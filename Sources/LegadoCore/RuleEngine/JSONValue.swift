import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public static func decode(data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public var stringValue: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value ? String(format: "%.0f", value) : String(value)
        case .bool(let value): return String(value)
        case .null: return ""
        case .object, .array:
            guard let data = try? JSONEncoder().encode(self) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let value) = self else { return nil }
        return value[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let value) = self else { return nil }
        let resolved = index >= 0 ? index : value.count + index
        guard value.indices.contains(resolved) else { return nil }
        return value[resolved]
    }
}

public extension JSONValue {
    var foundationObject: Any {
        switch self {
        case .object(let value): value.mapValues(\.foundationObject)
        case .array(let value): value.map(\.foundationObject)
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }

    static func bridge(_ value: Any?) -> JSONValue {
        guard let value else { return .null }
        if value is NSNull { return .null }
        if let value = value as? JSONValue { return value }
        if let value = value as? String { return .string(value) }
        // NSNumber(0/1) also casts to Bool. Inspect its CF type first so
        // JavaScript page arithmetic and numeric IDs remain numbers.
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        }
        if let value = value as? [Any] { return .array(value.map(bridge)) }
        if let value = value as? [String: Any] { return .object(value.mapValues(bridge)) }
        if let value = value as? NSDictionary {
            var object: [String: JSONValue] = [:]
            for (key, item) in value { object[String(describing: key)] = bridge(item) }
            return .object(object)
        }
        if let value = value as? NSArray { return .array(value.map(bridge)) }
        return .string(String(describing: value))
    }
}
