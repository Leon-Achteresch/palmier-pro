import Foundation
import Testing
@testable import PalmierPro

@Suite struct ToolSchemaTests {
    private var allTools: [AgentTool] { ToolDefinitions.mcpServer }

    private func properties(of schema: [String: Any]) -> [String: [String: Any]] {
        schema["properties"] as? [String: [String: Any]] ?? [:]
    }

    @Test func everyToolHasABoundedBrief() {
        for tool in allTools {
            #expect(!tool.brief.isEmpty, "\(tool.name.rawValue) needs a brief")
            #expect(tool.brief.count <= 400, "\(tool.name.rawValue) brief is not brief (\(tool.brief.count) chars)")
        }
    }

    @Test func everyTopLevelPropertyHasDescription() {
        for tool in allTools {
            for (name, prop) in properties(of: tool.inputSchema) {
                let desc = prop["description"] as? String
                #expect(desc?.isEmpty == false, "\(tool.name.rawValue).\(name) needs a description")
            }
        }
    }

    @Test func noSchemaReferencesTheTruncatableToolDescription() throws {
        for tool in allTools {
            let data = try JSONSerialization.data(withJSONObject: tool.inputSchema)
            let text = String(data: data, encoding: .utf8) ?? ""
            #expect(
                !text.lowercased().contains("see tool description") && !text.lowercased().contains("see the tool description"),
                "\(tool.name.rawValue): schemas must be self-contained — clients truncate long tool descriptions"
            )
        }
    }

    @Test func actionParametersEnumerateTheirValues() {
        for tool in allTools {
            guard let action = properties(of: tool.inputSchema)["action"] else { continue }
            let values = action["enum"] as? [String]
            #expect(values?.isEmpty == false, "\(tool.name.rawValue).action needs an enum")
        }
    }

    @Test func applyEffectSchemaCarriesEffectVocabulary() throws {
        let tool = try #require(allTools.first { $0.name == .applyEffect })
        let effects = try #require(properties(of: tool.inputSchema)["effects"])
        let items = try #require(effects["items"] as? [String: Any])
        let itemProps = try #require(items["properties"] as? [String: [String: Any]])
        let typeEnum = try #require(itemProps["type"]?["enum"] as? [String])
        let registryIds = EffectRegistry.all.map(\.id).filter { !$0.hasPrefix("color.") }
        #expect(Set(typeEnum) == Set(registryIds))
        #expect(typeEnum.allSatisfy { !$0.hasPrefix("color.") })
        let paramsDesc = try #require(itemProps["params"]?["description"] as? String)
        for id in registryIds {
            #expect(paramsDesc.contains(id), "params description must document \(id)")
        }
    }

    @Test func setKeyframesSchemaCarriesRowShapes() throws {
        let tool = try #require(allTools.first { $0.name == .setKeyframes })
        let props = properties(of: tool.inputSchema)
        for key in ["tracks", "keyframes"] {
            let desc = try #require(props[key]?["description"] as? String)
            #expect(desc.contains("TOP-LEFT"), "\(key) must carry the position semantics")
            for property in ["volumeDb", "opacity", "rotation", "position", "scale", "crop"] {
                #expect(desc.contains(property), "\(key) must document the \(property) row shape")
            }
        }
    }

    @Test func applyLayoutSlotDescriptionListsAllLayouts() throws {
        let tool = try #require(allTools.first { $0.name == .applyLayout })
        let props = properties(of: tool.inputSchema)
        let layouts = try #require(props["layout"]?["enum"] as? [String])
        let slots = try #require(props["slots"]?["items"] as? [String: Any])
        let slotProps = try #require(slots["properties"] as? [String: [String: Any]])
        let slotDesc = try #require(slotProps["slot"]?["description"] as? String)
        for layout in layouts where !layout.hasPrefix("pip_") && !layout.hasPrefix("grid_") {
            #expect(slotDesc.contains(layout), "slot description must cover \(layout)")
        }
        #expect(slotDesc.contains("r1c1"))
        #expect(slotDesc.contains("inset"))
    }

    @Test func everyToolHasNonEmptyDescriptionAndUniqueName() {
        var seen: Set<String> = []
        for tool in allTools {
            #expect(!tool.description.isEmpty, "\(tool.name.rawValue)")
            #expect(seen.insert(tool.name.rawValue).inserted, "duplicate tool \(tool.name.rawValue)")
        }
    }
}
