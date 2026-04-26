import Foundation

class DictionaryStore {
    static let shared = DictionaryStore()
    private var mappings: [String: String] = [:]
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("OpenWhispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("dictionary.json")
        load()
    }

    var entries: [String: String] { mappings }

    func add(original: String, corrected: String) {
        let key = original.lowercased()
        guard key != corrected.lowercased() else { return }
        mappings[key] = corrected
        save()
        print("[Dictionary] Learned: \"\(original)\" → \"\(corrected)\"")
    }

    func remove(original: String) {
        mappings.removeValue(forKey: original.lowercased())
        save()
    }

    /// Apply all dictionary replacements to text (case-insensitive match, preserves learned casing)
    func apply(to text: String) -> String {
        guard !mappings.isEmpty else { return text }

        var result = text
        for (original, corrected) in mappings {
            // Case-insensitive word boundary replacement
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: original))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: corrected
                )
            }
        }
        return result
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        mappings = dict
        print("[Dictionary] Loaded \(mappings.count) entries")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        try? data.write(to: fileURL)
    }
}
