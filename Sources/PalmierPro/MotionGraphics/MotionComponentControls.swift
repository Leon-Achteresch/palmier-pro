import SwiftUI

struct MotionComponentControls: View {
    let session: MotionEditorSession
    let component: MotionComponent
    @State private var newPropName = ""
    @State private var newKind: MotionPropSchema.Kind = .string
    @State private var newSlotName = ""

    var body: some View {
        Text(verbatim: component.name).fontWeight(AppTheme.FontWeight.semibold)
        Text(L10n.string("Exposed Properties")).foregroundStyle(AppTheme.Text.secondaryColor)
        ForEach(component.props) { prop in
            DisclosureGroup {
                MotionValueField(label: L10n.string("Label"), value: .string(prop.label)) { value in
                    if let name = value.string { update(prop) { $0.label = name } }
                }
                MotionValueField(label: L10n.string("Default Value"), value: prop.defaultValue, choices: prop.choices) { value in update(prop) { $0.defaultValue = value } }
                if prop.kind == .number {
                    MotionValueField(label: L10n.string("Minimum"), value: .number(prop.minimum ?? -1e12)) { value in
                        if let n = value.number { update(prop) { $0.minimum = n } }
                    }
                    MotionValueField(label: L10n.string("Maximum"), value: .number(prop.maximum ?? 1e12)) { value in
                        if let n = value.number { update(prop) { $0.maximum = n } }
                    }
                }
                if prop.kind == .choice {
                    MotionValueField(label: L10n.string("Choices, Comma Separated"), value: .string(prop.choices.joined(separator: ","))) { value in
                        if let text = value.string { update(prop) { $0.choices = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } }
                    }
                }
                Toggle(L10n.string("Animatable"), isOn: Binding(get: { prop.animatable }, set: { enabled in update(prop) { $0.animatable = enabled } }))
                Button(L10n.string("Remove Property")) {
                    var updated = component
                    updated.props.removeAll { $0.id == prop.id }
                    session.perform([.component(updated)])
                }
            } label: { Text(verbatim: prop.id) }
        }
        Divider()
        TextField(L10n.string("Property ID"), text: $newPropName).textFieldStyle(.roundedBorder)
        Picker(L10n.string("Type"), selection: $newKind) {
            ForEach(MotionPropSchema.Kind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
        }
        Button(L10n.string("Add Property")) {
            var updated = component
            let value: MotionValue
            switch newKind {
            case .number: value = .number(0)
            case .boolean: value = .bool(false)
            case .color: value = .string("#ffffff")
            case .choice: value = .string("default")
            case .string, .asset: value = .string("")
            }
            updated.props.append(MotionPropSchema(id: newPropName, label: newPropName, kind: newKind, defaultValue: value,
                choices: newKind == .choice ? ["default"] : []))
            session.perform([.component(updated)])
        }.disabled(newPropName.isEmpty)
        Text(L10n.string("Internal slots are declared by the component adapter with MotionSlot."))
            .foregroundStyle(AppTheme.Text.secondaryColor)
        ForEach(component.slots, id: \.self) { slot in
            HStack {
                Text(verbatim: slot)
                Spacer()
                Button(L10n.string("Remove Slot")) {
                    var updated = component
                    updated.slots.removeAll { $0 == slot }
                    session.perform([.component(updated)])
                }
            }
        }
        TextField(L10n.string("Slot ID"), text: $newSlotName).textFieldStyle(.roundedBorder)
        Button(L10n.string("Register Slot")) {
            var updated = component
            updated.slots.append(newSlotName)
            session.perform([.component(updated)])
        }.disabled(newSlotName.isEmpty)
    }

    private func update(_ prop: MotionPropSchema, operation: (inout MotionPropSchema) -> Void) {
        var updated = component
        guard let index = updated.props.firstIndex(where: { $0.id == prop.id }) else { return }
        operation(&updated.props[index])
        session.perform([.component(updated)])
    }
}

struct MotionComponentUpdateView: View {
    let session: MotionEditorSession
    let candidate: MotionComponentCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(L10n.string("Update Component")).font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
            Text(verbatim: candidate.component.name)
            if !candidate.changedProps.isEmpty {
                Text(L10n.string("Changed Properties"))
                Text(verbatim: candidate.changedProps.joined(separator: ", "))
            }
            if !candidate.removedSlots.isEmpty {
                Text(L10n.string("Removed Slots"))
                Text(verbatim: candidate.removedSlots.joined(separator: ", "))
            }
            Text(L10n.string("Existing bindings are validated before the update is applied. Undo restores the previous component version."))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let error = session.error { Text(verbatim: error) }
            HStack {
                Button(L10n.string("Cancel")) { session.componentCandidate = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string("Apply Update")) { session.applyComponentCandidate(candidate) }.keyboardShortcut(.defaultAction)
            }.disabled(session.busy)
        }.padding(AppTheme.Spacing.lg)
            .frame(width: AppTheme.MotionEditor.inspectorWidth * 2)
    }
}

extension MotionPropSchema.Kind {
    @MainActor var title: String {
        switch self {
        case .number: L10n.string("Number")
        case .string: L10n.string("Text")
        case .color: L10n.string("Color")
        case .boolean: L10n.string("Boolean")
        case .choice: L10n.string("Choice")
        case .asset: L10n.string("Asset")
        }
    }
}
