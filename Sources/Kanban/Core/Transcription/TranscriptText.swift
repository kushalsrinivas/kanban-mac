import Foundation

/// Text cleanup after decoding, ported from Handy's `audio_toolkit/text.rs`.
///
/// Handy's fuzzy custom-word correction is not duplicated: whisper receives the
/// custom words as `RunOptions.vocabulary`, and Handy skips fuzzy correction in
/// exactly that case (`custom_words_prompted`).
enum TranscriptText {

    /// Removed whatever the output language (they are not words in any of the
    /// model's languages).
    static let universalFillers: Set<String> = [
        "uh", "uhm", "umm", "uhh", "uhhh", "ehh", "ehm", "ahm", "hmm", "hm", "mmm", "хм", "ммм",
    ]

    /// Only safe with evidence for the output language: the same token is a real
    /// word elsewhere (Portuguese "um", German "um", Spanish "ha").
    static func gatedFillers(_ language: String?) -> Set<String> {
        guard let language else { return [] }
        let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        switch base {
        case "en": return ["um", "ah", "eh"]
        case "de": return ["äh", "ähm"]
        case "fr": return ["euh"]
        default: return []
        }
    }

    /// Handy's order: fillers, then non-filler cleanup. A short clip that came
    /// back as just "." or "?" becomes empty.
    static func postProcess(_ raw: String, language: String?,
                            removeFillers: Bool = true) -> String {
        var text = raw
        if removeFillers {
            text = self.removeFillers(text, language: language)
        }
        text = normalize(text)
        return text.contains(where: { $0.isLetter || $0.isNumber }) ? text : ""
    }

    static func removeFillers(_ text: String, language: String?) -> String {
        let fillers = universalFillers.union(gatedFillers(language))
        guard !fillers.isEmpty else { return text }
        var kept: [String] = []
        var capitalizeNext = false

        for token in text.split(whereSeparator: \.isWhitespace) {
            let core = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
            if !core.isEmpty, fillers.contains(core) {
                // A capitalized filler that opened a sentence owes the next word
                // its capital ("UHM this is" → "This is").
                capitalizeNext = opensSentence(kept) && token.first?.isUppercase == true
                continue
            }
            var word = String(token)
            if capitalizeNext, let first = word.first {
                word = first.uppercased() + word.dropFirst()
                capitalizeNext = false
            }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    /// Collapses 3+ repeated alphabetic words to one, then whitespace.
    static func normalize(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return "" }
        var result: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let lower = word.lowercased()
            if lower.allSatisfy(\.isLetter) {
                var count = 1
                while index + count < words.count, words[index + count].lowercased() == lower {
                    count += 1
                }
                result.append(word)
                index += count >= 3 ? count : 1
            } else {
                result.append(word)
                index += 1
            }
        }
        return result.joined(separator: " ")
    }

    private static func opensSentence(_ kept: [String]) -> Bool {
        guard let last = kept.last(where: { !$0.isEmpty }),
              let character = last.last(where: { !$0.isWhitespace }) else { return true }
        return ".!?…。！？".contains(character)
    }
}
