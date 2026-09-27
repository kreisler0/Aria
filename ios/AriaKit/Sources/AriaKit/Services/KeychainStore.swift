import Foundation
#if canImport(Security)
import Security
#endif

/// Small wrapper over the iOS Keychain (generic passwords). Used for the OpenRouter API
/// key (app-only) and the Supabase session (shared with the widget extension through the
/// App Group access group). On platforms without Security.framework (Linux, for tests)
/// it falls back to process memory.
public final class KeychainStore: @unchecked Sendable {
    public let service: String
    public let accessGroup: String?
    private let lock = NSLock()
    /// Flips to false if the access group is unusable (e.g. unsigned simulator builds).
    private var useAccessGroup: Bool

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        self.useAccessGroup = accessGroup != nil
    }

    public struct KeychainError: Error, Equatable, LocalizedError {
        public let status: Int32
        public var errorDescription: String? { "Keychain error \(status)" }
    }

    public func string(for account: String) -> String? {
        data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setString(_ value: String?, for account: String) throws {
        try setData(value.map { Data($0.utf8) }, for: account)
    }

#if canImport(Security)
    public func data(for account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement, useAccessGroup {
            useAccessGroup = false
            query = baseQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Stores `data` (or deletes the item when `nil`). Items stay readable after the first
    /// unlock so widgets and background refresh can use them.
    public func setData(_ data: Data?, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var status = write(data, account: account)
        if status == errSecMissingEntitlement, useAccessGroup {
            useAccessGroup = false
            status = write(data, account: account)
        }
        guard status == errSecSuccess || (data == nil && status == errSecItemNotFound) else {
            throw KeychainError(status: status)
        }
    }

    private func write(_ data: Data?, account: String) -> OSStatus {
        let query = baseQuery(account: account)
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard let data else { return deleteStatus }
        if deleteStatus == errSecMissingEntitlement { return deleteStatus }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useAccessGroup, let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
#else
    nonisolated(unsafe) private static var memory: [String: Data] = [:]
    private static let memoryLock = NSLock()

    private func memoryKey(_ account: String) -> String { "\(accessGroup ?? "-")|\(service)|\(account)" }

    public func data(for account: String) -> Data? {
        Self.memoryLock.lock()
        defer { Self.memoryLock.unlock() }
        return Self.memory[memoryKey(account)]
    }

    public func setData(_ data: Data?, for account: String) throws {
        Self.memoryLock.lock()
        defer { Self.memoryLock.unlock() }
        Self.memory[memoryKey(account)] = data
    }
#endif
}

/// The Supabase session, kept in the Keychain so the widget extension shares it.
public final class KeychainSessionStore: SessionStore, @unchecked Sendable {
    private let keychain: KeychainStore
    private let account: String
    private let lock = NSLock()
    private var fallback: AuthSession?
    private var keychainFailed = false

    public init(keychain: KeychainStore, account: String = "supabase.session") {
        self.keychain = keychain
        self.account = account
    }

    public func loadSession() -> AuthSession? {
        lock.lock()
        defer { lock.unlock() }
        if let data = keychain.data(for: account),
           let session = try? AriaJSON.makeDecoder().decode(AuthSession.self, from: data) {
            return session
        }
        return keychainFailed ? fallback : nil
    }

    public func saveSession(_ session: AuthSession?) {
        lock.lock()
        defer { lock.unlock() }
        fallback = session
        do {
            try keychain.setData(try session.map { try AriaJSON.makeEncoder().encode($0) }, for: account)
            keychainFailed = false
        } catch {
            // Keep the session for this process rather than signing the user out.
            keychainFailed = true
        }
    }
}

/// The user's OpenRouter API key. Lives only in the Keychain — never in Supabase.
public struct OpenRouterKeyStore: Sendable {
    private let keychain: KeychainStore
    private let account = "openrouter.apiKey"

    public init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    public var apiKey: String? {
        keychain.string(for: account).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func save(_ key: String?) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        try keychain.setString((trimmed?.isEmpty ?? true) ? nil : trimmed, for: account)
    }
}
