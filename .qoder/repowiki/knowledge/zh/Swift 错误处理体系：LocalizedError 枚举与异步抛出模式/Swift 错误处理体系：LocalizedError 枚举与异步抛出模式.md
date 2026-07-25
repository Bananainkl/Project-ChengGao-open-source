---
kind: error_handling
name: Swift 错误处理体系：LocalizedError 枚举与异步抛出模式
category: error_handling
scope:
    - '**'
source_files:
    - Sources/ChengGao/Services/CompatibleImageGenerationClient.swift
    - Sources/ChengGao/Services/EmbeddedModelRuntime.swift
    - Sources/ChengGao/Services/OfflineRewritePipeline.swift
    - Sources/ChengGao/Services/WebKitResearchSearchService.swift
    - Sources/ChengGao/Services/ResearchDatabase.swift
    - Sources/ChengGao/Services/DouyinVideoResolver.swift
    - Sources/ChengGao/Services/WebAIWebSession.swift
    - Tests/ChengGaoTests/OfflineRewritePipelineTests.swift
---

该仓库在 macOS SwiftUI 应用中采用 Swift 原生错误处理机制，以 `enum` + `LocalizedError` 为核心模式，结合 `async throws` 进行错误传播，未使用第三方错误库或 panic/recover 机制。

**1. 系统/方法**
- 所有业务错误均定义为 `enum` 并实现 `LocalizedError` 协议，通过 `errorDescription` 提供用户可读的中文错误信息。
- 服务层方法统一使用 `async throws` 签名，调用方通过 `do/catch` 或 `try await` 捕获错误。
- 网络请求、本地模型推理、数据库操作等外部依赖失败时，均转换为领域特定的错误枚举变体。
- 未发现 `fatalError`、`preconditionFailure` 或 `panic/recover` 的使用，表明应用严格避免崩溃式错误处理。

**2. 核心文件与包**
- `Sources/ChengGao/Services/CompatibleImageGenerationClient.swift`: `ImageGenerationError`（配置缺失、API Key 为空、HTTP 请求失败、响应无效、图片过大等）
- `Sources/ChengGao/Services/EmbeddedModelRuntime.swift`: `EmbeddedModelError`（资源缺失、进程启动失败、生成失败）
- `Sources/ChengGao/Services/OfflineRewritePipeline.swift`: `RewritePipelineError`（空输入）
- `Sources/ChengGao/Services/WebKitResearchSearchService.swift`: `WebKitResearchSearchError`（超时、登录验证、导航失败、无渲染结果等）
- `Sources/ChengGao/Services/ResearchDatabase.swift`: `ResearchDatabaseError`（打开失败、操作失败）
- `Sources/ChengGao/Services/DouyinVideoResolver.swift`: `SourceExtractionError`（平台会话缺失）
- `Sources/ChengGao/Services/WebAIWebSession.swift`: `WebAIWebError`（Equatable 支持）

**3. 架构与约定**
- **分层错误定义**：每个 Service 模块拥有独立的错误枚举，错误类型与功能域一一对应，便于调用方针对性处理。
- **用户友好消息**：所有 `errorDescription` 返回自然语言中文描述，可直接用于 UI 提示。
- **可发送性**：关键错误枚举遵循 `Sendable` 协议（如 `ImageGenerationError`、`OpenRouterError`），支持跨线程传递。
- **重试与降级**：部分错误被设计为可恢复（如 `noRenderedResults`、`timedOut`），调用方可尝试备用 URL 或策略。
- **上下文携带**：复杂错误通过关联值传递详细信息（如 HTTP 状态码、平台名称、具体失败原因）。

**4. 约定与约束**
- **禁止使用 panic**：全仓未发现 `fatalError`、`preconditionFailure`，所有异常路径均通过 `throw` 表达。
- **统一 LocalizedError**：所有自定义错误必须实现 `LocalizedError`，确保 UI 层可直接显示错误信息。
- **异步错误传播**：所有可能失败的方法声明 `throws`，调用链中错误向上冒泡至 UI 层处理。
- **测试覆盖**：`Tests/ChengGaoTests/OfflineRewritePipelineTests.swift` 包含对错误路径的验证用例。
- **视图层处理**：UI 层通过 `if case .failure = phase` 模式匹配 Result 类型或 catch 块处理错误，不直接暴露技术细节。