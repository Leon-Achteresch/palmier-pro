import Foundation
import Testing
@testable import PalmierPro

@Suite("Agent providers")
struct AgentProviderTests {
    @Test func modelIdentityCarriesTheProviderPrefix() {
        let openRouter = AgentModel.openRouter(id: "anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5")
        #expect(openRouter.provider == .openRouter)
        #expect(openRouter.providerModelId == "anthropic/claude-sonnet-4.5")
        #expect(openRouter.displayName == "Claude Sonnet 4.5")

        let google = AgentModel.google(id: "gemini-2.5-pro")
        #expect(google.provider == .google)
        #expect(google.providerModelId == "gemini-2.5-pro")

        #expect(AgentModel.claudeCode.provider == nil)
        #expect(AgentModel.claudeCode.isCLIAgent)
        #expect(AgentModel(rawValue: "codex/gpt-5.5").codexModelId == "gpt-5.5")
    }

    @Test func credentialsGateModelsByProvider() {
        let credentials = AgentCredentialSnapshot([.openRouter: "sk-or-test", .google: ""])
        #expect(credentials.hasKey(for: .openRouter(id: "anthropic/claude-sonnet-4.5")))
        #expect(!credentials.hasKey(for: .google(id: "gemini-2.5-pro")))
        #expect(credentials.hasKey(for: .claudeCode))
    }

    @Test func requestBodyMapsConversationToolCallsAndImages() throws {
        let messages = [
            AgentRequestMessage(role: .user, content: [
                .content(.text("Inspect this")),
                .image(base64: "aGVsbG8=", mediaType: "image/png"),
            ]),
            AgentRequestMessage(role: .assistant, content: [
                .content(.thinking(text: "thinking out loud")),
                .content(.text("Calling a tool")),
                .content(.toolUse(id: "call_1", name: "inspect_timeline", inputJSON: "{\"b\":2,\"a\":1}")),
            ]),
            AgentRequestMessage(role: .user, content: [
                .content(.toolResult(
                    toolUseId: "call_1",
                    content: [.text("Done"), .image(base64: "aW1hZ2U=", mediaType: "image/jpeg")],
                    isError: false)),
            ]),
        ]
        let body = ChatCompletionsRequestBody.build(
            provider: .openRouter,
            settings: AgentRunSettings(
                model: .openRouter(id: "anthropic/claude-sonnet-4.5"),
                reasoningEffort: .high
            ),
            system: "Instructions",
            tools: [AgentToolSchema(
                name: "inspect_timeline",
                description: "Inspect the timeline",
                inputSchema: ["type": "object"]
            )],
            messages: messages
        )

        #expect(body["model"] as? String == "anthropic/claude-sonnet-4.5")
        #expect(body["stream"] as? Bool == true)
        #expect((body["reasoning"] as? [String: String])?["effort"] == "high")

        let items = try #require(body["messages"] as? [[String: Any]])
        #expect(items[0]["role"] as? String == "system")
        #expect(items[1]["role"] as? String == "user")
        let userParts = try #require(items[1]["content"] as? [[String: Any]])
        #expect(userParts.contains { $0["type"] as? String == "image_url" })

        let assistant = items[2]
        #expect(assistant["role"] as? String == "assistant")
        #expect(assistant["content"] as? String == "Calling a tool")
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
        let function = try #require(toolCalls[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "inspect_timeline")
        #expect(function["arguments"] as? String == "{\"a\":1,\"b\":2}")

        #expect(items[3]["role"] as? String == "tool")
        #expect(items[3]["tool_call_id"] as? String == "call_1")
        #expect(items[3]["content"] as? String == "Done")
        // Tool-result images follow as their own user turn.
        #expect(items[4]["role"] as? String == "user")

        let googleBody = ChatCompletionsRequestBody.build(
            provider: .google,
            settings: AgentRunSettings(model: .google(id: "gemini-2.5-pro"), reasoningEffort: .none),
            system: "Instructions",
            tools: [],
            messages: []
        )
        #expect(googleBody["reasoning_effort"] == nil)
        #expect(googleBody["model"] as? String == "gemini-2.5-pro")
    }

    @Test func streamParserEmitsTextReasoningAndToolCalls() throws {
        var parser = ChatCompletionsStreamParser(provider: .openRouter)
        var events: [AgentStreamEvent] = []
        let lines = [
            #"data: {"choices":[{"delta":{"reasoning":"thinking"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"add_clip","arguments":"{\"a\":"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ]
        for line in lines { events += try parser.consume(line: line) }
        events += parser.finish()

        #expect(events.first == .thinkingDelta("thinking"))
        #expect(events.contains(.textDelta("Hello")))
        #expect(events.contains(.toolUseComplete(id: "call_1", name: "add_clip", inputJSON: "{\"a\":1}")))
        #expect(events.last == .messageStop(stopReason: .toolUse))
    }

    @Test func streamParserSurfacesUpstreamErrors() {
        var parser = ChatCompletionsStreamParser(provider: .google)
        #expect(throws: AgentClientTransportError.self) {
            _ = try parser.consume(line: #"data: {"error":{"message":"quota exceeded"}}"#)
        }
    }

    @Test func streamParserReportsEndTurn() throws {
        var parser = ChatCompletionsStreamParser(provider: .openRouter)
        var events = try parser.consume(line: #"data: {"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}"#)
        events += parser.finish()
        #expect(events == [.textDelta("done"), .messageStop(stopReason: .endTurn)])
    }
}
