import AppKit
import SwiftUI

struct MotionEditorStage: View {
    @Bindable var session: MotionEditorSession

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            GeometryReader { geometry in
                if let scene = session.scene {
                    let fit = min(geometry.size.width / Double(scene.width), geometry.size.height / Double(scene.height))
                    let scale = fit * session.zoom
                    ZStack(alignment: .topLeading) {
                        AppTheme.Background.previewCanvasColor
                        if let view = session.presentationView {
                            MotionHostView(view: view)
                                .allowsHitTesting(session.interacting)
                        }
                        if !session.interacting {
                            ForEach(session.evaluated?.nodes.filter { $0.active && !$0.locked } ?? []) { node in
                                layer(node, scale: scale)
                            }
                            ForEach(session.slots.filter { slot in
                                session.selection.contains(slot.nodeID) && session.evaluated?.nodes.first(where: { $0.id == slot.nodeID })?.locked == false
                            }) { slot in
                                Rectangle()
                                    .fill(AppTheme.Background.clearColor)
                                    .contentShape(Rectangle())
                                    .overlay { Rectangle().stroke(AppTheme.Text.secondaryColor, lineWidth: (session.selectedSlotID == slot.id ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline) / scale) }
                                    .frame(width: max(slot.bounds.width, 1), height: max(slot.bounds.height, 1))
                                    .onTapGesture { session.select(slot.nodeID); session.selectedSlotID = slot.id; session.selectedBinding = "slots.\(slot.slotID).x" }
                                    .gesture(DragGesture(coordinateSpace: .named("motion-stage")).onChanged { value in
                                        session.previewSlot(slot, dx: value.translation.width / scale, dy: value.translation.height / scale)
                                    }.onEnded { _ in session.commitGesture() })
                                    .position(x: slot.bounds.x + slot.bounds.width / 2, y: slot.bounds.y + slot.bounds.height / 2)
                            }
                        }
                    }
                    .frame(width: Double(scene.width), height: Double(scene.height))
                    .scaleEffect(scale)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .coordinateSpace(name: "motion-stage")
            .clipped()
            HStack(spacing: AppTheme.Spacing.sm) {
                Button { session.togglePlayback() } label: { Image(systemName: session.playing ? "pause.fill" : "play.fill") }
                Text(verbatim: "\(session.frame + 1) / \(session.scene?.durationInFrames ?? 0)")
                    .monospacedDigit()
                Spacer()
                Button(L10n.string("Fit")) { session.zoom = 1 }
                Slider(value: $session.zoom, in: 0.25...4)
                    .frame(width: AppTheme.MotionEditor.curveHeight)
                Text(verbatim: "\(Int(session.zoom * 100))%")
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .controlSize(.small)
            .padding(AppTheme.Spacing.sm)
        }
        .background(AppTheme.Background.surfaceColor)
    }

    private func layer(_ node: MotionEvaluatedNode, scale: Double) -> some View {
        let selected = session.selection.contains(node.id)
        return Rectangle()
            .fill(AppTheme.Background.clearColor)
            .contentShape(Rectangle())
            .overlay {
                if selected { Rectangle().stroke(AppTheme.Text.primaryColor, lineWidth: AppTheme.BorderWidth.thin / scale) }
            }
            .frame(width: max(node.bounds.width, 1), height: max(node.bounds.height, 1))
            .onTapGesture { session.select(node.id, extending: NSEvent.modifierFlags.contains(.command)) }
            .gesture(DragGesture(coordinateSpace: .named("motion-stage")).onChanged { value in
                session.previewTranslation(id: node.id, dx: value.translation.width / scale, dy: value.translation.height / scale)
            }.onEnded { _ in session.commitGesture() })
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Rectangle().fill(AppTheme.Text.primaryColor)
                        .frame(width: AppTheme.MotionEditor.handleSize / scale, height: AppTheme.MotionEditor.handleSize / scale)
                        .gesture(DragGesture(coordinateSpace: .named("motion-stage")).onChanged { value in
                            session.previewTransform(id: node.id, dx: value.translation.width / scale, dy: value.translation.height / scale, rotating: false)
                        }.onEnded { _ in session.commitGesture() })
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Circle().fill(AppTheme.Text.primaryColor)
                        .frame(width: AppTheme.MotionEditor.handleSize / scale, height: AppTheme.MotionEditor.handleSize / scale)
                        .gesture(DragGesture(coordinateSpace: .named("motion-stage")).onChanged { value in
                            session.previewTransform(id: node.id, dx: value.translation.width / scale, dy: value.translation.height / scale, rotating: true)
                        }.onEnded { _ in session.commitGesture() })
                }
            }
            .position(x: node.bounds.x + node.bounds.width / 2, y: node.bounds.y + node.bounds.height / 2)
    }
}

private struct MotionHostView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { Container() }
    func updateNSView(_ container: NSView, context: Context) {
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        container.addSubview(view)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
    }
    private final class Container: NSView {
        override var isFlipped: Bool { true }
    }
}
