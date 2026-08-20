import Foundation

/// YouTube-style chapter list written next to a rendered video when the timeline has chapter markers.
enum ChapterSidecar {

    static func url(nextTo outputURL: URL) -> URL {
        outputURL.deletingPathExtension().appendingPathExtension("chapters.txt")
    }

    /// "00:00 Intro" lines, one per chapter marker in frame order. Nil when there is nothing to write.
    static func text(markers: [TimelineMarker], fps: Int) -> String? {
        guard fps > 0 else { return nil }
        let chapters = markers.filter { $0.kind == .chapter }.sorted { $0.frame < $1.frame }
        guard !chapters.isEmpty else { return nil }
        let lines = chapters.enumerated().map { index, marker in
            "\(timestamp(frame: marker.frame, fps: fps)) \(title(of: marker, number: index + 1))"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "MM:SS", or "H:MM:SS" past the hour — the format YouTube parses.
    static func timestamp(frame: Int, fps: Int) -> String {
        guard fps > 0 else { return "00:00" }
        let totalSeconds = max(0, frame) / fps
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @concurrent
    static func write(_ text: String, nextTo outputURL: URL) async throws -> URL {
        let destination = url(nextTo: outputURL)
        try FileIO.writeData(Data(text.utf8), to: destination)
        return destination
    }

    /// Chapter titles are one line; newlines would break the list format.
    private static func title(of marker: TimelineMarker, number: Int) -> String {
        let trimmed = marker.name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Chapter \(number)" : trimmed
    }
}
