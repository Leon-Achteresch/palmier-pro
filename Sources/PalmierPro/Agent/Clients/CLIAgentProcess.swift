import Foundation

enum CLIAgentEvent: Sendable {
    case sessionId(String)
    case textDelta(String)
    case assistantBlocks([AgentContentBlock])
    case toolResults([AgentContentBlock])
    case failed(String)
}

protocol CLIAgentClient: Sendable {
    var command: String { get }
    var workingDirectory: URL? { get }

    static func events(from object: [String: Any]) -> [CLIAgentEvent]
    static func isTerminal(_ object: [String: Any]) -> Bool
    static func failureMessage(status: Int32, output: String) -> String
}

extension CLIAgentClient {

    func stream(prompt: String) -> AsyncThrowingStream<CLIAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await run(prompt: prompt, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        prompt: String,
        continuation: AsyncThrowingStream<CLIAgentEvent, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command + " 2>&1"]
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        environment["PATH"] = extraPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout

        let (exitStatuses, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }

        try process.run()
        let pid = process.processIdentifier

        try await withTaskCancellationHandler {
            let writer = stdin.fileHandleForWriting
            try? writer.write(contentsOf: Data(prompt.utf8))
            try? writer.close()

            var sawTerminal = false
            var unparsedTail = ""
            for try await line in stdout.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                guard let object = Self.jsonObject(from: line) else {
                    unparsedTail = String((unparsedTail + line + "\n").suffix(2000))
                    continue
                }
                if Self.isTerminal(object) { sawTerminal = true }
                for event in Self.events(from: object) {
                    continuation.yield(event)
                }
            }

            var status: Int32 = 0
            for await exitStatus in exitStatuses { status = exitStatus }
            if status != 0, !sawTerminal {
                throw AgentStreamError.upstream(Self.failureMessage(status: status, output: unparsedTail))
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}

enum CLIAgentJSON {
    static func string(from value: Any?) -> String {
        guard let value else { return "{}" }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
