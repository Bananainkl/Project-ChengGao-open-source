---
kind: logging_system
name: 日志系统 — 基于 print 的临时调试输出
category: logging_system
scope:
    - '**'
source_files:
    - Sources/ChengGao/Services/EmbeddedModelRuntime.swift
    - Tests/ChengGaoTests/OfflineRewritePipelineTests.swift
    - Sources/ChengGao/App/ChengGaoApp.swift
---

本仓库未引入任何结构化日志框架（如 os_log、Logger 或第三方日志库），也未定义统一的日志级别、日志门面或集中式日志配置。代码中的“日志”行为完全由分散的 `print(...)` 调用构成，主要用于开发调试阶段的临时输出。

具体表现：
- 所有日志均通过 Swift 标准库的 `print` 函数直接输出到标准输出，未见对 `os_log`、`Logger`、`NSLog` 等 macOS/iOS 原生日志 API 的使用。
- 日志位置集中在 `EmbeddedModelRuntime.swift` 的结构化改写调试分支中（如解析失败时的 prefix/suffix 打印、相似度与长度比打印、合并后的 similarity/issues 打印），以及测试文件 `OfflineRewritePipelineTests.swift` 中的若干 `print("LIVE_...")` 调试语句。
- 这些 `print` 调用大多被 `if debug { ... }` 条件包裹，说明开发者有意将其作为可选的调试开关，但并未提供全局的日志级别控制或运行时开关机制。
- 应用主入口 `ChengGaoApp.swift` 及 AppDelegate 中无任何日志初始化或配置代码。
- 构建脚本与 GitHub Actions 工作流中未发现针对日志收集、过滤或转储的配置。

约束与约定：
- 由于不存在统一的日志抽象层，新增模块如需记录运行期信息，只能自行添加 `print` 语句；无法保证日志格式、来源标识或可过滤性的一致性。
- 当前实现不具备生产环境可用的日志能力（无结构化字段、无 sink 路由、无级别过滤），仅适用于本地调试阶段快速定位问题。

结论：该仓库尚未建立正式的日志系统，现有输出仅为零散的调试用 `print` 语句，不属于可复用的日志架构。