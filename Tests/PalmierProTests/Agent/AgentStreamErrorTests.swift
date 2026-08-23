import Foundation
import Testing
@testable import PalmierPro

@Suite("AgentStreamError")
struct AgentStreamErrorTests {
    @Test("Surfaces provider name and raw upstream detail")
    func includesProviderMetadata() {
        let body = """
        {"error":{"message":"Provider returned error","code":429,\
        "metadata":{"provider_name":"Google AI Studio","raw":{"error":{"message":"Quota exceeded"}}}}}
        """
        let message = AgentStreamError.from(status: 429, body: body).errorDescription ?? ""
        #expect(message == "Provider returned error (Google AI Studio): Quota exceeded")
    }

    @Test("Falls back to the bare message without metadata")
    func withoutMetadata() {
        let body = #"{"error":{"message":"Provider returned error"}}"#
        #expect(AgentStreamError.from(status: 500, body: body).errorDescription == "Provider returned error")
    }

    @Test("Auth failures still ask for the key")
    func authFailure() {
        guard case .missingKey = AgentStreamError.from(status: 401, body: "") else {
            Issue.record("expected missingKey")
            return
        }
    }
}
