import Foundation

/// What the app and its widgets share through the App Group, plus the app's
/// own remembered settings. v4 kept the same things in localStorage:
/// the destination, the pin (with its trip, for 3 hours) and the theme.
/// Direction is never stored; it is derived from the clock.
public final class SharedStore {
    public static let defaultAppGroup = "group.com.lasmith1689.GlassRail"

    enum Key {
        static let destination = "glass-rail.destinationId"
        static let pin = "glass-rail-pin"
        static let theme = "glass-rail-theme"
        static let snapshot = "glass-rail.snapshot"
    }

    public let defaults: UserDefaults

    /// `appGroup` falls back to the standard defaults when the group container
    /// is unavailable (an unsigned Simulator build, for instance).
    public init(appGroup: String? = SharedStore.defaultAppGroup) {
        if let appGroup, let shared = UserDefaults(suiteName: appGroup) {
            defaults = shared
        } else {
            defaults = .standard
        }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The app group named in the bundle's Info.plist (`GlassRailAppGroup`).
    public static func appGroup(in bundle: Bundle = .main) -> String {
        let value = bundle.object(forInfoDictionaryKey: "GlassRailAppGroup") as? String ?? ""
        return value.isEmpty || value.contains("$(") ? defaultAppGroup : value
    }

    // MARK: Destination (shared with the widgets)

    public var destinationId: String {
        get {
            let saved = defaults.string(forKey: Key.destination) ?? ""
            return UserConfig.destinationIds.contains(saved) ? saved : UserConfig.destinationIds[0]
        }
        set {
            guard UserConfig.destinationIds.contains(newValue) else { return }
            defaults.set(newValue, forKey: Key.destination)
        }
    }

    // MARK: Pin (remembered for PinStore.ttl)

    public var pinRaw: String? {
        get { defaults.string(forKey: Key.pin) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.pin) } else { defaults.removeObject(forKey: Key.pin) }
        }
    }

    public func restorePin(now: Date) -> RestoredPin? {
        PinStore.parse(pinRaw, now: now)
    }

    public func savePin(_ pin: Pin?, trip: Trip?, now: Date) {
        pinRaw = pin.map { PinStore.serialize($0, trip: trip, now: now) }
    }

    // MARK: Theme

    public var themeId: String? {
        get { defaults.string(forKey: Key.theme) }
        set { defaults.set(newValue, forKey: Key.theme) }
    }

    // MARK: Last live data (lets the widget fall back and the app start warm)

    public struct Snapshot: Codable, Equatable, Sendable {
        public var payload: Payload
        public var runs: Runs

        public init(payload: Payload, runs: Runs) {
            self.payload = payload
            self.runs = runs
        }
    }

    public var snapshot: Snapshot? {
        get {
            guard let data = defaults.data(forKey: Key.snapshot) else { return nil }
            return try? GlassRailJSON.decoder().decode(Snapshot.self, from: data)
        }
        set {
            guard let newValue, let data = try? GlassRailJSON.encoder().encode(newValue) else {
                defaults.removeObject(forKey: Key.snapshot)
                return
            }
            defaults.set(data, forKey: Key.snapshot)
        }
    }
}
