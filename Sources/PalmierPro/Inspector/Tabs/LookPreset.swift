import Foundation

enum LookPreset: String, CaseIterable, Identifiable {
    case cinematic
    case moody
    case vintage
    case brightAiry
    case goldenHour
    case monochrome

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cinematic: "Cinematic"
        case .moody: "Moody"
        case .vintage: "Vintage"
        case .brightAiry: "Bright & Airy"
        case .goldenHour: "Golden Hour"
        case .monochrome: "Monochrome"
        }
    }

    static let effectIds: Set<String> = [
        "color.exposure", "color.contrast", "color.highlightsShadows",
        "color.blacksWhites", "color.temperature", "color.vibrance", "color.saturation",
    ]

    var adjustments: [(type: String, params: [String: Double])] {
        switch self {
        case .cinematic:
            [
                ("color.exposure", ["ev": 0.1]),
                ("color.contrast", ["amount": 1.15]),
                ("color.highlightsShadows", ["highlights": -0.2, "shadows": 0.2]),
                ("color.blacksWhites", ["blacks": -0.1, "whites": 0.1]),
                ("color.temperature", ["temperature": 6800]),
                ("color.vibrance", ["amount": 0.15]),
                ("color.saturation", ["amount": 1.05]),
            ]
        case .moody:
            [
                ("color.exposure", ["ev": -0.15]),
                ("color.contrast", ["amount": 1.25]),
                ("color.highlightsShadows", ["highlights": -0.3, "shadows": -0.2]),
                ("color.blacksWhites", ["blacks": -0.15]),
                ("color.temperature", ["temperature": 6200]),
                ("color.saturation", ["amount": 0.95]),
            ]
        case .vintage:
            [
                ("color.contrast", ["amount": 0.9]),
                ("color.highlightsShadows", ["highlights": -0.1]),
                ("color.blacksWhites", ["blacks": 0.15]),
                ("color.temperature", ["temperature": 7200]),
                ("color.vibrance", ["amount": -0.1]),
                ("color.saturation", ["amount": 0.85]),
            ]
        case .brightAiry:
            [
                ("color.exposure", ["ev": 0.3]),
                ("color.contrast", ["amount": 0.9]),
                ("color.highlightsShadows", ["highlights": -0.25, "shadows": 0.25]),
                ("color.blacksWhites", ["whites": 0.1]),
                ("color.temperature", ["temperature": 6300]),
                ("color.vibrance", ["amount": 0.1]),
            ]
        case .goldenHour:
            [
                ("color.exposure", ["ev": 0.1]),
                ("color.contrast", ["amount": 1.05]),
                ("color.highlightsShadows", ["highlights": -0.15, "shadows": 0.1]),
                ("color.temperature", ["temperature": 7800, "tint": 10]),
                ("color.vibrance", ["amount": 0.2]),
            ]
        case .monochrome:
            [
                ("color.saturation", ["amount": 0]),
                ("color.contrast", ["amount": 1.2]),
                ("color.blacksWhites", ["blacks": -0.1, "whites": 0.1]),
            ]
        }
    }
}
