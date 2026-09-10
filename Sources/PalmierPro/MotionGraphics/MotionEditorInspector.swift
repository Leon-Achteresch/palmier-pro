import SwiftUI

struct MotionEditorInspector: View {
    @Bindable var session: MotionEditorSession
    @State private var fixtureName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                if let node = session.selectedNode {
                    MotionValueField(label: L10n.string("Name"), value: .string(node.name)) {
                        if let name = $0.string { session.perform([.rename(id: node.id, name: name)]) }
                    }
                    timing(node)
                    Divider()
                    ForEach(properties(for: node), id: \.self) { property in
                        propertyField(property, node: node)
                    }
                    if let component = session.scene?.components.first(where: { $0.id == node.componentID }) {
                        componentFields(component, node: node)
                    }
                    if !node.recipes.isEmpty {
                        Divider()
                        ForEach(node.recipes) { recipe in MotionRecipeInspector(session: session, node: node, recipe: recipe) }
                    }
                } else if let component = session.scene?.components.first(where: { $0.id == session.selectedComponentID }) {
                    MotionComponentControls(session: session, component: component)
                } else if session.selection.count > 1 {
                    Text(L10n.string("Multiple Layers Selected"))
                    Text(L10n.string("Drag, align, group, or animate the selected layers."))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                } else if let scene = session.scene {
                    MotionSceneInspector(session: session, scene: scene)
                }
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .controlSize(.small)
            .padding(AppTheme.Spacing.smMd)
            .disabled(session.busy || session.selectedNode?.locked == true)
        }
    }

    private func timing(_ node: MotionNode) -> some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            MotionValueField(label: L10n.string("Start Frame"), value: .number(Double(node.startFrame))) { value in
                if let n = value.integer { session.perform([.timing(ids: [node.id], startFrame: n, durationFrames: node.durationFrames)]) }
            }
            MotionValueField(label: L10n.string("Duration Frames"), value: .number(Double(node.durationFrames))) { value in
                if let n = value.integer { session.perform([.timing(ids: [node.id], startFrame: node.startFrame, durationFrames: n)]) }
            }
        }
    }

    private func propertyField(_ property: MotionProperty, node: MotionNode) -> some View {
        let value = session.autoKey ? session.evaluated?.nodes.first { $0.id == node.id }?.animatedProperties[property.rawValue] ?? node.value(property) : node.value(property)
        return HStack(spacing: AppTheme.Spacing.xs) {
            MotionValueField(label: property.title, value: value, choices: choices(property)) { session.setValue(property.rawValue, value: $0) }
            Button { session.addKey(property.rawValue, value: value) } label: { Image(systemName: "diamond") }
                .help(L10n.string("Add Keyframe"))
        }
    }

    @ViewBuilder private func componentFields(_ component: MotionComponent, node: MotionNode) -> some View {
        Divider()
        Text(verbatim: component.name).fontWeight(AppTheme.FontWeight.semibold)
        if !component.fixtures.isEmpty {
            Menu(L10n.string("Apply Fixture")) {
                ForEach(component.fixtures.keys.sorted(), id: \.self) { name in
                    Button { session.applyFixture(name, component: component) } label: { Text(verbatim: name) }
                }
            }
        }
        HStack {
            TextField(L10n.string("Fixture Name"), text: $fixtureName).textFieldStyle(.roundedBorder)
            Button(L10n.string("Save Fixture")) {
                session.saveFixture(fixtureName, component: component, node: node)
            }.disabled(fixtureName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        ForEach(component.props) { prop in
            let base = node.props[prop.id] ?? prop.defaultValue
            let value = session.autoKey ? session.evaluated?.nodes.first { $0.id == node.id }?.props[prop.id] ?? base : base
            HStack(spacing: AppTheme.Spacing.xs) {
                MotionValueField(label: prop.label, value: value, choices: prop.choices) { session.setValue("props." + prop.id, value: $0) }
                if prop.animatable {
                    Button { session.addKey("props." + prop.id, value: value) } label: { Image(systemName: "diamond") }
                        .help(L10n.string("Add Keyframe"))
                }
            }
        }
        ForEach(component.slots, id: \.self) { slot in
            DisclosureGroup {
                ForEach([MotionProperty.x, .y, .scaleX, .scaleY, .rotation, .opacity, .reveal], id: \.self) { property in
                    HStack {
                        MotionValueField(label: property.title, value: session.slotValue(node: node, slot: slot, property: property)) {
                            session.setValue("slots.\(slot).\(property.rawValue)", value: $0)
                        }
                        Button { session.addKey("slots.\(slot).\(property.rawValue)", value: session.slotValue(node: node, slot: slot, property: property)) } label: { Image(systemName: "diamond") }
                    }
                }
            } label: { Text(verbatim: slot) }
        }
    }

    private func properties(for node: MotionNode) -> [MotionProperty] {
        var properties: [MotionProperty] = [.x, .y, .width, .height, .scaleX, .scaleY, .rotation, .opacity, .anchorX, .anchorY]
        if node.kind == .text { properties += [.text, .fontSize, .fontFamily, .fontWeight, .letterSpacing, .textAlign, .fill] }
        if node.kind == .shape { properties += [.fill, .stroke, .strokeWidth, .cornerRadius] }
        if node.kind == .path { properties += [.path, .fill, .stroke, .strokeWidth, .pathProgress] }
        if node.kind != .camera { properties += [.mask, .reveal, .blur] }
        return properties
    }

    private func choices(_ property: MotionProperty) -> [String] {
        switch property {
        case .mask: ["none", "rectangle", "ellipse"]
        case .textAlign: ["left", "center", "right"]
        default: []
        }
    }
}

struct MotionValueField: View {
    let label: String
    let value: MotionValue
    var choices: [String] = []
    let commit: (MotionValue) -> Void
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(verbatim: label).lineLimit(2)
            Spacer(minLength: AppTheme.Spacing.zero)
            if let boolean = value.bool {
                Toggle(isOn: Binding(get: { boolean }, set: { commit(.bool($0)) })) { EmptyView() }.labelsHidden()
            } else if !choices.isEmpty {
                Picker(selection: Binding(get: { value.string ?? "" }, set: { commit(.string($0)) })) {
                    ForEach(choices, id: \.self) { Text(verbatim: $0).tag($0) }
                } label: { Text(verbatim: label) }.labelsHidden()
            } else {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: AppTheme.MotionEditor.fieldWidth)
                    .focused($focused)
                    .onSubmit(save)
                    .onChange(of: focused) { was, now in if was && !now { save() } }
                    .onChange(of: value, initial: true) { _, new in if !focused { draft = display(new); invalid = false } }
                    .help(invalid ? L10n.string("Enter a finite number.") : label)
                    .overlay(alignment: .trailing) { if invalid { Image(systemName: "exclamationmark.circle").foregroundStyle(AppTheme.Text.primaryColor) } }
            }
        }
    }

    private func display(_ value: MotionValue) -> String {
        value.string ?? value.number.map { $0.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) } ?? ""
    }

    private func save() {
        guard draft != display(value) else { return }
        if value.number != nil {
            guard let number = Double(draft), number.isFinite else { invalid = true; return }
            invalid = false
            commit(.number(number))
        } else { commit(.string(draft)) }
    }
}

extension MotionValue {
    var integer: Int? {
        guard let number, number.isFinite, number.rounded() == number, number >= -1_000_000, number <= 1_000_000 else { return nil }
        return Int(number)
    }
}

private struct MotionRecipeInspector: View {
    let session: MotionEditorSession
    let node: MotionNode
    let recipe: MotionRecipe

    var body: some View {
        DisclosureGroup(recipe.kind.title) {
            field(L10n.string("Start Frame"), recipe.startFrame) { $0.startFrame = $1 }
            field(L10n.string("Duration Frames"), recipe.durationFrames) { $0.durationFrames = $1 }
            MotionValueField(label: L10n.string("Amount"), value: .number(recipe.amount)) { value in
                if let n = value.number { var updated = recipe; updated.amount = n; save(updated) }
            }
            field(L10n.string("Repeat Count"), recipe.repeatCount) { $0.repeatCount = $1 }
            field(L10n.string("Gap Frames"), recipe.gapFrames) { $0.gapFrames = $1 }
            Toggle(L10n.string("Mirror"), isOn: Binding(get: { recipe.mirror }, set: { var updated = recipe; updated.mirror = $0; save(updated) }))
            MotionEasingEditor(easing: recipe.easing) { var updated = recipe; updated.easing = $0; save(updated) }
            Button(L10n.string("Expand to Keyframes")) { session.expandRecipe(node: node, recipe: recipe) }
            Button(L10n.string("Remove Animation")) { session.perform([.removeRecipe(id: node.id, recipeID: recipe.id)]) }
        }
    }

    private func field(_ title: String, _ value: Int, update: @escaping (inout MotionRecipe, Int) -> Void) -> some View {
        MotionValueField(label: title, value: .number(Double(value))) { value in
            if let n = value.integer { var updated = recipe; update(&updated, n); save(updated) }
        }
    }

    private func save(_ updated: MotionRecipe) {
        var result = updated
        result.startFrame += node.startFrame
        session.perform([.recipe(ids: [node.id], recipe: result, stagger: 0)])
    }
}

struct MotionEasingEditor: View {
    let easing: MotionEasing
    let commit: (MotionEasing) -> Void

    var body: some View {
        Picker(L10n.string("Easing"), selection: Binding(get: { easing.kind }, set: { var result = easing; result.kind = $0; commit(result) })) {
            ForEach(MotionEasing.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        if easing.kind == .bezier {
            field("X1", \.x1); field("Y1", \.y1); field("X2", \.x2); field("Y2", \.y2)
        }
        if easing.kind == .spring {
            field(L10n.string("Stiffness"), \.stiffness)
            field(L10n.string("Damping"), \.damping)
            field(L10n.string("Mass"), \.mass)
        }
    }

    private func field(_ name: String, _ path: WritableKeyPath<MotionEasing, Double>) -> some View {
        MotionValueField(label: name, value: .number(easing[keyPath: path])) { value in
            if let n = value.number { var result = easing; result[keyPath: path] = n; commit(result) }
        }
    }
}
