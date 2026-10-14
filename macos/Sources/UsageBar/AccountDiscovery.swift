import CryptoKit
import Foundation
import SQLite3

/// Finds every signed-in Cursor and Claude Code account on this Mac.
///
/// - Cursor: the default user-data dir plus any `~/.cursor-<name>` dir
///   (what `cursor --user-data-dir ~/.cursor-<name>` creates).
/// - Claude: `~/.claude` plus any `~/.claude-<name>` dir
///   (what `CLAUDE_CONFIG_DIR=~/.claude-<name> claude` creates).
enum AccountDiscovery {
    static func discover() -> [Account] {
        cursorAccounts() + claudeAccounts()
    }

    private static var home: String { NSHomeDirectory() }

    private static func homeDirs(withPrefix prefix: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().compactMap { name in
            var isDir: ObjCBool = false
            let path = home + "/" + name
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? path : nil
        }
    }

    // MARK: Cursor

    private static func cursorAccounts() -> [Account] {
        var candidates: [(db: String, name: String, isDefault: Bool)] = []
        let support = home + "/Library/Application Support"
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: support)) ?? []).sorted() where name.hasPrefix("Cursor") {
            let label = name == "Cursor" ? "Cursor" : String(name.dropFirst("Cursor".count)).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            candidates.append((support + "/" + name + "/User/globalStorage/state.vscdb", label, name == "Cursor"))
        }
        for dir in homeDirs(withPrefix: ".cursor-") {
            let label = String((dir as NSString).lastPathComponent.dropFirst(".cursor-".count))
            candidates.append((dir + "/User/globalStorage/state.vscdb", label, false))
        }

        var byKey: [String: Account] = [:]
        var order: [String] = []
        for c in candidates where FileManager.default.fileExists(atPath: c.db) {
            let values = readCursorValues(c.db, keys: ["cursorAuth/accessToken", "cursorAuth/cachedEmail"])
            guard let token = values["cursorAuth/accessToken"], !token.isEmpty else { continue }
            let email = values["cursorAuth/cachedEmail"]
            let account = Account(provider: .cursor, source: c.db, isDefault: c.isDefault, email: email, name: c.name)
            let key = email ?? c.db
            if let existing = byKey[key] {
                // Same login in two folders: prefer the explicitly named one (e.g. "personal" over the default).
                if existing.isDefault && !account.isDefault { byKey[key] = account }
            } else {
                byKey[key] = account
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    static func readCursorValues(_ path: String, keys: [String]) -> [String: String] {
        var db: OpaquePointer?
        let uri = "file:" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        var result: [String: String] = [:]
        for key in keys {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key=?;", -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) {
                result[key] = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    // MARK: Claude

    private static func claudeAccounts() -> [Account] {
        var dirs = [(home + "/.claude", true)]
        dirs += homeDirs(withPrefix: ".claude-").map { ($0, false) }

        var seen = Set<String>()
        var accounts: [Account] = []
        for (dir, isDefault) in dirs where ClaudeProvider.hasCredentials(configDir: dir, isDefault: isDefault) {
            // The default dir keeps its settings next to it (~/.claude.json), custom dirs inside.
            let configFile = isDefault ? home + "/.claude.json" : dir + "/.claude.json"
            var email: String?
            if let data = FileManager.default.contents(atPath: configFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let oauth = json["oauthAccount"] as? [String: Any] {
                email = oauth["emailAddress"] as? String
            }
            if let email, !seen.insert(email).inserted { continue }
            let name = isDefault ? "Claude" : String((dir as NSString).lastPathComponent.dropFirst(".claude-".count))
            accounts.append(Account(provider: .claude, source: dir, isDefault: isDefault, email: email, name: name))
        }
        return accounts
    }

    /// Claude Code's Keychain service name: a non-default config dir gets
    /// `-<first 8 hex chars of sha256(path)>` appended.
    static func claudeKeychainServices(configDir: String, isDefault: Bool) -> [String] {
        let base = "Claude Code-credentials"
        func hashed(_ path: String) -> String {
            let digest = SHA256.hash(data: Data(path.precomposedStringWithCanonicalMapping.utf8))
            return base + "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        }
        if isDefault { return [base, hashed(configDir)] }
        return [hashed(configDir), hashed(configDir + "/")]
    }

    /// Time of the newest Claude Code transcript write — i.e. the last request sent from this account.
    static func claudeLastActivity(configDir: String) -> Date? {
        let projects = URL(fileURLWithPath: configDir + "/projects", isDirectory: true)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let folders = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: keys) else { return nil }
        var newest: Date?
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                if let date = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate,
                   newest.map({ date > $0 }) ?? true {
                    newest = date
                }
            }
        }
        return newest
    }
}
