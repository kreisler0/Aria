import Foundation

/// `devices.platform`.
public enum DevicePlatform: String, Codable, Hashable, Sendable {
    case web, ios, ipados, windows, macos, android
}

/// A row of `public.devices`: somewhere the account is signed in.
public struct DeviceRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var deviceId: String
    public var name: String
    public var platform: String
    public var createdAt: Date?
    public var lastSeenAt: Date

    public init(id: UUID = UUID(), deviceId: String, name: String, platform: String, createdAt: Date? = nil, lastSeenAt: Date) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    /// Checked in within the last two minutes (apps check in every minute while open).
    public func isOnline(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSeenAt) < 120
    }

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case name
        case platform
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}
