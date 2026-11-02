import Foundation

/// User-tunable behaviour, stored in UserDefaults.
public struct Settings: Codable, Equatable, Sendable {
    /// Photos newer than this many days stay on the phone when freeing up space.
    public var keepOnPhoneDays: Int = 30
    /// Previews of this many newest photos are kept for offline viewing (plus all favorites).
    public var offlinePreviewCount: Int = 250
    /// Back up originals only on Wi‑Fi.
    public var wifiOnly: Bool = true
    /// Back up automatically when the app opens and in the nightly run.
    public var autoBackup: Bool = true
    /// Downloaded originals kept on the phone (MB).
    public var originalsCacheMB: Int = 1024
    /// The user confirmed iCloud Photos is off (required before deleting from the phone).
    public var iCloudPhotosOffConfirmed: Bool = false
    /// Off shows every Live Photo as a still; each photo can also be turned off on its own from its LIVE menu.
    public var playLivePhotos: Bool = true

    public init() {}

    // Settings saved by an older version keep their values; fields added since then take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        keepOnPhoneDays = try c.decodeIfPresent(Int.self, forKey: .keepOnPhoneDays) ?? d.keepOnPhoneDays
        offlinePreviewCount = try c.decodeIfPresent(Int.self, forKey: .offlinePreviewCount) ?? d.offlinePreviewCount
        wifiOnly = try c.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? d.wifiOnly
        autoBackup = try c.decodeIfPresent(Bool.self, forKey: .autoBackup) ?? d.autoBackup
        originalsCacheMB = try c.decodeIfPresent(Int.self, forKey: .originalsCacheMB) ?? d.originalsCacheMB
        iCloudPhotosOffConfirmed = try c.decodeIfPresent(Bool.self, forKey: .iCloudPhotosOffConfirmed) ?? d.iCloudPhotosOffConfirmed
        playLivePhotos = try c.decodeIfPresent(Bool.self, forKey: .playLivePhotos) ?? d.playLivePhotos
    }

    private static let key = "bottomless.settings"
    public static func load(_ defaults: UserDefaults = .standard) -> Settings {
        guard let d = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }
    public func save(_ defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Settings.key) }
    }
}

/// The rule for "Free up space": backed up, not a favorite, and older than the keep window.
public enum FreeUpRule {
    public static func cutoff(keepDays: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(max(0, keepDays)) * 86400)
    }
}
