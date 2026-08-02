import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — search_stock_media")
@MainActor
struct StockMediaToolTests {
    @Test func toolIsExposedWithSchema() {
        let tool = ToolDefinitions.all.first { $0.name == .searchStockMedia }
        let schema = tool?.inputSchema
        let required = schema?["required"] as? [String]
        #expect(tool != nil)
        #expect(required?.sorted() == ["kind", "query"])
    }

    @Test func rejectsMissingQuery() async {
        let h = ToolHarness()
        let result = await h.runRaw("search_stock_media", args: ["kind": "photo"])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("query"))
    }

    @Test(arguments: ["gif", "", "photos"]) func rejectsInvalidKind(_ kind: String) async {
        let h = ToolHarness()
        let result = await h.runRaw("search_stock_media", args: ["query": "beach", "kind": kind])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("kind"))
    }

    @Test func rejectsUnknownProvider() async {
        let h = ToolHarness()
        let result = await h.runRaw(
            "search_stock_media",
            args: ["query": "beach", "kind": "photo", "provider": "unsplash"]
        )
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("provider"))
    }

    @Test func rejectsInvalidPage() async {
        let h = ToolHarness()
        let result = await h.runRaw(
            "search_stock_media",
            args: ["query": "beach", "kind": "photo", "page": 0]
        )
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("page"))
    }

    @Test func rejectsUnknownArgument() async {
        let h = ToolHarness()
        let result = await h.runRaw(
            "search_stock_media",
            args: ["query": "beach", "kind": "photo", "bogus": 1]
        )
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("bogus"))
    }
}
