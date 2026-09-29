import Foundation

/// A loosely typed JSON value, so NJ Transit's responses can be read the way
/// v4 read them in JavaScript (`String(value ?? "")`, `value === true`, `a || b`)
/// while staying `Sendable` for structured concurrency.
public indirect enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    /// Parse raw bytes. Throws when the body is not JSON at all (an HTML error
    /// page, for instance), like `await res.json()` does.
    public static func parse(_ data: Data) throws -> JSON {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSON(any: raw)
    }

    public init(any value: Any?) {
        guard let value else {
            self = .null
            return
        }
        switch value {
        case is NSNull:
            self = .null
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let list as [Any]:
            self = .array(list.map { JSON(any: $0) })
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSON(any: $0) })
        default:
            self = .null
        }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    /// The elements when this is an array, otherwise nil.
    public var arrayValue: [JSON]? {
        if case .array(let list) = self { return list }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// `value === true`
    public var isTrue: Bool {
        if case .bool(true) = self { return true }
        return false
    }

    /// JavaScript truthiness.
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let flag): return flag
        case .number(let number): return number != 0 && !number.isNaN
        case .string(let text): return !text.isEmpty
        case .array, .object: return true
        }
    }

    /// `String(value)` for the scalar values an API returns (null becomes "").
    public var jsString: String {
        switch self {
        case .null: return ""
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return JSON.format(number)
        case .string(let text): return text
        case .array(let list): return list.map(\.jsString).joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    static func format(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.rounded() == number, abs(number) < 1e15 {
            return String(Int64(number))
        }
        return String(number)
    }
}

extension Optional where Wrapped == JSON {
    /// `String(value ?? "")`
    var jsString: String { self?.jsString ?? "" }
    var truthy: Bool { self?.truthy ?? false }
}
