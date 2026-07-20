import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ResearchStore {
    var keyword = ""
    var selectedPlatforms: Set<ResearchPlatform> = [.bilibili]
    var maxItems = 20
    var recentDays = 30
    private(set) var results: [ResearchContent] = []
    private(set) var tasks: [ResearchTaskRecord] = []
    private(set) var accounts: [ResearchAccount] = []
    var selectedContentID: String?
    var loginPlatform: ResearchPlatform?
    var isSearching = false
    var progress = 0.0
    var statusMessage = "输入关键词，寻找当前值得拆解的热门内容"
    var warningMessage: String?
    var errorMessage: String?
    var youtubeAPIKeyDraft = ""
    private(set) var hasYouTubeAPIKey = false
    private(set) var youtubeKeyStatus = "尚未配置"

    var selectedContent: ResearchContent? {
        results.first { $0.id == selectedContentID }
    }

    var canSearch: Bool {
        !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedPlatforms.isEmpty
            && !isSearching
    }

    var searchablePlatforms: [ResearchPlatform] {
        ResearchPlatform.allCases.filter { searchState(for: $0).isReady }
    }

    private let searchService: any ResearchSearching
    private let database: ResearchDatabase?
    private var searchTask: Task<Void, Never>?

    init(
        searchService: any ResearchSearching = ResearchSearchService(),
        databaseURL: URL? = nil
    ) {
        self.searchService = searchService
        self.database = try? ResearchDatabase(url: databaseURL ?? ResearchDatabase.defaultURL)
        self.hasYouTubeAPIKey = ResearchCredentialStore.loadYouTubeAPIKey() != nil
        self.youtubeKeyStatus = hasYouTubeAPIKey ? "已保存到本地私有凭证文件" : "尚未配置"
        Task { await loadPersistedData() }
    }

    func startSearch() {
        guard canSearch else { return }
        let ignoredManualPlatform = selectedPlatforms.remove(.wechatChannels) != nil
        guard !selectedPlatforms.isEmpty else {
            errorMessage = "视频号不支持公开关键词检索。请在“新建文稿”粘贴视频号分享链接进行拆解。"
            statusMessage = "请粘贴视频号分享链接"
            return
        }
        let unavailablePlatforms = selectedPlatforms.sorted(by: { $0.rawValue < $1.rawValue })
            .filter { !searchState(for: $0).isReady }
        let readyPlatforms = selectedPlatforms.subtracting(unavailablePlatforms)
        if readyPlatforms.isEmpty, let platform = unavailablePlatforms.first {
            let state = searchState(for: platform)
            errorMessage = "\(platform.title)没有有效登录会话（\(state.label)），请先在“平台账号”完成后再搜索。"
            statusMessage = "\(platform.title)\(state.label)"
            if state.canSelect { loginPlatform = platform }
            return
        }
        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        var setupWarnings: [String] = []
        if ignoredManualPlatform {
            setupWarnings.append("已跳过视频号关键词搜索；视频号内容请使用分享链接导入。")
        }
        if !unavailablePlatforms.isEmpty {
            let names = unavailablePlatforms.map { "\($0.title)（\(searchState(for: $0).label)）" }
                .joined(separator: "、")
            setupWarnings.append("已跳过尚未就绪的平台：\(names)。可在“平台账号”完成登录或配置后再选。")
        }
        warningMessage = setupWarnings.isEmpty ? nil : setupWarnings.joined(separator: "\n")
        let preflightWarnings = setupWarnings
        progress = 0
        statusMessage = "正在启动搜索…"
        results = []
        selectedContentID = nil
        let input = ResearchSearchInput(
            keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            platforms: readyPlatforms,
            maxItems: maxItems,
            recentDays: recentDays
        )
        var taskRecord = ResearchTaskRecord(
            id: UUID().uuidString, keyword: input.keyword,
            platforms: input.platforms.sorted { $0.rawValue < $1.rawValue }, status: .running,
            progress: 0, errorMessage: nil, createdAt: .now, startedAt: .now, completedAt: nil
        )
        tasks.insert(taskRecord, at: 0)
        let service = searchService
        let database = database

        searchTask = Task {
            try? await database?.save(task: taskRecord)
            do {
                let outcome = try await service.search(input: input) { [weak self] platform, completed, total in
                    Task { @MainActor in
                        guard let self, self.isSearching else { return }
                        self.progress = total == 0 ? 0 : Double(completed) / Double(total)
                        self.statusMessage = completed == total
                            ? "正在整理热度排名…"
                            : (completed == 0 ? "正在搜索 \(platform.title)…" : "已完成 \(completed)/\(total)：\(platform.title)")
                    }
                }
                try Task.checkCancellation()
                results = outcome.contents
                selectedContentID = results.first?.id
                let allWarnings = preflightWarnings + outcome.warnings
                warningMessage = allWarnings.isEmpty ? nil : allWarnings.joined(separator: "\n")
                statusMessage = "找到 \(results.count) 条内容 · 已按综合热度排序"
                progress = 1
                taskRecord.status = .completed
                taskRecord.progress = 1
                taskRecord.completedAt = .now
                if let database {
                    try await database.save(contents: results, taskID: taskRecord.id)
                    try await database.save(task: taskRecord)
                }
                replaceTask(taskRecord)
            } catch is CancellationError {
                taskRecord.status = .cancelled
                taskRecord.errorMessage = nil
                taskRecord.completedAt = .now
                statusMessage = "搜索已取消"
                try? await database?.save(task: taskRecord)
                replaceTask(taskRecord)
            } catch {
                taskRecord.status = .failed
                taskRecord.errorMessage = error.localizedDescription
                taskRecord.completedAt = .now
                errorMessage = error.localizedDescription
                statusMessage = "搜索未完成"
                if selectedPlatforms.count == 1,
                   let platform = selectedPlatforms.first,
                   error.localizedDescription.contains("重新登录") {
                    finishLogin(platform, detected: false)
                    loginPlatform = platform
                }
                try? await database?.save(task: taskRecord)
                replaceTask(taskRecord)
            }
            isSearching = false
            searchTask = nil
        }
    }

    func cancelSearch() {
        guard isSearching else { return }
        statusMessage = "正在取消搜索…"
        searchTask?.cancel()
    }

    func beginLogin(_ platform: ResearchPlatform) {
        loginPlatform = platform
    }

    func finishLogin(_ platform: ResearchPlatform, detected: Bool) {
        let now = Date()
        let account = ResearchAccount(
            id: "\(platform.rawValue):default", platform: platform,
            displayName: "\(platform.title) 默认账号",
            status: detected ? .loggedIn : .verificationRequired,
            lastCheckedAt: now,
            createdAt: accounts.first(where: { $0.platform == platform })?.createdAt ?? now,
            updatedAt: now
        )
        accounts.removeAll { $0.platform == platform }
        accounts.append(account)
        accounts.sort { $0.platform.rawValue < $1.platform.rawValue }
        loginPlatform = nil
        Task { try? await database?.save(account: account) }
    }

    func account(for platform: ResearchPlatform) -> ResearchAccount? {
        accounts.first { $0.platform == platform }
    }

    func searchState(for platform: ResearchPlatform) -> ResearchPlatformSearchState {
        if platform == .bilibili { return .ready("公开搜索") }
        if platform == .wechatChannels { return .manualLinkOnly }
        if platform == .youtube, hasYouTubeAPIKey { return .ready("Data API") }
        switch account(for: platform)?.status {
        case .loggedIn: return .ready("已登录")
        case .verificationRequired: return .verificationRequired
        case .notLoggedIn, .unknown, nil: return .loginRequired
        }
    }

    func removeAccount(_ platform: ResearchPlatform) {
        let id = accounts.first(where: { $0.platform == platform })?.id ?? "\(platform.rawValue):default"
        accounts.removeAll { $0.platform == platform }
        Task {
            await PlatformSessionStore.deleteCookies(for: platform)
            try? await database?.deleteAccount(id: id)
        }
    }

    func saveYouTubeAPIKey() {
        let key = youtubeAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("AIza"), key.count >= 30 else {
            youtubeKeyStatus = "Key 格式不正确，应为 Google API Key"
            return
        }
        do {
            try ResearchCredentialStore.saveYouTubeAPIKey(key)
            youtubeAPIKeyDraft = ""
            hasYouTubeAPIKey = true
            youtubeKeyStatus = "已保存到本地私有凭证文件"
            selectedPlatforms.insert(.youtube)
        } catch {
            youtubeKeyStatus = error.localizedDescription
        }
    }

    func deleteYouTubeAPIKey() {
        do {
            try ResearchCredentialStore.deleteYouTubeAPIKey()
            youtubeAPIKeyDraft = ""
            hasYouTubeAPIKey = false
            youtubeKeyStatus = "已从本地私有凭证文件删除"
            selectedPlatforms.remove(.youtube)
        } catch {
            youtubeKeyStatus = error.localizedDescription
        }
    }

    func export(_ format: ResearchExportFormat) {
        guard !results.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "爆款研究-\(keyword).\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try format.render(results).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "已导出 \(results.count) 条结果"
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func loadPersistedData() async {
        guard let database else { return }
        accounts = (try? await database.loadAccounts()) ?? []
        tasks = (try? await database.loadTasks()) ?? []
        if results.isEmpty {
            results = (try? await database.loadRecentContents()) ?? []
            selectedContentID = results.first?.id
        }
    }

    private func replaceTask(_ value: ResearchTaskRecord) {
        if let index = tasks.firstIndex(where: { $0.id == value.id }) {
            tasks[index] = value
        } else {
            tasks.insert(value, at: 0)
        }
    }
}

enum ResearchExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV"
    case json = "JSON"
    case markdown = "Markdown"

    var id: Self { self }
    var fileExtension: String { rawValue.lowercased() == "markdown" ? "md" : rawValue.lowercased() }

    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        case .markdown: .plainText
        }
    }

    func render(_ values: [ResearchContent]) throws -> String {
        switch self {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return String(decoding: try encoder.encode(values), as: UTF8.self)
        case .csv:
            let header = "rank,platform,title,author,published_at,views,likes,comments,collects,shares,hot_score,url"
            let rows = values.enumerated().map { index, item in
                let fields: [String] = [
                    String(index + 1),
                    item.platform.title,
                    item.title,
                    item.authorName ?? "",
                    item.publishedAt?.ISO8601Format() ?? "",
                    item.viewCount.map(String.init) ?? "",
                    item.likeCount.map(String.init) ?? "",
                    item.commentCount.map(String.init) ?? "",
                    item.collectCount.map(String.init) ?? "",
                    item.shareCount.map(String.init) ?? "",
                    String(format: "%.3f", item.hotScore),
                    item.contentURL.absoluteString
                ]
                return fields.map(Self.csvField).joined(separator: ",")
            }
            return ([header] + rows).joined(separator: "\n")
        case .markdown:
            let rows = values.enumerated().map { index, item in
                "| \(index + 1) | \(item.platform.title) | [\(item.title.replacingOccurrences(of: "|", with: "／"))](\(item.contentURL.absoluteString)) | \(item.viewCount.map(String.init) ?? "—") | \(String(format: "%.2f", item.hotScore)) |"
            }
            return (["| 排名 | 平台 | 标题 | 播放 | 热度 |", "|---:|---|---|---:|---:|"] + rows).joined(separator: "\n")
        }
    }

    private static func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
