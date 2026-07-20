import SwiftUI

struct ResearchView: View {
    static let resultsListFraction: CGFloat = 0.75
    static let detailsFraction: CGFloat = 0.25

    @Bindable var researchStore: ResearchStore
    @Bindable var rewriteStore: RewriteStore

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.headerContentSpacing) {
            WorkspacePageHeader(title: "爆款研究")
            searchPanel
            messages
            Group {
                if researchStore.results.isEmpty {
                    emptyState
                } else {
                    resultsLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, WorkspaceLayout.detailHorizontalPadding)
        .padding(.top, WorkspaceLayout.detailTopPadding)
        .padding(.bottom, WorkspaceLayout.detailBottomPadding)
        .sheet(item: $researchStore.loginPlatform) { platform in
            PlatformLoginSheet(platform: platform, store: researchStore)
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    keywordField
                    searchOptions
                    searchButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    keywordField
                    HStack(spacing: 12) {
                        searchOptions
                        Spacer(minLength: 0)
                        searchButton
                    }
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112, maximum: 155), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(ResearchPlatform.allCases) { platform in
                    platformControl(platform)
                }
            }

            if researchStore.isSearching {
                ProgressView(value: researchStore.progress)
            }

            HStack {
                Text(researchStore.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !researchStore.results.isEmpty {
                    Menu("导出") {
                        ForEach(ResearchExportFormat.allCases) { format in
                            Button(format.rawValue) { researchStore.export(format) }
                        }
                    }
                }
            }
        }
        .padding(18)
        .workspaceGlassPanel(cornerRadius: 18, elevated: true)
    }

    private var keywordField: some View {
        TextField("输入关键词，例如：香港身份", text: $researchStore.keyword)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220)
            .onSubmit { researchStore.startSearch() }
    }

    private var searchOptions: some View {
        HStack(spacing: 10) {
            Picker("时间", selection: $researchStore.recentDays) {
                Text("近 7 天").tag(7)
                Text("近 30 天").tag(30)
                Text("近 90 天").tag(90)
            }
            .frame(width: 122)

            Picker("数量", selection: $researchStore.maxItems) {
                Text("20 条").tag(20)
                Text("50 条").tag(50)
                Text("100 条").tag(100)
            }
            .frame(width: 102)
        }
    }

    @ViewBuilder private var searchButton: some View {
        if researchStore.isSearching {
            Button("取消", action: researchStore.cancelSearch)
        } else {
            Button("搜索爆款", action: researchStore.startSearch)
                .buttonStyle(.borderedProminent)
                .disabled(!researchStore.canSearch)
                .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    @ViewBuilder private var messages: some View {
        if let warning = researchStore.warningMessage {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let error = researchStore.errorMessage {
            Label(error, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: .rect(cornerRadius: 12))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "还没有搜索结果",
            systemImage: "chart.line.uptrend.xyaxis",
            description: Text("哔哩哔哩优先快速搜索；其他平台会复用账号管理中的网页登录会话。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workspaceGlassPanel(cornerRadius: 18, elevated: true)
    }

    private var resultsLayout: some View {
        GeometryReader { geometry in
            let dividerWidth: CGFloat = 1
            let availableWidth = max(0, geometry.size.width - dividerWidth)
            HStack(spacing: 0) {
                resultsList
                    .frame(width: availableWidth * Self.resultsListFraction)
                Divider()
                selectedDetail
                    .frame(width: availableWidth * Self.detailsFraction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workspaceGlassPanel(cornerRadius: 18, elevated: true)
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            resultHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(researchStore.results.enumerated()), id: \.element.id) { index, item in
                        resultRow(item, rank: index + 1)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder private var selectedDetail: some View {
        if let content = researchStore.selectedContent {
            ResearchContentDetail(content: content) {
                rewriteStore.processResearchContent(content)
            }
        } else {
            ContentUnavailableView("请选择一条内容", systemImage: "cursorarrow.click")
        }
    }

    private var resultHeader: some View {
        HStack {
            Text("排名").frame(width: 34)
            Text("平台").frame(width: 58, alignment: .leading)
            Text("标题").frame(maxWidth: .infinity, alignment: .leading)
            Text("播放").frame(width: 58, alignment: .trailing)
            Text("热度").frame(width: 44, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
    }

    private func resultRow(_ item: ResearchContent, rank: Int) -> some View {
        Button {
            researchStore.selectedContentID = item.id
        } label: {
            HStack(spacing: 7) {
                Text(String(rank)).frame(width: 34)
                Text(item.platform.title)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if item.platform == .xiaohongshu {
                            Text(item.resolvedContentKind.label)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        Text(item.title).lineLimit(2)
                    }
                    Text(item.authorName ?? "作者不可获取")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(metric(item.viewCount)).frame(width: 58, alignment: .trailing)
                Text(item.hotScore, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .contentShape(.rect)
            .background(researchStore.selectedContentID == item.id ? Color.accentColor.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
    }

    private func platformSelection(_ platform: ResearchPlatform) -> Binding<Bool> {
        Binding(
            get: { researchStore.selectedPlatforms.contains(platform) },
            set: { selected in
                if selected { researchStore.selectedPlatforms.insert(platform) }
                else { researchStore.selectedPlatforms.remove(platform) }
            }
        )
    }

    private func platformToggle(_ platform: ResearchPlatform) -> some View {
        let state = researchStore.searchState(for: platform)
        return Toggle(isOn: platformSelection(platform)) {
            VStack(spacing: 2) {
                Label(platform.title, systemImage: platform.systemImage)
                Text(state.label)
                    .font(.caption2)
                    .foregroundStyle(
                        state.isReady ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
        .disabled(!state.canSelect)
        .help("\(platform.searchAvailability.label) · \(state.label)")
    }

    @ViewBuilder
    private func platformControl(_ platform: ResearchPlatform) -> some View {
        if platform == .wechatChannels {
            Button {
                researchStore.selectedPlatforms.remove(.wechatChannels)
                rewriteStore.prepareManualPlatformLink(platform)
            } label: {
                VStack(spacing: 2) {
                    Label(platform.title, systemImage: platform.systemImage)
                    Text("粘贴分享链接")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("视频号没有公开关键词检索入口；点击后粘贴分享链接")
        } else {
            platformToggle(platform)
        }
    }

    private func metric(_ value: Int?) -> String {
        guard let value = ResearchContent.trustedMetric(value) else { return "—" }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        return value.formatted()
    }
}

private struct ResearchContentDetail: View {
    let content: ResearchContent
    let analyze: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let cover = content.coverURL {
                    AsyncImage(url: cover) { phase in
                        ZStack {
                            Rectangle().fill(.quaternary)
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            } else if case .failure = phase {
                                Image(systemName: "photo")
                                    .font(.title)
                                    .foregroundStyle(.tertiary)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                    .frame(maxWidth: 320)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 12))
                    .clipped()
                }

                Text(content.title)
                    .font(.headline)
                if content.platform == .xiaohongshu {
                    Label(
                        content.resolvedContentKind == .video ? "视频 · 将取得音轨并转写口播" : "图文 · 将识别正文与原图并重新设计",
                        systemImage: content.resolvedContentKind == .video ? "play.rectangle" : "photo.on.rectangle.angled"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                Text(content.authorName ?? "作者不可获取")
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        compactMetric("播放", metric(content.viewCount))
                            .gridCellColumns(2)
                    }
                    GridRow {
                        compactMetric("点赞", metric(content.likeCount))
                        compactMetric("评论", metric(content.commentCount))
                    }
                    GridRow {
                        compactMetric("收藏", metric(content.collectCount))
                        compactMetric(
                            "综合热度",
                            content.hotScore.formatted(.number.precision(.fractionLength(2)))
                        )
                    }
                }

                Label(
                    "指标可信度：\(content.metricConfidence.rawValue) · \(content.metricConfidence.explanation)",
                    systemImage: confidenceImage
                )
                .font(.caption)
                .foregroundStyle(confidenceColor)

                Text(content.resolvedContentKind == .video
                    ? "跨平台指标口径不同，综合热度仅用于候选筛选；视频拆解必须取得真实字幕或音轨。"
                    : "跨平台指标口径不同，综合热度仅用于候选筛选；图文会读取正文、识别每张原图并重新设计提示词。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    analyze()
                } label: {
                    Label(
                        content.resolvedContentKind == .video ? "转写并生成口播稿" : "改写图文并重构配图",
                        systemImage: "wand.and.stars"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(content.resolvedContentKind == .video ? "打开原视频" : "打开原笔记") {
                    openURL(content.contentURL)
                }
                    .frame(maxWidth: .infinity)
            }
            .padding(12)
            .frame(maxWidth: 460, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.never)
    }

    private func compactMetric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .lineLimit(1)
        }
    }

    private func metric(_ value: Int?) -> String {
        ResearchContent.trustedMetric(value)?.formatted() ?? "数据不可获取"
    }

    private var confidenceImage: String {
        content.metricConfidence == .high ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
    }

    private var confidenceColor: Color {
        switch content.metricConfidence {
        case .high: .green
        case .medium: .orange
        case .low: .red
        }
    }
}
