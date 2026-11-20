import SwiftUI

struct ResearchView: View {
    static let resultsListFraction: CGFloat = 2.0 / 3.0
    static let detailsFraction: CGFloat = 1.0 / 3.0

    @Bindable var researchStore: ResearchStore
    @Bindable var rewriteStore: RewriteStore
    let search: () -> Void
    let showComposer: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedResult: String?
    @State private var showsFilters = false
    @State private var compactShowsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("搜索素材关键词", text: $researchStore.keyword)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit(search)
                    .accessibilityLabel("研究关键词")
                searchButton
            }
            if researchStore.isSearching {
                ProgressView(value: researchStore.progress).accessibilityLabel("搜索进度")
            }
            messages
            if researchStore.results.isEmpty {
                emptyState
            } else {
                resultsLayout
            }
            HStack(alignment: .firstTextBaseline) {
                Text(researchStore.statusMessage)
                Spacer()
                Text("近 \(researchStore.recentDays) 天 · 最多 \(researchStore.maxItems) 条")
                    .fixedSize()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .workspaceMargins()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("搜索条件", systemImage: "line.3.horizontal.decrease") { showsFilters.toggle() }
                    .help("选择平台、时间范围和结果数量")
                    .popover(isPresented: $showsFilters) { filters }
                if !researchStore.results.isEmpty {
                    Menu("导出研究结果", systemImage: "square.and.arrow.up") {
                        ForEach(ResearchExportFormat.allCases) { format in
                            Button(format.rawValue) { researchStore.export(format) }
                        }
                    }
                }
            }
        }
        .onChange(of: researchStore.isSearching) { _, searching in
            if searching { compactShowsDetail = false }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("搜索条件").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("完成") { showsFilters = false }
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    searchOptions
                    Divider()
                    ForEach(ResearchPlatform.allCases) { platform in
                        platformControl(platform)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 340, height: 392)
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
            Button("搜索爆款", action: search)
                .buttonStyle(.borderedProminent)
                .disabled(!researchStore.canSearch)
                .controlSize(.large)
        }
    }

    @ViewBuilder private var messages: some View {
        if let warning = researchStore.warningMessage {
            WorkspaceIssueView(message: warning, isWarning: true)
        }
        if let error = researchStore.errorMessage {
            WorkspaceIssueView(message: error)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(researchStore.isSearching ? "正在查找素材" : "查找研究素材",
                  systemImage: researchStore.isSearching ? "magnifyingglass" : "text.magnifyingglass")
        } description: {
            Text(researchStore.isSearching ? "结果将按综合热度排列。" : "输入关键词开始搜索，可在搜索条件中选择平台。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsLayout: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width - 1)
            let compact = width < 820
            let readingDetail = compact && compactShowsDetail
            HStack(spacing: 0) {
                // Keep the variable-height list mounted while macOS is resizing the window.
                ZStack(alignment: .topLeading) {
                    resultsList(compact: compact)
                        .opacity(readingDetail ? 0 : 1)
                        .allowsHitTesting(!readingDetail)
                        .disabled(readingDetail)
                        .accessibilityHidden(readingDetail)
                    if readingDetail {
                        VStack(alignment: .leading, spacing: 6) {
                            Button("返回结果列表", systemImage: "chevron.left") {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { compactShowsDetail = false }
                            }
                            .keyboardShortcut("[", modifiers: .command)
                            .padding(8)
                            selectedDetail
                        }
                    }
                }
                .frame(width: compact ? proxy.size.width : width * Self.resultsListFraction)
                if !compact {
                    Divider()
                    selectedDetail.frame(width: width * Self.detailsFraction)
                }
            }
        }
        .workspaceEditorSurface(focused: false)
    }

    private func resultsList(compact: Bool) -> some View {
        VStack(spacing: 0) {
            resultHeader
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(researchStore.results.enumerated()), id: \.element.id) { index, item in
                            let selected = researchStore.selectedContentID == item.id
                            Button {
                                researchStore.selectedContentID = item.id
                                if compact {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { compactShowsDetail = true }
                                }
                            } label: {
                                resultRow(item, rank: index + 1)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .frame(maxWidth: .infinity)
                                    .background(selected ? Color.accentColor.opacity(0.14) : .clear)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .focused($focusedResult, equals: item.id)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .id(item.id)
                            Divider()
                        }
                    }
                }
                .onMoveCommand { direction in
                    guard direction == .up || direction == .down,
                          !researchStore.results.isEmpty else { return }
                    let current = researchStore.results.firstIndex { $0.id == researchStore.selectedContentID } ?? 0
                    let next = min(max(0, current + (direction == .up ? -1 : 1)), researchStore.results.count - 1)
                    let id = researchStore.results[next].id
                    researchStore.selectedContentID = id
                    scroll.scrollTo(id, anchor: .center)
                    focusedResult = id
                }
            }
        }
    }

    @ViewBuilder private var selectedDetail: some View {
        if let content = researchStore.selectedContent {
            ResearchContentDetail(content: content, canAnalyze: !rewriteStore.isProcessing) {
                rewriteStore.processResearchContent(content)
                showComposer()
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
            Text("点赞").frame(width: 58, alignment: .trailing)
            Text("热度").frame(width: 44, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
    }

    private func resultRow(_ item: ResearchContent, rank: Int) -> some View {
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
                    Text(item.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(item.title)
                }
                Text(item.authorName ?? "作者不可获取")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(metric(item.likeCount)).frame(width: 58, alignment: .trailing)
            Text(item.hotScore, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第\(rank)名，\(item.platform.title)，\(item.title)")
        .accessibilityHint("查看这条内容的详细信息与数据指标")
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
            HStack {
                Label(platform.title, systemImage: platform.systemImage)
                Spacer()
                Text(state.label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!state.canSelect || researchStore.isSearching)
        .help("\(platform.searchAvailability.label) · \(state.label)")
    }

    @ViewBuilder private func platformControl(_ platform: ResearchPlatform) -> some View {
        if platform == .wechatChannels {
            Button("导入视频号分享链接…", systemImage: "link") {
                showsFilters = false
                researchStore.selectedPlatforms.remove(.wechatChannels)
                rewriteStore.prepareManualPlatformLink(platform)
                showComposer()
            }
            .disabled(rewriteStore.isProcessing)
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
    let canAnalyze: Bool
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
                .disabled(!canAnalyze)

                Button(content.resolvedContentKind == .video ? "打开原视频" : "打开原笔记") {
                    openURL(content.contentURL)
                }
                    .frame(maxWidth: .infinity)
            }
            .padding(12)
            .frame(maxWidth: 460, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.automatic)
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
