import Foundation

/// Gemini accepts only a narrow OpenAPI subset: one type per node, `properties` only on objects,
/// and every array must declare typed `items`. Other OpenRouter providers take the schemas as written.
enum GeminiSchemaSanitizer {
    static func applies(to modelId: String) -> Bool { modelId.hasPrefix("google/") }

    static func sanitize(_ schema: [String: Any]) -> [String: Any] {
        guard var node = normalize(schema) as? [String: Any] else { return schema }
        if node["type"] == nil, node["anyOf"] == nil { node["type"] = "object" }
        return node
    }

    private static func normalize(_ value: Any) -> Any {
        guard var node = value as? [String: Any] else { return value }

        if let types = node["type"] as? [String], types.count > 1 {
            node.removeValue(forKey: "type")
            let shared = node.filter { $0.key == "description" }
            var branches: [[String: Any]] = []
            for type in types {
                var branch = node
                branch.removeValue(forKey: "description")
                branch["type"] = type
                if type != "object" {
                    branch.removeValue(forKey: "properties")
                    branch.removeValue(forKey: "required")
                    branch.removeValue(forKey: "additionalProperties")
                }
                if type != "array" { branch.removeValue(forKey: "items") }
                branches.append(normalize(branch) as? [String: Any] ?? branch)
            }
            var union = shared
            union["anyOf"] = branches
            return union
        }
        if let types = node["type"] as? [String] { node["type"] = types.first ?? "string" }

        let type = node["type"] as? String
        if type != "object" {
            node.removeValue(forKey: "properties")
            node.removeValue(forKey: "required")
        }
        node.removeValue(forKey: "additionalProperties")

        if type == "array" {
            let items = node["items"] as? [String: Any] ?? [:]
            let typed = items["type"] != nil || items["anyOf"] != nil
            node["items"] = normalize(typed ? items : items.merging(mixedScalar) { current, _ in current })
        }
        if let properties = node["properties"] as? [String: Any] {
            node["properties"] = properties.mapValues(normalize)
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let branches = node[key] as? [[String: Any]] {
                node[key] = branches.map { normalize($0) as? [String: Any] ?? $0 }
            }
        }
        return node
    }

    /// A row of mixed scalars (keyframe rows, index spans) is the only untyped array we ship.
    private static var mixedScalar: [String: Any] { ["anyOf": [["type": "number"], ["type": "string"]]] }
}
