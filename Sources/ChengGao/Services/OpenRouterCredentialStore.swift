import Foundation

enum OnlineAICredentialStorage: Equatable {
    case protectedFile

    var label: String { "仅当前用户可读的本地凭证文件" }
}

/// Online AI credentials intentionally avoid macOS Keychain access.
///
/// The app used to probe Keychain during every launch, which could display an
/// authorization dialog before the user had done anything. Credentials are now
/// stored only in an app-private directory with POSIX 0600 permissions.
enum OnlineAICredentialStore {
    private static let service = "com.itou.chenggao.online-ai"

    static func load(for provider: OnlineAIProvider, serviceName: String? = nil) -> String? {
        let url = protectedFileURL(provider: provider, serviceName: serviceName ?? service)
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    static func save(
        _ value: String,
        for provider: OnlineAIProvider,
        serviceName: String? = nil
    ) throws -> OnlineAICredentialStorage {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete(for: provider, serviceName: serviceName)
            return .protectedFile
        }
        let url = protectedFileURL(provider: provider, serviceName: serviceName ?? service)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(trimmed.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return .protectedFile
    }

    static func delete(for provider: OnlineAIProvider, serviceName: String? = nil) throws {
        let url = protectedFileURL(provider: provider, serviceName: serviceName ?? service)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func storage(
        for provider: OnlineAIProvider,
        serviceName: String? = nil
    ) -> OnlineAICredentialStorage? {
        FileManager.default.fileExists(
            atPath: protectedFileURL(provider: provider, serviceName: serviceName ?? service).path
        ) ? .protectedFile : nil
    }

    private static func protectedFileURL(provider: OnlineAIProvider, serviceName: String) -> URL {
        let safeService = serviceName.replacingOccurrences(of: "/", with: "-")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "com.itou.chenggao/Credentials", directoryHint: .isDirectory)
            .appending(path: "\(safeService)-\(provider.rawValue).key")
    }
}

/// Image credentials are deliberately isolated from chat credentials. A relay
/// can use a different host, account, permission scope, or billing key for
/// image generation, so changing either credential must not affect the other.
enum OnlineImageCredentialStore {
    private static let service = "com.itou.chenggao.online-image-ai"

    static func load(for provider: OnlineAIProvider, serviceName: String? = nil) -> String? {
        OnlineAICredentialStore.load(
            for: provider,
            serviceName: serviceName ?? service
        )
    }

    @discardableResult
    static func save(
        _ value: String,
        for provider: OnlineAIProvider,
        serviceName: String? = nil
    ) throws -> OnlineAICredentialStorage {
        try OnlineAICredentialStore.save(
            value,
            for: provider,
            serviceName: serviceName ?? service
        )
    }

    static func delete(for provider: OnlineAIProvider, serviceName: String? = nil) throws {
        try OnlineAICredentialStore.delete(
            for: provider,
            serviceName: serviceName ?? service
        )
    }

    static func storage(
        for provider: OnlineAIProvider,
        serviceName: String? = nil
    ) -> OnlineAICredentialStorage? {
        OnlineAICredentialStore.storage(
            for: provider,
            serviceName: serviceName ?? service
        )
    }
}
