// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import NaturalLanguage
import Observation

/// Says a title out loud, for a child who does not read yet.
@MainActor
@Observable
final class TitleSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// The words are heard right now.
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ title: String) {
        synthesizer.stopSpeaking(at: .immediate)
        #if os(iOS)
        // Heard with the silent switch on too: a child asked for it with a tap, as with a
        // film. Other sound goes softer for the moment it takes. When the session cannot be
        // had, the words are still spoken, in the app's ordinary one.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? session.setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: title)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.language(of: title, preferred: Locale.preferredLanguages))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The language a title is in, when that is clear and it is one the household uses (the
    /// device's languages, and English). A name says nothing about its language: then it is
    /// the device's.
    static func language(of title: String, preferred: [String]) -> String {
        let device = preferred.first ?? "en"
        let recognizer = NLLanguageRecognizer()
        let codes = (preferred + ["en"]).map { String($0.prefix(while: { $0 != "-" && $0 != "_" })) }
        recognizer.languageConstraints = codes.map { NLLanguage($0) }
        recognizer.processString(title)
        guard title.split(separator: " ").count >= 3,
            let (language, certainty) = recognizer.languageHypotheses(withMaximum: 1).first, certainty >= 0.8
        else { return device }
        return preferred.first { $0.hasPrefix(language.rawValue) } ?? language.rawValue
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = self.synthesizer.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Said again at once: it is still speaking then.
        Task { @MainActor in isSpeaking = self.synthesizer.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = self.synthesizer.isSpeaking }
        #if os(iOS)
        // Whatever played softer gets its sound back.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
