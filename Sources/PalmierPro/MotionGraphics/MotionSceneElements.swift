import Foundation

struct MotionComponent: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var source: String
    var stylesheet: String = ""
    var props: [MotionPropSchema] = []
    var fixtures: [String: [String: MotionValue]] = [:]
    var slots: [String] = []


}

enum MotionProperty: String, Codable, CaseIterable, Sendable {
    case x, y, width, height, scaleX, scaleY, rotation, opacity, anchorX, anchorY
    case cornerRadius, blur, fill, stroke, strokeWidth, reveal, text, fontSize, fontFamily
    case fontWeight, letterSpacing, textAlign, path, image, mask, pathProgress, textProgress

    var defaultValue: MotionValue {
        switch self {
        case .width: .number(320)
        case .height: .number(180)
        case .scaleX, .scaleY, .opacity, .reveal, .pathProgress, .textProgress: .number(1)
        case .anchorX, .anchorY: .number(0.5)
        case .fill: .string("#ffffff")
        case .stroke: .string("#000000")
        case .fontSize: .number(48)
        case .fontWeight: .number(400)
        case .fontFamily: .string("system-ui")
        case .textAlign: .string("left")
        case .mask: .string("none")
        case .text, .path, .image: .string("")
        default: .number(0)
        }
    }

    var range: ClosedRange<Double>? {
        switch self {
        case .x, .y: -65536...65536
        case .width, .height: 0...16384
        case .scaleX, .scaleY: -100...100
        case .rotation: -36000...36000
        case .opacity, .anchorX, .anchorY, .reveal, .pathProgress, .textProgress: 0...1
        case .cornerRadius, .blur, .strokeWidth: 0...1000
        case .fontSize: 1...4096
        case .fontWeight: 100...900
        case .letterSpacing: -1000...1000
        default: nil
        }
    }

    func validate(_ value: MotionValue) throws {
        try value.validated()
        let valid: Bool
        if let range { valid = value.number.map(range.contains) ?? false }
        else {
            switch self {
            case .fill, .stroke: valid = value.string.map(Self.isColor) ?? false
            case .mask: valid = value.string.map { ["none", "rectangle", "ellipse"].contains($0) } ?? false
            case .textAlign: valid = value.string.map { ["left", "center", "right"].contains($0) } ?? false
            case .image: valid = value.string.map { $0.isEmpty || $0.hasPrefix("data:image/") } ?? false
            case .path: valid = value.string.map { text in text.utf8.count <= 131072 && text.allSatisfy { "MmLlHhVvCcSsQqTtAaZz0123456789.,+- eE\n\t".contains($0) } } ?? false
            default: valid = value.string != nil
            }
        }
        guard valid else { throw MotionSceneError.invalidField("invalid value for '\(rawValue)'") }
    }

    static func isColor(_ text: String) -> Bool {
        text == "transparent" || (text.hasPrefix("#") && [4, 5, 7, 9].contains(text.count)
            && text.dropFirst().allSatisfy(\.isHexDigit))
    }
}

struct MotionNode: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable { case component, group, text, shape, path, image, camera }
    var id: String = UUID().uuidString
    var name: String
    var kind: Kind
    var parentID: String?
    var componentID: String?
    var startFrame: Int = 0
    var durationFrames: Int
    var locked: Bool = false
    var hidden: Bool = false
    var properties: [String: MotionValue] = [:]
    var props: [String: MotionValue] = [:]
    var tracks: [MotionTrack] = []
    var recipes: [MotionRecipe] = []

    func value(_ property: MotionProperty) -> MotionValue { properties[property.rawValue] ?? property.defaultValue }
}

struct MotionKey: Codable, Equatable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var frame: Int
    var value: MotionValue
    var easing: MotionEasing = .init()
}

struct MotionEasing: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case linear, hold, easeIn, easeOut, easeInOut, bezier, spring }
    var kind: Kind = .easeOut
    var x1: Double = 0.25
    var y1: Double = 0.1
    var x2: Double = 0.25
    var y2: Double = 1
    var stiffness: Double = 170
    var damping: Double = 26
    var mass: Double = 1

    func validated() throws {
        guard [x1, y1, x2, y2, stiffness, damping, mass].allSatisfy(\.isFinite),
              (0...1).contains(x1), (0...1).contains(x2), (-10...10).contains(y1), (-10...10).contains(y2),
              (0.1...10000).contains(stiffness), (0.1...1000).contains(damping), (0.01...100).contains(mass)
        else { throw MotionSceneError.invalidField("invalid easing parameters") }
    }
}

struct MotionTrack: Codable, Equatable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var binding: String
    var keys: [MotionKey]
    var repeatCount: Int = 1
    var mirror: Bool = false
    var gapFrames: Int = 0
}

struct MotionRecipe: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case slideUp = "slide-up-fade", slideLeft = "slide-left-fade", pop, fadeIn = "fade-in", fadeOut = "fade-out"
        case float, pulse, spin, typewriter, textStagger = "text-stagger"
    }
    var id: String = UUID().uuidString
    var kind: Kind
    var startFrame: Int = 0
    var durationFrames: Int = 18
    var amount: Double = 40
    var repeatCount: Int = 1
    var mirror: Bool = false
    var gapFrames: Int = 0
    var easing: MotionEasing = .init()
}

struct MotionAudioCue: Codable, Equatable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var mediaRef: String
    var frame: Int
    var trimStartFrame: Int = 0
    var durationFrames: Int
    var volumeDB: Double = -12
}

struct MotionFormat: Codable, Equatable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var width: Int
    var height: Int
    var overrides: [String: [String: MotionValue]] = [:]
}
