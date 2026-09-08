import Foundation

/// Attributes synchronous work started by the agent or an MCP client.
enum ToolOrigin {
    struct Value: Sendable {
        let source: String
        let sessionID: String
    }

    @TaskLocal static var current: Value?
}
