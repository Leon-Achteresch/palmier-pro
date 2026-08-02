import Foundation

/// A skill is a folder under `~/.palmier/skills/<id>/` with a `SKILL.md` file
struct Skill: Identifiable, Sendable {
    let id: String  // folder name
    let name: String
    let description: String
    let path: URL  // the SKILL.md file
}

enum SkillFrontmatter {
    /// Splits a SKILL.md into its frontmatter fields and body
    static func parse(_ text: String) -> (fields: [String: String], body: String) {
        var fields: [String: String] = [:]
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (fields, text)
        }
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            i += 1
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(">") || value.hasPrefix("|") {
                let separator = value.hasPrefix("|") ? "\n" : " "
                var block: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---",
                      lines[i].hasPrefix(" ") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    block.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                value = block.joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        let body = i + 1 < lines.count
            ? lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (fields, body)
    }

    static func requiredFields(_ text: String) -> (name: String, description: String, body: String)? {
        let parsed = parse(text)
        guard let name = parsed.fields["name"], !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let description = parsed.fields["description"],
              !description.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (name, description, parsed.body)
    }

    static func replacingName(_ text: String, name: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return "---\nname: \(name)\n---\n\n" + text
        }
        var front: [String] = []
        var replaced = false
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            if let colon = lines[i].firstIndex(of: ":"),
               lines[i][..<colon].trimmingCharacters(in: .whitespaces) == "name" {
                front.append("name: \(name)"); replaced = true
            } else {
                front.append(lines[i])
            }
            i += 1
        }
        if !replaced { front.insert("name: \(name)", at: 0) }
        let rest = i < lines.count ? lines[i...].joined(separator: "\n") : "---"
        return "---\n" + front.joined(separator: "\n") + "\n" + rest
    }
}
