import Inject
import SwiftUI

extension View {
    /// Rebuilds this subtree whenever InjectionIII injects new code. No-op in release builds.
    func hotReloadable() -> some View {
        HotReloadContainer(content: self)
    }
}

private struct HotReloadContainer<Content: View>: View {
    @ObserveInjection private var inject
    let content: Content

    var body: some View {
        content.enableInjection()
    }
}
