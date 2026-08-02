import Foundation
import Testing
@testable import PalmierPro

@Suite("ClaudeCodeClient - stream event mapping")
struct ClaudeCodeClientTests {

    private func events(_ json: String) -> [CLIAgentEvent] {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return ClaudeCodeClient.events(from: object)
    }

    @Test func initEventYieldsSessionId() {
        let parsed = events(#"{"type":"system","subtype":"init","session_id":"abc-123"}"#)
        guard case .sessionId(let id)? = parsed.first else {
            Issue.record("expected sessionId event")
            return
        }
        #expect(id == "abc-123")
    }

    @Test func streamEventYieldsTextDelta() {
        let parsed = events(#"""
        {"type":"stream_event","parent_tool_use_id":null,"event":{
            "type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}
        }}
        """#)
        guard case .textDelta(let text)? = parsed.first else {
            Issue.record("expected textDelta event")
            return
        }
        #expect(text == "Hel")
    }

    @Test func subagentStreamEventIsIgnored() {
        let parsed = events(#"""
        {"type":"stream_event","parent_tool_use_id":"tu_9","event":{
            "type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}
        }}
        """#)
        #expect(parsed.isEmpty)
    }

    @Test func topLevelAssistantMessageDropsStreamedTextKeepsToolUse() {
        let parsed = events(#"""
        {"type":"assistant","parent_tool_use_id":null,"message":{"content":[
            {"type":"text","text":"Hello"},
            {"type":"tool_use","id":"tu_1","name":"mcp__palmier-pro__get_timeline","input":{"detail":true}}
        ]}}
        """#)
        guard case .assistantBlocks(let blocks)? = parsed.first, blocks.count == 1,
              case .toolUse(let id, let name, let input) = blocks[0] else {
            Issue.record("expected only the toolUse block")
            return
        }
        #expect(id == "tu_1")
        #expect(name == "mcp__palmier-pro__get_timeline")
        #expect(input.contains("\"detail\":true"))
    }

    @Test func subagentAssistantMessageKeepsText() {
        let parsed = events(#"""
        {"type":"assistant","parent_tool_use_id":"tu_9","message":{"content":[{"type":"text","text":"Hello"}]}}
        """#)
        guard case .assistantBlocks(let blocks)? = parsed.first,
              case .text(let text)? = blocks.first else {
            Issue.record("expected text block")
            return
        }
        #expect(text == "Hello")
    }

    @Test func userMessageYieldsToolResults() {
        let parsed = events(#"""
        {"type":"user","message":{"content":[
            {"type":"tool_result","tool_use_id":"tu_1","is_error":true,"content":[{"type":"text","text":"boom"}]},
            {"type":"tool_result","tool_use_id":"tu_2","content":"plain string"}
        ]}}
        """#)
        guard case .toolResults(let blocks)? = parsed.first, blocks.count == 2,
              case .toolResult(let firstId, let firstContent, let firstIsError) = blocks[0],
              case .toolResult(let secondId, let secondContent, let secondIsError) = blocks[1] else {
            Issue.record("expected two toolResult blocks")
            return
        }
        #expect(firstId == "tu_1")
        #expect(firstIsError)
        guard case .text(let firstText)? = firstContent.first,
              case .text(let secondText)? = secondContent.first else {
            Issue.record("expected text result content")
            return
        }
        #expect(firstText == "boom")
        #expect(secondId == "tu_2")
        #expect(!secondIsError)
        #expect(secondText == "plain string")
    }

    @Test func errorResultYieldsFailure() {
        let parsed = events(#"{"type":"result","subtype":"error_during_execution","result":"it broke"}"#)
        guard case .failed(let message)? = parsed.first else {
            Issue.record("expected failed event")
            return
        }
        #expect(message == "it broke")
    }

    @Test func successResultAndUnknownEventsYieldNothing() {
        #expect(events(#"{"type":"result","subtype":"success","result":"OK"}"#).isEmpty)
        #expect(events(#"{"type":"rate_limit_event"}"#).isEmpty)
        #expect(events(#"{"type":"system","subtype":"hook_started"}"#).isEmpty)
    }
}
