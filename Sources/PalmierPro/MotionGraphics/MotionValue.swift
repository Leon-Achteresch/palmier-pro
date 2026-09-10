import Foundation

indirect enum MotionValue: Codable, Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case array([MotionValue])
    case object([String: MotionValue])
    case null

    init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= 32 else { throw MotionSceneError.invalidField("property nesting is too deep") }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MotionValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: MotionValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }

    func validated(depth: Int = 0) throws {
        guard depth < 16 else { throw MotionSceneError.invalidField("property nesting exceeds 16 levels") }
        switch self {
        case .number(let value):
            guard value.isFinite, abs(value) <= 1e12 else { throw MotionSceneError.invalidField("property must be finite and within ±1e12") }
        case .string(let value):
            guard value.utf8.count <= 16 * 1024 * 1024 else { throw MotionSceneError.invalidField("property string is too large") }
        case .array(let values):
            guard values.count <= 4096 else { throw MotionSceneError.invalidField("property array is too large") }
            for value in values { try value.validated(depth: depth + 1) }
        case .object(let values):
            guard values.count <= 512 else { throw MotionSceneError.invalidField("property object is too large") }
            for (key, value) in values {
                guard Self.isSafeKey(key) else { throw MotionSceneError.invalidField("invalid property key") }
                try value.validated(depth: depth + 1)
            }
        case .null, .bool: break
        }
    }

    static func isSafeKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 128 && !["__proto__", "prototype", "constructor"].contains(key)
    }
}

struct MotionPropSchema: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case number, string, color, boolean, choice, asset
    }

    var id: String
    var label: String
    var kind: Kind
    var defaultValue: MotionValue
    var minimum: Double?
    var maximum: Double?
    var choices: [String] = []
    var animatable: Bool = true

    func validate(_ value: MotionValue) throws {
        try value.validated()
        let valid: Bool
        switch kind {
        case .number:
            valid = value.number.map { $0 >= (minimum ?? -1e12) && $0 <= (maximum ?? 1e12) } ?? false
        case .boolean: valid = value.bool != nil
        case .choice: valid = value.string.map(choices.contains) ?? false
        case .color: valid = value.string.map(MotionProperty.isColor) ?? false
        case .asset: valid = value.string.map { $0.isEmpty || $0.hasPrefix("data:") } ?? false
        case .string: valid = value.string != nil
        }
        guard valid else { throw MotionSceneError.invalidField("invalid value for property '\(id)'") }
    }
}
