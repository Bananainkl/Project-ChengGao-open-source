import CSQLite
import Foundation

actor ResearchDatabase {
    nonisolated(unsafe) private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = ResearchDatabase.defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw ResearchDatabaseError.openFailed
        }
        let setup = """
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS accounts(
          id TEXT PRIMARY KEY, platform TEXT NOT NULL, display_name TEXT NOT NULL,
          login_status TEXT NOT NULL, last_checked_at TEXT NOT NULL,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tasks(
          id TEXT PRIMARY KEY, keyword TEXT NOT NULL, platforms_json TEXT NOT NULL,
          status TEXT NOT NULL, progress REAL NOT NULL, error_message TEXT,
          created_at TEXT NOT NULL, started_at TEXT, completed_at TEXT
        );
        CREATE TABLE IF NOT EXISTS contents(
          id TEXT PRIMARY KEY, platform TEXT NOT NULL, platform_content_id TEXT, keyword TEXT NOT NULL,
          content_type TEXT NOT NULL, title TEXT NOT NULL, description TEXT, author_name TEXT,
          author_url TEXT, content_url TEXT NOT NULL, cover_url TEXT, published_at TEXT,
          duration_seconds INTEGER, view_count INTEGER, like_count INTEGER, comment_count INTEGER,
          collect_count INTEGER, share_count INTEGER, hot_score REAL NOT NULL,
          raw_data_json TEXT NOT NULL, collected_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS contents_platform_id
          ON contents(platform, platform_content_id) WHERE platform_content_id IS NOT NULL;
        CREATE TABLE IF NOT EXISTS task_contents(
          task_id TEXT NOT NULL, content_id TEXT NOT NULL, rank INTEGER NOT NULL,
          PRIMARY KEY(task_id, content_id),
          FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE,
          FOREIGN KEY(content_id) REFERENCES contents(id) ON DELETE CASCADE
        );
        """
        guard sqlite3_exec(database, setup, nil, nil, nil) == SQLITE_OK else {
            throw ResearchDatabaseError.operationFailed("schema migration failed")
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func save(account: ResearchAccount) throws {
        let sql = """
        INSERT INTO accounts(id, platform, display_name, login_status, last_checked_at, created_at, updated_at)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          display_name=excluded.display_name,
          login_status=excluded.login_status,
          last_checked_at=excluded.last_checked_at,
          updated_at=excluded.updated_at;
        """
        try withStatement(sql) { statement in
            bind(account.id, at: 1, to: statement)
            bind(account.platform.rawValue, at: 2, to: statement)
            bind(account.displayName, at: 3, to: statement)
            bind(account.status.rawValue, at: 4, to: statement)
            bind(Self.dateString(account.lastCheckedAt), at: 5, to: statement)
            bind(Self.dateString(account.createdAt), at: 6, to: statement)
            bind(Self.dateString(account.updatedAt), at: 7, to: statement)
            try step(statement)
        }
    }

    func loadAccounts() throws -> [ResearchAccount] {
        try query("SELECT id, platform, display_name, login_status, last_checked_at, created_at, updated_at FROM accounts ORDER BY platform;") { row in
            guard let platform = ResearchPlatform(rawValue: text(row, 1)),
                  let status = ResearchLoginStatus(rawValue: text(row, 3)) else { return nil }
            return ResearchAccount(
                id: text(row, 0), platform: platform, displayName: text(row, 2), status: status,
                lastCheckedAt: date(row, 4), createdAt: date(row, 5), updatedAt: date(row, 6)
            )
        }
    }

    func deleteAccount(id: String) throws {
        try withStatement("DELETE FROM accounts WHERE id = ?;") { statement in
            bind(id, at: 1, to: statement)
            try step(statement)
        }
    }

    func save(task: ResearchTaskRecord) throws {
        let platforms = task.platforms.map(\.rawValue).joined(separator: ",")
        let sql = """
        INSERT INTO tasks(id, keyword, platforms_json, status, progress, error_message, created_at, started_at, completed_at)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          status=excluded.status, progress=excluded.progress, error_message=excluded.error_message,
          started_at=excluded.started_at, completed_at=excluded.completed_at;
        """
        try withStatement(sql) { statement in
            bind(task.id, at: 1, to: statement)
            bind(task.keyword, at: 2, to: statement)
            bind(platforms, at: 3, to: statement)
            bind(task.status.rawValue, at: 4, to: statement)
            sqlite3_bind_double(statement, 5, task.progress)
            bind(task.errorMessage, at: 6, to: statement)
            bind(task.createdAt.ISO8601Format(), at: 7, to: statement)
            bind(task.startedAt?.ISO8601Format(), at: 8, to: statement)
            bind(task.completedAt?.ISO8601Format(), at: 9, to: statement)
            try step(statement)
        }
    }

    func loadTasks(limit: Int = 20) throws -> [ResearchTaskRecord] {
        try query("SELECT id, keyword, platforms_json, status, progress, error_message, created_at, started_at, completed_at FROM tasks ORDER BY created_at DESC LIMIT \(max(1, limit));") { row in
            guard let status = ResearchTaskStatus(rawValue: text(row, 3)) else { return nil }
            return ResearchTaskRecord(
                id: text(row, 0), keyword: text(row, 1),
                platforms: text(row, 2).split(separator: ",").compactMap { ResearchPlatform(rawValue: String($0)) },
                status: status, progress: sqlite3_column_double(row, 4),
                errorMessage: optionalText(row, 5), createdAt: date(row, 6),
                startedAt: optionalDate(row, 7), completedAt: optionalDate(row, 8)
            )
        }
    }

    func save(contents: [ResearchContent], taskID: String) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for (rank, content) in contents.enumerated() {
                try save(content: content)
                try withStatement("INSERT OR REPLACE INTO task_contents(task_id, content_id, rank) VALUES(?, ?, ?);") { statement in
                    bind(taskID, at: 1, to: statement)
                    bind(content.id, at: 2, to: statement)
                    sqlite3_bind_int(statement, 3, Int32(rank + 1))
                    try step(statement)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func loadRecentContents(limit: Int = 200) throws -> [ResearchContent] {
        let sql = """
        SELECT id, platform, platform_content_id, keyword, content_type, title, description, author_name, author_url,
               content_url, cover_url, published_at, duration_seconds, view_count, like_count,
               comment_count, collect_count, share_count, hot_score, raw_data_json, collected_at
        FROM contents ORDER BY collected_at DESC, hot_score DESC LIMIT \(max(1, limit));
        """
        return try query(sql) { row in content(from: row) }
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "com.itou.chenggao", directoryHint: .isDirectory)
            .appending(path: "research.sqlite3")
    }

    private func save(content: ResearchContent) throws {
        let sql = """
        INSERT INTO contents(
          id, platform, platform_content_id, keyword, content_type, title, description, author_name,
          author_url, content_url, cover_url, published_at, duration_seconds, view_count, like_count,
          comment_count, collect_count, share_count, hot_score, raw_data_json, collected_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          title=excluded.title, description=excluded.description, author_name=excluded.author_name,
          author_url=excluded.author_url, content_url=excluded.content_url, cover_url=excluded.cover_url,
          published_at=excluded.published_at, duration_seconds=excluded.duration_seconds,
          view_count=excluded.view_count, like_count=excluded.like_count,
          comment_count=excluded.comment_count, collect_count=excluded.collect_count,
          share_count=excluded.share_count, hot_score=excluded.hot_score,
          content_type=excluded.content_type, raw_data_json=excluded.raw_data_json,
          collected_at=excluded.collected_at;
        """
        try withStatement(sql) { statement in
            let coverURL = ResearchContent.normalizedRemoteURL(content.coverURL, platform: content.platform)
            let imageURLs = (content.imageURLs ?? []).compactMap {
                ResearchContent.normalizedRemoteURL($0, platform: content.platform)
            }
            let imageData = try? JSONEncoder().encode(imageURLs)
            let imageJSON = imageData.map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            let strings: [(Int32, String?)] = [
                (1, content.id), (2, content.platform.rawValue), (3, content.platformContentID),
                (4, content.keyword), (5, content.resolvedContentKind.rawValue), (6, content.title),
                (7, content.description), (8, content.authorName), (9, content.authorURL?.absoluteString),
                (10, content.contentURL.absoluteString), (11, coverURL?.absoluteString),
                (12, content.publishedAt?.ISO8601Format())
            ]
            for (index, value) in strings { bind(value, at: index, to: statement) }
            bind(content.durationSeconds, at: 13, to: statement)
            bind(content.viewCount, at: 14, to: statement)
            bind(content.likeCount, at: 15, to: statement)
            bind(content.commentCount, at: 16, to: statement)
            bind(content.collectCount, at: 17, to: statement)
            bind(content.shareCount, at: 18, to: statement)
            sqlite3_bind_double(statement, 19, content.hotScore)
            bind(imageJSON, at: 20, to: statement)
            bind(content.collectedAt.ISO8601Format(), at: 21, to: statement)
            try step(statement)
        }
    }

    private func content(from row: OpaquePointer) -> ResearchContent? {
        guard let platform = ResearchPlatform(rawValue: text(row, 1)),
              let contentURL = URL(string: text(row, 9)) else { return nil }
        let imageURLs: [URL]? = optionalText(row, 19).flatMap { value in
            guard let data = value.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([URL].self, from: data).compactMap {
                ResearchContent.normalizedRemoteURL($0, platform: platform)
            }
        }
        return ResearchContent(
            id: text(row, 0), platform: platform, platformContentID: optionalText(row, 2),
            keyword: text(row, 3), title: text(row, 5), description: optionalText(row, 6),
            authorName: optionalText(row, 7), authorURL: optionalText(row, 8).flatMap(URL.init),
            contentURL: contentURL,
            coverURL: ResearchContent.normalizedRemoteURL(optionalText(row, 10), platform: platform),
            publishedAt: optionalDate(row, 11), durationSeconds: optionalInt(row, 12),
            viewCount: optionalInt(row, 13), likeCount: optionalInt(row, 14),
            commentCount: optionalInt(row, 15), collectCount: optionalInt(row, 16),
            shareCount: optionalInt(row, 17), hotScore: sqlite3_column_double(row, 18),
            collectedAt: date(row, 20),
            contentKind: ResearchContentKind(rawValue: text(row, 4)),
            imageURLs: imageURLs
        )
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func withStatement(_ sql: String, body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func query<T>(_ sql: String, transform: (OpaquePointer) -> T?) throws -> [T] {
        var values: [T] = []
        try withStatement(sql) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = transform(statement) { values.append(value) }
            }
        }
        return values
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Int?, at index: Int32, to statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    private func text(_ row: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(row, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ row: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(row, index) == SQLITE_NULL ? nil : text(row, index)
    }

    private func optionalInt(_ row: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(row, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(row, index))
    }

    private func date(_ row: OpaquePointer, _ index: Int32) -> Date {
        Self.parseDate(text(row, index)) ?? .distantPast
    }

    private func optionalDate(_ row: OpaquePointer, _ index: Int32) -> Date? {
        optionalText(row, index).flatMap(Self.parseDate)
    }

    private static func dateString(_ date: Date) -> String { date.ISO8601Format() }

    private static func parseDate(_ value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }

    private func databaseError() -> ResearchDatabaseError {
        let message = database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "unknown"
        return .operationFailed(message)
    }
}

enum ResearchDatabaseError: LocalizedError {
    case openFailed
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: "无法打开本地研究数据库。"
        case .operationFailed(let message): "研究数据库操作失败：\(message)"
        }
    }
}
