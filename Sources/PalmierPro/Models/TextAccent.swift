import Foundation

/// Words held in a second colour for the whole clip, unlike `TextAnimation.highlight`, which only
/// tints a word while it is animating.
struct TextAccent: Codable, Sendable, Equatable, Hashable {
    var color: TextStyle.RGBA
    var words: [Int]

    init(color: TextStyle.RGBA, words: [Int]) {
        self.color = color
        self.words = words.filter { $0 >= 0 }.sorted()
    }

    var isActive: Bool { !words.isEmpty }

    func covers(_ wordIndex: Int) -> Bool { words.contains(wordIndex) }

    func color(forWord index: Int, base: TextStyle.RGBA) -> TextStyle.RGBA {
        covers(index) ? color : base
    }

    /// The word tokens the accent's indices address. Every surface that resolves, renders, or picks
    /// accent words must go through this, or the indices stop meaning the same thing.
    static func tokens(in content: String) -> [(range: NSRange, text: String)] {
        let ns = content as NSString
        let ws = CharacterSet.whitespacesAndNewlines
        // A surrogate half (emoji etc.) maps to no scalar — treat it as part of a word, not whitespace.
        func isSpace(_ u: unichar) -> Bool { Unicode.Scalar(u).map(ws.contains) ?? false }
        var result: [(NSRange, String)] = []
        var i = 0
        while i < ns.length {
            while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
            guard i < ns.length else { break }
            let start = i
            while i < ns.length, !isSpace(ns.character(at: i)) { i += 1 }
            let r = NSRange(location: start, length: i - start)
            result.append((r, ns.substring(with: r)))
        }
        return result
    }

    /// Case- and punctuation-insensitive form used to match a requested word against a token.
    static func matchKey(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            color: try c.decode(TextStyle.RGBA.self, forKey: .color),
            words: (try? c.decode([Int].self, forKey: .words)) ?? []
        )
    }
}
