import Foundation

enum PresetKind: String, Codable, Sendable, CaseIterable {
    case look
    case effects
    case textStyle

    var displayName: String {
        switch self {
        case .look: "Look"
        case .effects: "Effect Stack"
        case .textStyle: "Text Style"
        }
    }

    var attribute: ClipAttribute {
        switch self {
        case .look: .color
        case .effects: .effects
        case .textStyle: .textStyle
        }
    }

    func supports(_ clip: Clip) -> Bool {
        switch self {
        case .look, .effects: clip.mediaType.isVisual
        case .textStyle: clip.mediaType == .text
        }
    }

    func payload(from clip: Clip) -> PresetPayload? {
        switch self {
        case .look:
            let grade = (clip.effects ?? []).filter(\.isColorGrade)
            return grade.isEmpty ? nil : .effects(grade)
        case .effects:
            let stack = (clip.effects ?? []).filter { !$0.isColorGrade }
            return stack.isEmpty ? nil : .effects(stack)
        case .textStyle:
            guard clip.mediaType == .text else { return nil }
            return .textStyle(TextStylePayload(
                style: clip.textStyle ?? TextStyle(),
                fillMode: clip.textFillMode,
                animation: clip.textAnimation
            ))
        }
    }
}

struct TextStylePayload: Codable, Sendable, Equatable {
    var style: TextStyle
    var fillMode: TextFillMode?
    var animation: TextAnimation?
}

enum PresetPayload: Codable, Sendable, Equatable {
    case effects([Effect])
    case textStyle(TextStylePayload)

    var effects: [Effect]? {
        guard case .effects(let stack) = self else { return nil }
        return stack
    }

    var textStyle: TextStylePayload? {
        guard case .textStyle(let payload) = self else { return nil }
        return payload
    }

    func matches(_ kind: PresetKind) -> Bool {
        switch (self, kind) {
        case (.effects(let stack), .look): !stack.isEmpty && stack.allSatisfy(\.isColorGrade)
        case (.effects(let stack), .effects): !stack.isEmpty && stack.allSatisfy { !$0.isColorGrade }
        case (.textStyle, .textStyle): true
        default: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case effects
        case textStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stack = try container.decodeIfPresent([Effect].self, forKey: .effects) {
            self = .effects(stack)
        } else if let style = try container.decodeIfPresent(TextStylePayload.self, forKey: .textStyle) {
            self = .textStyle(style)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "payload carries neither effects nor textStyle"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .effects(let stack): try container.encode(stack, forKey: .effects)
        case .textStyle(let style): try container.encode(style, forKey: .textStyle)
        }
    }
}

struct StylePreset: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    let kind: PresetKind
    let payload: PresetPayload
    let createdAt: Date
    let isBuiltIn: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: PresetKind,
        payload: PresetPayload,
        createdAt: Date = Date(),
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, payload, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decode(PresetKind.self, forKey: .kind),
            payload: try container.decode(PresetPayload.self, forKey: .payload),
            createdAt: try container.decode(Date.self, forKey: .createdAt)
        )
    }

    var donorClip: Clip {
        var clip = Clip(mediaRef: "", startFrame: 0, durationFrames: 0)
        switch payload {
        case .effects(let stack):
            clip.effects = stack
        case .textStyle(let style):
            clip.mediaType = .text
            clip.textStyle = style.style
            clip.textFillMode = style.fillMode
            clip.textAnimation = style.animation
        }
        return clip
    }
}
