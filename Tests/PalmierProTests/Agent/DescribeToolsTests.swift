import Foundation
import Testing
@testable import PalmierPro

@Suite @MainActor struct DescribeToolsTests {
    @Test func returnsFullDocsForNamedTools() async {
        let harness = ToolHarness()
        let result = await harness.runRaw("describe_tools", args: ["names": ["set_keyframes", "apply_color"]])
        #expect(result.isError == false)
        let text = ToolHarness.textOf(result)
        #expect(text.contains("# set_keyframes"))
        #expect(text.contains("# apply_color"))
        let full = ToolDefinitions.all.first { $0.name == .setKeyframes }
        #expect(text.contains(full?.description ?? "MISSING"))
    }

    @Test func listsIndexWithoutNames() async {
        let harness = ToolHarness()
        let result = await harness.runRaw("describe_tools")
        #expect(result.isError == false)
        let text = ToolHarness.textOf(result)
        for tool in ToolDefinitions.mcpServer {
            #expect(text.contains("- \(tool.name.rawValue): "), "index must list \(tool.name.rawValue)")
        }
    }

    @Test func rejectsUnknownName() async {
        let harness = ToolHarness()
        let result = await harness.runRaw("describe_tools", args: ["names": ["no_such_tool"]])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("no_such_tool"))
    }

    @Test func failedCallsPointToDocs() async {
        let harness = ToolHarness()
        let result = await harness.runRaw("trim_clips", args: [:])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("describe_tools with names=[\"trim_clips\"]"))
    }
}
