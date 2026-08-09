import AppKit
import WebKit

/// Drives the bundled React runtime in an offscreen WKWebView and captures frames at exact times.
///
/// WKWebView is main-actor only, so this type is too. Keep it for the duration of one bake and tear
/// it down afterwards; the caller owns moving the pixel work off the main actor.
@MainActor
final class MotionSceneRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private let size: CGSize
    private var pageLoad: CheckedContinuation<Void, any Error>?
    private var didAllowInitialLoad = false

    private static let loadTimeout = Duration.seconds(20)

    /// Reads the bundled runtime off the main actor. Hand the result to `init`.
    @concurrent
    static func loadRuntimeHTML() async throws -> String {
        guard let url = BundledResource.url("MotionRuntime/index.html") else {
            throw MotionSceneError.runtimeMissing
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    init(size: CGSize, runtimeHTML: String) {
        self.size = size
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let frame = CGRect(origin: .zero, size: size)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.contentView = webView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.orderBack(nil)

        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.layer?.isOpaque = false
        Self.makeTransparent(webView)
        webView.loadHTMLString(runtimeHTML, baseURL: nil)
    }

    /// `underPageBackgroundColor` alone still composites an opaque white page; only this makes the
    /// snapshot carry alpha. Probed first so a future macOS without the key degrades to an opaque
    /// render instead of raising.
    private static func makeTransparent(_ webView: WKWebView) {
        guard webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) else {
            Log.preview.warning("motion runtime cannot disable the web view background; scenes will render opaque")
            return
        }
        webView.setValue(false, forKey: "drawsBackground")
    }

    func tearDown() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        window.contentView = nil
        window.orderOut(nil)
        resumePageLoad(with: .failure(CancellationError()))
    }

    // MARK: - Navigation lockdown

    /// Scene source is executed code. The runtime is self-contained, so nothing may navigate or
    /// fetch: the only permitted load is the initial in-memory document.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard !didAllowInitialLoad else {
            Log.preview.warning("motion scene blocked navigation to \(navigationAction.request.url?.scheme ?? "?")")
            decisionHandler(.cancel)
            return
        }
        didAllowInitialLoad = true
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumePageLoad(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        resumePageLoad(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        resumePageLoad(with: .failure(error))
    }

    private func resumePageLoad(with result: Result<Void, any Error>) {
        if case .loading = loadState {
            switch result {
            case .success: loadState = .finished
            case .failure(let error): loadState = .failed(error)
            }
        }
        guard let continuation = pageLoad else { return }
        pageLoad = nil
        continuation.resume(with: result)
    }

    // MARK: - Scene

    func load(scene: MotionScene) async throws {
        try await waitForPageLoad()
        let result = try await callJS(
            "return await window.__motion.load(source, { fps, width, height, durationInFrames })",
            arguments: [
                "source": scene.source,
                "fps": scene.fps,
                "width": scene.width,
                "height": scene.height,
                "durationInFrames": scene.durationInFrames,
            ]
        )
        guard let payload = result as? [String: Any] else {
            throw MotionSceneError.sceneFailed("the motion runtime returned no result")
        }
        if payload["ok"] as? Bool != true {
            throw MotionSceneError.sceneFailed(Self.message(from: payload))
        }
    }

    func seek(toMilliseconds milliseconds: Double) async throws {
        _ = try await callJS("return window.__motion.seek(ms)", arguments: ["ms": milliseconds])
    }

    /// Throws if the scene reported an error at any point, so a failed bake never ships blank frames.
    func assertSceneHealthy() async throws {
        let result = try await callJS("return window.__motion.status()", arguments: [:])
        guard let payload = result as? [String: Any] else { return }
        if payload["ok"] as? Bool != true {
            throw MotionSceneError.sceneFailed(Self.message(from: payload))
        }
    }

    func snapshot() async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw MotionSceneError.snapshotFailed
        }
        return cgImage
    }

    // MARK: - Private

    /// The delegate can fire before anyone waits, so completion lives in `loadState` rather than in
    /// the continuation. Every path through here resumes exactly once, on the main actor.
    private func waitForPageLoad() async throws {
        switch loadState {
        case .finished: return
        case .failed(let error): throw error
        case .loading: break
        }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: Self.loadTimeout)
            guard !Task.isCancelled else { return }
            self.resumePageLoad(with: .failure(MotionSceneError.renderTimedOut))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            switch loadState {
            case .finished: continuation.resume()
            case .failed(let error): continuation.resume(throwing: error)
            case .loading: pageLoad = continuation
            }
        }
    }

    private enum LoadState {
        case loading
        case finished
        case failed(any Error)
    }

    private var loadState: LoadState = .loading

    private func callJS(_ body: String, arguments: [String: Any]) async throws -> Any? {
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
        } catch {
            throw MotionSceneError.sceneFailed(error.localizedDescription)
        }
    }

    private static func message(from payload: [String: Any]) -> String {
        (payload["error"] as? String) ?? "the scene failed to render"
    }
}
