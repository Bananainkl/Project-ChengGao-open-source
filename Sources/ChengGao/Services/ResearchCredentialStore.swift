import Foundation

enum ResearchCredentialStore {
    private static let filename = "com.itou.chenggao.research-youtube-data-api-key.key"

    static func loadYouTubeAPIKey() -> String? {
        guard let data = try? Data(contentsOf: credentialURL),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func saveYouTubeAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteYouTubeAPIKey()
            return
        }
        let directory = credentialURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(trimmed.utf8).write(to: credentialURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: credentialURL.path
        )
    }

    static func deleteYouTubeAPIKey() throws {
        guard FileManager.default.fileExists(atPath: credentialURL.path) else { return }
        try FileManager.default.removeItem(at: credentialURL)
    }

    private static var credentialURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "com.itou.chenggao/Credentials", directoryHint: .isDirectory)
            .appending(path: filename)
    }
}
