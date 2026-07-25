---
kind: frontend_style
name: SwiftUI 毛玻璃风格与 macOS 原生视觉体系
category: frontend_style
scope:
    - '**'
source_files:
    - Sources/ChengGao/Views/WorkspaceGlassStyle.swift
    - Sources/ChengGao/App/WindowGlassConfigurator.swift
    - Sources/ChengGao/Views/ContentView.swift
    - Sources/ChengGao/Views/SidebarView.swift
    - Sources/ChengGao/Views/WorkspaceLayout.swift
---

本项目采用 SwiftUI 作为唯一 UI 框架，结合 AppKit 桥接实现 macOS 原生毛玻璃（Glass）视觉效果，整体遵循 Apple 设计语言，未引入第三方 CSS/样式库或 Tailwind 等方案。

**样式系统与方法论**
- 以 `WorkspaceGlassStyle.swift` 为核心，封装了统一的毛玻璃面板、内嵌背景与环境光渐变组件，通过自定义 `ViewModifier`（`WorkspaceGlassPanelModifier`、`WorkspaceGlassInsetModifier`）提供 `workspaceGlassPanel`、`workspaceGlassInset` 等扩展方法，供各页面复用。
- 使用 `.glassEffect(.regular, in: .rect(...))`、`.thinMaterial`、`.ultraThinMaterial` 等 SwiftUI 内置材质 API 实现磨砂玻璃效果；背景采用双径向渐变（accentColor + cyan）叠加系统 Material，形成环境光氛围。
- 通过 `WindowGlassConfigurator`（NSViewRepresentable）桥接 AppKit，将窗口设为非透明背景、隐藏标题栏并启用 fullSizeContentView，使 SwiftUI 的 material 能采样桌面底层内容。

**主题与颜色约定**
- 颜色随 `colorScheme`（深色/浅色）动态切换，透明度在暗色模式下降低以提升对比度。
- 统一使用系统语义色：`Color.accentColor`、`Color.cyan`、`Color.white.opacity(...)` 配合 `.tint`、`.secondary` 等修饰符，不硬编码 RGB 值。
- 圆角统一通过 `RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)` 生成，默认 20pt，边框线宽 0.65–0.8pt。

**布局与响应式策略**
- 主界面基于 `NavigationSplitView` 构建侧边栏+详情布局，侧边栏宽度通过 `navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)` 约束。
- 全局尺寸常量集中在 `WorkspaceLayout` 枚举中（detailHorizontalPadding=14、detailTopPadding=16、detailBottomPadding=20、headerContentSpacing=24），保证间距一致性。
- 应用窗口最小尺寸 980×680，默认 1180×780，支持 `.windowResizability(.contentMinSize)`。

**组件组织规范**
- 所有视图文件位于 `Sources/ChengGao/Views/`，按功能划分（SidebarView、ComposerView、ResultView、SettingsView 等），无嵌套子目录。
- 样式与布局逻辑从业务视图中剥离到独立文件（如 `WorkspaceGlassStyle.swift`、`WorkspaceLayout.swift`），保持单一职责。
- 通过 `@Bindable` 绑定 Store（RewriteStore、ResearchStore）驱动 UI 更新，状态与表现分离。

**约束与限制**
- 当用户开启“减少透明度”辅助功能时，毛玻璃自动降级为纯色背景（`Color.nsColor(.windowBackgroundColor)`），确保可访问性。
- 不使用任何外部 CSS/SCSS/Tailwind，全部样式由 SwiftUI 声明式 API 与 ViewModifier 组合实现。