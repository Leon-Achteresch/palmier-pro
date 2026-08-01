import SwiftTerm
import SwiftUI

enum AgentTerminalCLI: String, CaseIterable, Identifiable {
    case claude, codex, shell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .shell: "Shell"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .shell: "terminal"
        }
    }

    @MainActor
    fileprivate var launchCommand: String? {
        switch self {
        case .claude: "claude --mcp-config \(Self.mcpConfigJSON)"
        case .codex: "codex"
        case .shell: nil
        }
    }

    @MainActor
    private static var mcpConfigJSON: String {
        "'{\"mcpServers\":{\"palmier-pro\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:\(MCPService.port)/mcp\"}}}'"
    }
}

@MainActor
@Observable
final class AgentTerminalStore {
    private var views: [AgentTerminalCLI: LocalProcessTerminalView] = [:]

    @ObservationIgnored
    private lazy var exitHandler = TerminalExitHandler { [weak self] view in
        self?.views = self?.views.filter { $0.value !== view } ?? [:]
    }

    func existingView(for cli: AgentTerminalCLI) -> LocalProcessTerminalView? { views[cli] }

    @discardableResult
    func view(for cli: AgentTerminalCLI, workingDirectory: URL?) -> LocalProcessTerminalView {
        if let existing = views[cli] { return existing }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.processDelegate = exitHandler
        view.configureNativeColors()
        view.startProcess(executable: "/bin/zsh", args: ["-ilc", Self.script(for: cli, in: workingDirectory)])
        views[cli] = view
        return view
    }

    func terminate(_ cli: AgentTerminalCLI) {
        guard let view = views.removeValue(forKey: cli) else { return }
        view.send(txt: "\u{04}")
    }

    private static func script(for cli: AgentTerminalCLI, in directory: URL?) -> String {
        var parts: [String] = []
        if let directory { parts.append("cd \(directory.path.singleQuotedForShell)") }
        if let command = cli.launchCommand { parts.append(command) }
        let prelude = parts.joined(separator: " && ")
        return prelude.isEmpty ? "exec /bin/zsh -il" : "\(prelude); exec /bin/zsh -il"
    }
}

extension String {
    var singleQuotedForShell: String { "'\(replacingOccurrences(of: "'", with: "'\\''"))'" }
}

@MainActor
private final class TerminalExitHandler: NSObject, LocalProcessTerminalViewDelegate {
    private let onExit: @MainActor (LocalProcessTerminalView) -> Void

    init(onExit: @escaping @MainActor (LocalProcessTerminalView) -> Void) {
        self.onExit = onExit
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            guard let view = source as? LocalProcessTerminalView else { return }
            onExit(view)
        }
    }
}

struct AgentTerminalView: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
