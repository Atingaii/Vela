import Foundation
import CoreFoundation

/// Shared preference defaults keep the CLI, dashboard and native host consistent.
public enum VelaPreferences {
    public static let supportedLocales: Set<String> = ["zh-CN", "en"]
    public static let supportedThemes: Set<String> = ["system", "light", "dark"]
    public static let supportedDensities: Set<String> = ["standard", "compact"]
    public static let defaultLocale = "zh-CN"
    public static let defaultTheme = "system"
    public static let defaultDensity = "standard"
    public static let defaultZoomPercent = 100
    public static let defaults: JSON = [
        "id": "preferences", "telemetry": false, "notifications": false,
        "notificationSound": true, "notifyApprovals": true,
        "notifyCompleted": true, "notifyErrors": true,
        "analysisEnabled": false, "launchAtLogin": false,
        "locale": defaultLocale,
        "theme": defaultTheme,
        "density": defaultDensity,
        "zoomPercent": defaultZoomPercent,
        // New approvals expire after seven days unless a local user explicitly
        // changes this policy. Existing records intentionally have no field.
        "approvalExpirySeconds": 604_800
    ]
    private static let allowed = Set(defaults.keys).subtracting(["id", "telemetry"])
    private static let integerKeys: Set<String> = ["approvalExpirySeconds", "zoomPercent"]
    private static let stringEnumKeys: Set<String> = ["locale", "theme", "density"]
    private static let booleanKeys = allowed.subtracting(stringEnumKeys).subtracting(integerKeys)

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
        if let theme = changes["theme"] {
            guard let theme = theme as? String, supportedThemes.contains(theme) else {
                throw VelaError("Unsupported theme; expected system, light or dark")
            }
        }
        if let density = changes["density"] {
            guard let density = density as? String, supportedDensities.contains(density) else {
                throw VelaError("Unsupported density; expected standard or compact")
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
        if let zoom = changes["zoomPercent"] {
            guard let number = zoom as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  (90...150).contains(number.intValue), Double(number.intValue) == number.doubleValue else {
                throw VelaError("zoomPercent must be an integer from 90 to 150")
            }
        }
    }

    private static func normalized(_ saved: JSON?) -> JSON {
        var result = defaults
        if let saved {
            result.merge(saved) { _, value in value }
            for key in booleanKeys {
                if let number = saved[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    result[key] = number.boolValue
                } else { result[key] = defaults[key] }
            }
            if let locale = saved["locale"] as? String, supportedLocales.contains(locale) {
                result["locale"] = locale
            } else { result["locale"] = defaultLocale }
            if let theme = saved["theme"] as? String, supportedThemes.contains(theme) {
                result["theme"] = theme
            } else { result["theme"] = defaultTheme }
            if let density = saved["density"] as? String, supportedDensities.contains(density) {
                result["density"] = density
            } else { result["density"] = defaultDensity }
            if let number = saved["approvalExpirySeconds"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
               number.doubleValue.rounded() == number.doubleValue,
               (0...31_536_000).contains(number.intValue), Double(number.intValue) == number.doubleValue {
                result["approvalExpirySeconds"] = number.intValue
            } else { result["approvalExpirySeconds"] = defaults["approvalExpirySeconds"] }
            if let number = saved["zoomPercent"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
               number.doubleValue.rounded() == number.doubleValue,
               (90...150).contains(number.intValue), Double(number.intValue) == number.doubleValue {
                result["zoomPercent"] = number.intValue
            } else { result["zoomPercent"] = defaultZoomPercent }
        }
        result["telemetry"] = false
        return result
    }

    public static func read(from store: VelaStore) throws -> JSON {
        normalized(try store.get("settings", "preferences"))
    }

    @discardableResult public static func save(_ changes: JSON, in store: VelaStore) throws -> JSON {
        try save(changes, in: store, afterReadBeforePersistForTesting: nil)
    }

    /// Internal seam lets the Core test deterministically replace the persisted
    /// object after this helper has captured its snapshot. It is not an RPC or
    /// public Store transaction interface.
    @discardableResult static func save(_ changes: JSON, in store: VelaStore, afterReadBeforePersistForTesting: (() throws -> Void)?) throws -> JSON {
        try validate(changes)
        let saved = try store.get("settings", "preferences")
        var preferences = normalized(saved)
        preferences.merge(changes) { _, value in value }
        // JSON number values have no integer wire type. Store accepted whole
        // numeric zoom input canonically so later reads and clients agree.
        if let number = changes["zoomPercent"] as? NSNumber {
            preferences["zoomPercent"] = number.intValue
        }
        try afterReadBeforePersistForTesting?()
        let expecting = try saved.map { [("settings", "preferences", stableHash(try jsonString($0)))] } ?? []
        let expectingAbsent = saved == nil ? [("settings", "preferences")] : []
        return try store.putBatch([("settings", preferences)], expecting: expecting, expectingAbsent: expectingAbsent)[0]
    }
}
