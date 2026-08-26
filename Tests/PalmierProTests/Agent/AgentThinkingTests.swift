import Foundation
import Testing
@testable import PalmierPro

@Suite("Agent thinking")
@MainActor
struct AgentThinkingTests {
    @Test func thinkingBlockRoundTripsUnchanged() throws {
        let block = AgentContentBlock.thinking(text: "reasoned")
        let decoded = try JSONDecoder().decode(
            AgentContentBlock.self,
            from: JSONEncoder().encode(block)
        )
        guard case .thinking(let text) = decoded else {
            Issue.record("Expected thinking block")
            return
        }
        #expect(text == "reasoned")
    }

    @Test func cancellationKeepsThinkingTurnWithText() {
        let service = AgentService()
        let message = AgentMessage(role: .assistant, blocks: [.thinking(text: "partial")])
        service.messages = [message]

        service.dropEmptyAssistantTurn(id: message.id)

        #expect(service.messages.count == 1)
    }

    @Test func cancellationDropsEmptyTurn() {
        let service = AgentService()
        let message = AgentMessage(role: .assistant, blocks: [.thinking(text: "")])
        service.messages = [message]

        service.dropEmptyAssistantTurn(id: message.id)

        #expect(service.messages.isEmpty)
    }
}
