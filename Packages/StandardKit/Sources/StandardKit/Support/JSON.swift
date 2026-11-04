import Foundation

/// A small JSON value type for building schemas and request bodies.
public indirect enum JSON: Codable, Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByArrayLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral
{
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSON])
    case object([String: JSON])
    case null

    public init(stringLiteral value: String) { self = .string(value) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// Builders for strict JSON schemas (every property required, no extras).
public enum Schema {
    public static func object(_ properties: KeyValuePairs<String, JSON>) -> JSON {
        var props: [String: JSON] = [:]
        var required: [JSON] = []
        for (k, v) in properties {
            props[k] = v
            required.append(.string(k))
        }
        return ["type": "object", "properties": .object(props), "required": .array(required),
            "additionalProperties": false]
    }

    /// Same as `object(_:)` for properties assembled at runtime (order doesn't matter to the API).
    public static func object(_ properties: [String: JSON]) -> JSON {
        ["type": "object", "properties": .object(properties), "required": .array(properties.keys.sorted().map { .string($0) }),
            "additionalProperties": false]
    }

    public static func array(_ items: JSON, min: Int? = nil, max: Int? = nil) -> JSON {
        var o: [String: JSON] = ["type": "array", "items": items]
        if let min { o["minItems"] = .number(Double(min)) }
        if let max { o["maxItems"] = .number(Double(max)) }
        return .object(o)
    }

    public static func string(_ description: String? = nil) -> JSON {
        guard let description else { return ["type": "string"] }
        return ["type": "string", "description": .string(description)]
    }

    public static func integer(_ description: String? = nil) -> JSON {
        guard let description else { return ["type": "integer"] }
        return ["type": "integer", "description": .string(description)]
    }

    public static func number() -> JSON { ["type": "number"] }
    public static let boolean: JSON = ["type": "boolean"]

    public static func enumeration(_ values: [String]) -> JSON {
        ["type": "string", "enum": .array(values.map { .string($0) })]
    }

    public static func nullable(_ schema: JSON) -> JSON {
        ["anyOf": [schema, ["type": "null"]]]
    }
}
