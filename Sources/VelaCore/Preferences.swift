import Foundation
import CoreFoundation

/// Shared preference defaults keep the CLI, dashboard and native host consistent.
public enum VelaPreferences {
    public static let supportedLocales: Set<String> = ["zh-CN", "en"]
    public static let defaultLocale = "zh-CN"
    public static let defaults: JSON = [
        "id": "preferences", "telemetry": false, "notifications": false,
        "notificationSound": true, "notifyApprovals": true,
        "notifyCompleted": true, "notifyErrors": true,
        "analysisEnabled": false, "launchAtLogin": false,
        "locale": defaultLocale,
        // New approvals expire after seven days unless a local user explicitly
        // changes this policy. Existing records intentionally have no field.
        "approvalExpirySeconds": 604_800
    ]
    private static let allowed = Set(defaults.keys).subtracting(["id", "telemetry"])
    private static let integerKeys: Set<String> = ["approvalExpirySeconds"]
    private static let booleanKeys = allowed.subtracting(["locale"]).subtracting(integerKeys)

    public static func validate(_ changes: JSON) throws {
        // NSNumber also bridges integer 0/1 to Bool. Require an actual JSON boolean.
        guard Set(changes.keys).isSubset(of: allowed) else {
            throw VelaError("设置包含不支持的字段")
        }
        if let locale = changes["locale"] {
            guard let locale = locale as? String, supportedLocales.contains(locale) else {
                throw VelaError("Unsupported locale; expected zh-CN or en")
            }
        }
        guard changes.filter({ booleanKeys.contains($0.key) }).values.allSatisfy({ value in
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }) else { throw VelaError("设置包含不支持的字段或非布尔值") }
        if let expiry = changes["approvalExpirySeconds"] {
            guard let number = expiry as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  (0...31_536_000).contains(number.intValue), Double(number.intValue) == number.doubleValue else {
                throw VelaError("approvalExpirySeconds must be an integer from 0 to 31536000")
            }
        }
    }

    public static func read(from store: VelaStore) throws -> JSON {
        var result = defaults
        if let saved = try store.get("settings", "preferences") {
            result.merge(saved) { _, value in value }
            for key in booleanKeys {
                if let number = saved[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    result[key] = number.boolValue
                } else { result[key] = defaults[key] }
            }
            if let locale = saved["locale"] as? String, supportedLocales.contains(locale) {
                result["locale"] = locale
            } else { result["locale"] = defaultLocale }
            if let number = saved["approvalExpirySeconds"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
               number.doubleValue.rounded() == number.doubleValue,
               (0...31_536_000).contains(number.intValue), Double(number.intValue) == number.doubleValue {
                result["approvalExpirySeconds"] = number.intValue
            } else { result["approvalExpirySeconds"] = defaults["approvalExpirySeconds"] }
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
