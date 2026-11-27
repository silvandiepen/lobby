// SPDX-License-Identifier: MPL-2.0
import Foundation

/// One subtitle the player could show for what is about to play, whoever shows it: the player
/// itself (a stream's rendition, a track inside the file) or the app, which draws it.
public struct SubtitleCandidate: Hashable, Sendable {
    /// The caller's own key for it.
    public var id: String
    /// Any code the server, a file or the player gives ("nl", "dut", "en-GB"). nil: unknown.
    public var language: String?
    public var isForced: Bool
    /// The player itself shows it. Preferred over the same subtitle drawn by the app.
    public var isNative: Bool

    public init(id: String, language: String?, isForced: Bool, isNative: Bool) {
        self.id = id
        self.language = language
        self.isForced = isForced
        self.isNative = isNative
    }
}

/// Which subtitle a viewer's preferences ask for when a film starts.
///
/// 1. Subtitles on: the first of the viewer's languages that the film has as full subtitles.
/// 2. Otherwise, with forced subtitles on: forced ones, first in the language of the sound,
///    then in the viewer's languages, then in the device's.
/// 3. Otherwise none.
///
/// A subtitle of unknown language is never chosen by itself: the menu still has it.
public enum SubtitleChooser {
    public static func choose(
        from candidates: [SubtitleCandidate], preferences: SubtitlePreferences, soundLanguage: String?,
        deviceLanguages: [String]
    ) -> SubtitleCandidate? {
        func best(_ language: String, forced: Bool) -> SubtitleCandidate? {
            let matching = candidates.filter { candidate in
                candidate.isForced == forced && SubtitleLanguage.base(candidate.language) == language
            }
            return matching.first(where: \.isNative) ?? matching.first
        }
        let wanted = preferences.languages.compactMap(SubtitleLanguage.base)
        for language in wanted {
            if let found = best(language, forced: false) { return found }
        }
        guard preferences.forced else { return nil }
        var order: [String] = []
        for language in [SubtitleLanguage.base(soundLanguage)].compactMap({ $0 }) + wanted + deviceLanguages.compactMap(SubtitleLanguage.base)
        where !order.contains(language) {
            order.append(language)
        }
        for language in order {
            if let found = best(language, forced: true) { return found }
        }
        return nil
    }
}

/// Language codes as they come: ISO 639-1 ("nl"), 639-2 in either form ("nld", "dut"), with a
/// region ("en-GB", "pt_BR").
public enum SubtitleLanguage {
    /// The two-letter code when there is one, else the code itself, lower case. nil for nothing
    /// or "und".
    public static func base(_ code: String?) -> String? {
        guard let code else { return nil }
        let lowered = code.trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init),
            !first.isEmpty, first != "und", first != "zxx", first != "mul"
        else { return nil }
        if first.count == 2 { return first }
        if let known = bibliographic[first] { return known }
        if let alpha2 = Locale.LanguageCode(first).identifier(.alpha2) { return alpha2 }
        return first
    }

    /// ISO 639-2/B codes, which Matroska files and older tools use and Foundation may not know.
    private static let bibliographic: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl",
        "fre": "fr", "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "mao": "mi",
        "may": "ms", "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
        // And the common T codes, so this does not hang on what Foundation knows.
        "eng": "en", "nld": "nl", "deu": "de", "fra": "fr", "spa": "es", "ita": "it", "rus": "ru",
        "hye": "hy", "por": "pt", "zho": "zh", "jpn": "ja", "kor": "ko", "ara": "ar", "tur": "tr",
        "pol": "pl", "swe": "sv", "nor": "no", "nob": "nb", "dan": "da", "fin": "fi", "ces": "cs",
        "ell": "el", "heb": "he", "hun": "hu", "ukr": "uk", "fas": "fa", "ron": "ro", "slk": "sk",
        "hin": "hi", "tha": "th", "vie": "vi", "ind": "id", "msa": "ms", "cat": "ca", "hrv": "hr",
        "srp": "sr", "bul": "bg", "slv": "sl", "est": "et", "lav": "lv", "lit": "lt", "isl": "is",
        "kat": "ka", "sqi": "sq", "eus": "eu", "cym": "cy", "gle": "ga", "fry": "fy",
    ]
}
