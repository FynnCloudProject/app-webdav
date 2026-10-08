import Foundation

actor TokenCache {
    static let shared = TokenCache()

    private struct Entry {
        let token: String
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]

    private init() {}

    func get(_ key: String) -> String? {
        guard let entry = entries[key] else { return nil }
        if entry.expiresAt > Date().addingTimeInterval(30) {
            return entry.token
        }
        entries.removeValue(forKey: key)
        return nil
    }

    func set(_ key: String, token: String, expiresIn: Int) {
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        entries[key] = Entry(token: token, expiresAt: expiresAt)
    }

    func remove(_ key: String) {
        entries.removeValue(forKey: key)
    }
}
