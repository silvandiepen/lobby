// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// The cues of one WebVTT subtitle, as Lobby Server serves it and as a download stores it.
///
/// The app draws these itself over the picture, timed from the player's clock, for subtitles
/// the player cannot offer: a file that plays directly has no playlist to list them, a stream
/// that started while its copy was being written lists only some, and a downloaded copy
/// carries none (`docs/playback.md`).
struct SubtitleCues: Hashable, Sendable {
    struct Cue: Hashable, Sendable {
        var startMs: Int
        var endMs: Int
        var text: String
    }

    /// In order of start time.
    private(set) var cues: [Cue]

    init(cues: [Cue]) {
        self.cues = cues.sorted { $0.startMs < $1.startMs }
    }

    /// Reads WebVTT. What is not a cue (the header, notes, styles, regions) is skipped, cue
    /// settings and markup are dropped, and a cue that cannot be read is left out: one bad
    /// line must not cost the film its subtitles.
    init(webVTT text: String) {
        var cues: [Cue] = []
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for block in normalised.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                let start = Self.milliseconds(parts[0]),
                let end = Self.milliseconds(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""),
                end > start
            else { continue }
            let body = lines[(timing + 1)...].map(Self.plain).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(Cue(startMs: start, endMs: end, text: body))
        }
        self.init(cues: cues)
    }

    var isEmpty: Bool { cues.isEmpty }
    var count: Int { cues.count }

    /// What is on screen at a position in the film: nothing, one cue, or several at once (a
    /// sign and a line of speech), one under the other.
    func text(atMs position: Int) -> String? {
        // The last cue that starts at or before the position, found by halving.
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].startMs <= position { low = middle + 1 } else { high = middle }
        }
        var showing: [String] = []
        var index = low - 1
        // Cues that overlap start close together: looking a few back is enough.
        while index >= 0, low - index <= 8 {
            if cues[index].endMs > position { showing.insert(cues[index].text, at: 0) }
            index -= 1
        }
        return showing.isEmpty ? nil : showing.joined(separator: "\n")
    }

    /// "00:01:02.500", "01:02.500" or "1:02,500" (as in SubRip) to milliseconds.
    static func milliseconds(_ timestamp: String) -> Int? {
        let trimmed = timestamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let clock = trimmed.split(separator: ":").map(String.init)
        guard (2...3).contains(clock.count), let seconds = Double(clock[clock.count - 1]), seconds >= 0,
            let minutes = Int(clock[clock.count - 2]), minutes >= 0
        else { return nil }
        var hours = 0
        if clock.count == 3 {
            guard let value = Int(clock[0]), value >= 0 else { return nil }
            hours = value
        }
        return hours * 3_600_000 + minutes * 60_000 + Int((seconds * 1000).rounded())
    }

    /// A cue line without its markup: `<i>`, `<c.yellow>`, `<v Roger>`, `<00:01.000>`, and the
    /// few character references WebVTT has.
    static func plain(_ line: String) -> String {
        var result = ""
        var insideTag = false
        for character in line {
            if character == "<" {
                insideTag = true
            } else if character == ">" , insideTag {
                insideTag = false
            } else if !insideTag {
                result.append(character)
            }
        }
        for (reference, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&lrm;", ""), ("&rlm;", "")] {
            result = result.replacingOccurrences(of: reference, with: character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// A subtitle the viewer can pick that the player's own menu does not have.
struct SubtitleOption: Hashable, Sendable, Identifiable {
    enum Source: Hashable, Sendable {
        /// `GET /v1/assets/{id}/subtitles/{id}.vtt`.
        case server(assetID: String, track: SubtitleTrack)
        /// The file a download stored beside the film.
        case stored(itemID: String, subtitleID: String)
    }

    var id: String
    /// "Dutch", "English (forced)", or the track's own title.
    var label: String
    var source: Source
    /// As the server or the download has it ("nl", "eng"). nil: unknown.
    var language: String? = nil
    var isForced = false

    static func label(language: String?, title: String?, isForced: Bool, position: Int) -> String {
        let name: String
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            name = title
        } else if let language, let display = Locale.current.localizedString(forLanguageCode: language) {
            name = display.prefix(1).uppercased() + display.dropFirst()
        } else {
            name = "Subtitles \(position)"
        }
        return isForced ? "\(name) (forced)" : name
    }
}

/// Which subtitles the app has to draw itself for what is about to play.
enum SubtitleChoices {
    /// What kind of thing plays.
    enum Playing: Hashable, Sendable {
        /// The original file from the server. Its embedded text tracks are in the file, and
        /// the player's own menu has them. Subtitle files beside it are not.
        case direct
        /// The server's copy as a stream. Its playlist lists the subtitle files at once, and
        /// the embedded tracks only when the copy was complete when playback started.
        case stream(stillBeingWritten: Bool)
        /// The copy on this device, with the subtitles the download stored.
        case local(stored: [LocalSubtitle])
    }

    static func options(for file: MediaFile, itemID: String, playing: Playing) -> [SubtitleOption] {
        let tracks = file.subtitles.filter(\.isText)
        func option(_ track: SubtitleTrack, _ position: Int, _ source: SubtitleOption.Source) -> SubtitleOption {
            SubtitleOption(
                id: track.id,
                label: SubtitleOption.label(language: track.language, title: track.title, isForced: track.isForced, position: position),
                source: source, language: track.language, isForced: track.isForced)
        }

        // Subtitles stored as pictures are in no player's menu: the app draws them, from the
        // server, wherever they are (docs/decisions.md, "Subtitles per viewer").
        let pictures = file.subtitles.filter(\.isPicture).enumerated().map { position, track in
            option(track, tracks.count + position + 1, .server(assetID: file.assetId, track: track))
        }

        switch playing {
        case .direct:
            return tracks.enumerated().compactMap { position, track in
                track.source == .sidecar ? option(track, position + 1, .server(assetID: file.assetId, track: track)) : nil
            } + pictures
        case .stream(let stillBeingWritten):
            guard stillBeingWritten else { return pictures }
            return tracks.enumerated().compactMap { position, track in
                track.source == .embedded ? option(track, position + 1, .server(assetID: file.assetId, track: track)) : nil
            } + pictures
        case .local(let stored):
            // A copy of a file that plays as it is still has its embedded tracks inside. A
            // repackaged copy has none.
            let embeddedAreInTheFile = file.playability == .direct
            return stored.enumerated().compactMap { position, subtitle in
                let track = tracks.first { $0.id == subtitle.id }
                if embeddedAreInTheFile, track?.source == .embedded { return nil }
                return SubtitleOption(
                    id: subtitle.id,
                    label: SubtitleOption.label(language: subtitle.language, title: subtitle.title, isForced: subtitle.isForced, position: position + 1),
                    source: .stored(itemID: itemID, subtitleID: subtitle.id), language: subtitle.language,
                    isForced: subtitle.isForced)
            }
        }
    }
}
