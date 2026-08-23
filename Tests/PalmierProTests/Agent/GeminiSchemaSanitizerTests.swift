import Foundation
import Testing
@testable import PalmierPro

@Suite("Gemini schema sanitizer")
struct GeminiSchemaSanitizerTests {
    private func violations(_ node: Any, path: String) -> [String] {
        guard let dict = node as? [String: Any] else { return [] }
        var found: [String] = []
        let type = dict["type"]
        if type is [Any] { found.append("\(path): union type") }
        if dict["additionalProperties"] != nil { found.append("\(path): additionalProperties") }
        if dict["properties"] != nil, (type as? String) != "object" { found.append("\(path): properties on non-object") }
        if (type as? String) == "array" {
            guard let items = dict["items"] as? [String: Any], items["type"] != nil || items["anyOf"] != nil else {
                return found + ["\(path): array items missing type"]
            }
            found += violations(items, path: path + ".items")
        }
        for (key, value) in dict["properties"] as? [String: Any] ?? [:] {
            found += violations(value, path: path + ".\(key)")
        }
        for branch in dict["anyOf"] as? [[String: Any]] ?? [] {
            found += violations(branch, path: path + ".anyOf")
        }
        return found
    }

    @Test("Every tool schema is Gemini-safe after sanitizing")
    func allToolSchemas() {
        let found = ToolDefinitions.all.flatMap {
            violations(GeminiSchemaSanitizer.sanitize($0.inputSchema), path: $0.name.rawValue)
        }
        #expect(found.isEmpty, "\(found)")
    }

    @Test("Raw schemas do violate the subset, so the sanitizer is load-bearing")
    func rawSchemasNeedSanitizing() {
        let found = ToolDefinitions.all.flatMap { violations($0.inputSchema, path: $0.name.rawValue) }
        #expect(!found.isEmpty)
    }

    @Test("Union types become anyOf branches, properties kept on the object branch")
    func unionBecomesAnyOf() {
        let sanitized = GeminiSchemaSanitizer.sanitize([
            "type": "object",
            "properties": ["remove": [
                "type": "array",
                "items": ["type": ["integer", "object"], "properties": ["trackId": ["type": "string"]]],
            ]],
        ])
        let items = ((sanitized["properties"] as? [String: Any])?["remove"] as? [String: Any])?["items"] as? [String: Any]
        let branches = items?["anyOf"] as? [[String: Any]]
        #expect(branches?.count == 2)
        #expect(branches?.first?["type"] as? String == "integer")
        #expect(branches?.first?["properties"] == nil)
        #expect(branches?.last?["properties"] != nil)
    }

    @Test("Only Google models are sanitized")
    func gatedOnGoogle() {
        #expect(GeminiSchemaSanitizer.applies(to: "google/gemini-3.6-flash"))
        #expect(!GeminiSchemaSanitizer.applies(to: "anthropic/claude-sonnet-5"))
    }
}
