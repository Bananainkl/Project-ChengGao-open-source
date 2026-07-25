---
kind: configuration_system
name: 配置系统 — UserDefaults + 受保护文件凭证存储
category: configuration_system
scope:
    - '**'
source_files:
    - Sources/ChengGao/Models/OnlineAIConfiguration.swift
    - Sources/ChengGao/Models/WebAIModels.swift
    - Sources/ChengGao/Stores/RewriteStore.swift
    - Sources/ChengGao/Services/OpenRouterCredentialStore.swift
    - Sources/ChengGao/Views/SettingsView.swift
    - Sources/ChengGao/App/ChengGaoApp.swift
    - Sources/ChengGao/Services/ResearchCredentialStore.swift
    - Sources/ChengGao/Services/PlatformSessionStore.swift
---

## 系统与架构概览
本仓库采用「轻量级本地持久化」的配置体系：用户偏好与连接参数通过 `UserDefaults` 以键值形式保存，敏感凭据（API Key）则写入应用支持目录下的私有文件（POSIX 权限 0600），完全避免调用 macOS 钥匙串。配置入口集中在 `Models` 与 `Stores` 层，UI 通过 SwiftUI Settings 页面暴露编辑能力。

## 关键文件与包
- `Sources/ChengGao/Models/OnlineAIConfiguration.swift` — 在线 AI 提供商、端点、模型及图片生成配置的加载/保存逻辑，包含 URL 推导与凭据形状检测
- `Sources/ChengGao/Models/WebAIModels.swift` — Web AI 提供商开关与默认值
- `Sources/ChengGao/Stores/RewriteStore.swift` — 主 Store，集中初始化所有配置项、合并历史数据、协调凭据状态
- `Sources/ChengGao/Services/OpenRouterCredentialStore.swift` — 聊天与图片两类凭据的受保护文件存储实现
- `Sources/ChengGao/Views/SettingsView.swift` — SwiftUI Settings 界面，绑定 Store 中的可编辑字段
- `Sources/ChengGao/App/ChengGaoApp.swift` — 应用入口，注册 Settings Scene
- `Sources/ChengGao/Services/ResearchCredentialStore.swift` / `PlatformSessionStore.swift` — 研究搜索与平台会话相关凭据与 Cookie 管理

## 架构与约定
1. **UserDefaults 分层键空间**
   - `onlineAI.provider` 决定当前提供商；每个提供商拥有独立子命名空间 `onlineAI.<provider>.endpoint/model` 以及 `onlineAI.<provider>.imageGeneration.*`
   - `webAI.provider`、`webAI.enabled` 控制网页 AI 开关
   - 其他通用设置如 `outputLanguage`、`visualStyle`、`modelMode`、`onlineTerminologyCheck` 等直接位于根命名空间
2. **load/save 模式**
   - 每个配置结构体提供 `static func load(defaults:)` 与 `func save(defaults:)`，默认使用 `.standard`，便于测试注入隔离实例
3. **URL 自动推导**
   - `OnlineAIConfiguration.chatCompletionsURL(from:)` 接受 base URL、`/v1` 或完整 `/chat/completions` 路径，自动补全为兼容端点
   - `OnlineImageGenerationConfiguration.imagesGenerationsURL(from:fallbackChatEndpoint:)` 同理推导图片接口，留空时复用聊天主机并替换路径
4. **凭据分离与安全策略**
   - 聊天 API Key 与图片 API Key 分别由 `OnlineAICredentialStore` 与 `OnlineImageCredentialStore` 管理，互不覆盖
   - 凭据文件存放于 `~/Library/Application Support/com.itou.chenggao/Credentials/<service>-<provider>.key`，目录权限 0700，文件权限 0600
   - 启动时若检测到旧版把 Key 误填到 endpoint 字段，会自动清除并提示撤销旧 Key
5. **UI 与 Store 绑定**
   - `SettingsView` 通过 `@Bindable var store: RewriteStore` 双向绑定，修改后调用 Store 方法触发 `save()` 与状态刷新
   - 提供商切换会重新加载对应命名空间的配置，保证多提供商隔离

## 约束与规则
- **禁止访问钥匙串**：代码注释明确说明“应用不再探测钥匙串，避免启动时弹出授权对话框”，所有凭据仅存于受保护文件
- **凭据长度与格式校验**：`acceptsAPIKey(_:)` 对 DeepSeek 要求 `sk-` 前缀且长度≥20，其他提供商至少 16 字符；`looksLikeCredential(_:)` 用于防止将密钥误粘贴到 endpoint 字段
- **默认值回退**：所有 `load` 方法均提供合理默认值（如 provider 回退到 `.custom`，size/quality 回退到 `.automatic`），确保首次运行可用
- **测试隔离**：测试中使用 `UserDefaults(suiteName:)` 创建隔离实例，避免污染全局配置
- **Web AI 白名单**：`allowedHosts` 限定各提供商允许的主机列表，限制 WebView 导航范围