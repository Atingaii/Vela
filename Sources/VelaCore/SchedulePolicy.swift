import Foundation
import CoreFoundation

enum VelaSchedulePolicy {
    static func validate(_ input: JSON) throws -> JSON {
        let zone = input["timeZone"] ?? TimeZone.current.identifier
        guard let zone = zone as? String, TimeZone(identifier: zone) != nil else { throw VelaError("Unknown IANA time zone") }
        let policy = input["catchUp"] ?? "latest"
        guard let policy = policy as? String, ["skip", "latest", "all"].contains(policy) else { throw VelaError("catchUp must be skip, latest or all") }
        func integer(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = input[name] else { return fallback }
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                  range.contains(value.intValue) else { throw VelaError("Invalid \(name)") }
            return value.intValue
        }
        return ["timeZone": zone, "catchUp": policy,
                "catchUpLimit": try integer("catchUpLimit", default: 10, range: 1...100),
                "catchUpWindowHours": try integer("catchUpWindowHours", default: 24, range: 1...168)]
    }

    static func read(_ workflow: JSON) throws -> JSON {
        // Existing definitions retain their original no-catch-up authorization until edited.
        var input = workflow
        if input["catchUp"] == nil { input["catchUp"] = "skip" }
        return try validate(input)
    }
}
