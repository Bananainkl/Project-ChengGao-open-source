import Foundation

enum WebAIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case qwen
    case deepSeek

    var id: Self { self }

    var title: String {
        switch self {
        case .qwen: "千问"
        case .deepSeek: "DeepSeek"
        }
    }

    var systemImage: String {
        switch self {
        case .qwen: "cloud"
        case .deepSeek: "brain.head.profile"
        }
    }

    var chatURL: URL {
        switch self {
        case .qwen: URL(string: "https://www.qianwen.com/")!
        case .deepSeek: URL(string: "https://chat.deepseek.com/")!
        }
    }

    var allowedHosts: [String] {
        switch self {
        case .qwen: ["qianwen.com", "passport.aliyun.com", "login.taobao.com"]
        case .deepSeek: ["deepseek.com", "wechat.com", "weixin.qq.com"]
        }
    }

    var editorSelectors: [String] {
        switch self {
        case .qwen:
            [#"[role="textbox"][contenteditable="true"]"#, #"[data-slate-editor="true"]"#]
        case .deepSeek:
            ["textarea", #"[role="textbox"][contenteditable="true"]"#, #"[contenteditable="true"]"#]
        }
    }

    var responseSelector: String {
        switch self {
        case .qwen: ".qk-markdown-complete"
        case .deepSeek: ".ds-markdown"
        }
    }

    var sendButtonLabels: [String] {
        switch self {
        case .qwen: ["发送消息", "发送", "Send"]
        case .deepSeek: ["发送", "Send"]
        }
    }
}

struct WebAIConfiguration: Equatable, Sendable {
    static let providerKey = "webAI.provider"
    static let enabledKey = "webAI.enabled"

    var provider: WebAIProvider
    var isEnabled: Bool

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(
            provider: WebAIProvider(rawValue: defaults.string(forKey: providerKey) ?? "") ?? .qwen,
            isEnabled: defaults.bool(forKey: enabledKey)
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: Self.providerKey)
        defaults.set(isEnabled, forKey: Self.enabledKey)
    }
}
