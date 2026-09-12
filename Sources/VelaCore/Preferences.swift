import Foundation
import CoreFoundation

/// Shared preference defaults keep the CLI, dashboard and native host consistent.
public enum VelaPreferences {
    public static let defaults: JSON = [
        "id": "preferences", "telemetry": false, "notifications": false,
        "notificationSound": true, "notifyApprovals": true,
        "notifyCompleted": true, "notifyErrors": true,
        "analysisEnabled": false, "launchAtLogin": false
    ]
    private static let allowed = Set(defaults.keys).subtracting(["id", "telemetry"])

    public static func validate(_ changes: JSON) throws {
        // NSNumber also bridges integer 0/1 to Bool. Require an actual JSON boolean.
        guard Set(changes.keys).isSubset(of: allowed), changes.values.allSatisfy({ value in
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }) else { throw VelaError("设置包含不支持的字段或非布尔值") }
    }

    public static func read(from store: VelaStore) throws -> JSON {
        var result = defaults
        if let saved = try store.get("settings", "preferences") {
            result.merge(saved) { _, value in value }
            for key in allowed {
                if let number = saved[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    result[key] = number.boolValue
                } else { result[key] = defaults[key] }
            }
        }
        result["telemetry"] = false
        return result
    }

    @discardableResult public static func save(_ changes: JSON, in store: VelaStore) throws -> JSON {
        try validate(changes)
        var preferences = try read(from: store)
        preferences.merge(changes) { _, value in value }
        return try store.put("settings", preferences)
    }
}
