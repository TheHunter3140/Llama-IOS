import Foundation
import AVFoundation

/// Lecture à voix haute avec les voix de l'iPhone. Le synthétiseur n'est créé qu'au premier usage.
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speakingText: String?

    private var synth: AVSpeechSynthesizer?
    private var currentUtterance: AVSpeechUtterance?

    private func synthesizer() -> AVSpeechSynthesizer {
        if let existing = synth { return existing }
        let created = AVSpeechSynthesizer()
        created.delegate = self
        synth = created
        return created
    }

    func speak(_ text: String, voiceID: String?, rate: Double) {
        stop()
        let clean = Speaker.plain(text)
        guard !clean.isEmpty else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: clean)
        if let id = voiceID, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "fr-FR")
        }
        utterance.rate = Float(min(max(rate, 0.1), 0.6))
        currentUtterance = utterance
        speakingText = text
        synthesizer().speak(utterance)
    }

    func stop() {
        currentUtterance = nil
        speakingText = nil
        if let s = synth, s.isSpeaking {
            s.stopSpeaking(at: .immediate)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        speakingText = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finished(utterance) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finished(utterance) }
    }

    // MARK: utilitaires

    /// Retire la mise en forme Markdown pour que la voix ne lise pas les symboles.
    static func plain(_ text: String) -> String {
        var t = text
        if let blocks = try? NSRegularExpression(pattern: "```[\\s\\S]*?```") {
            let range = NSRange(t.startIndex..., in: t)
            t = blocks.stringByReplacingMatches(in: t, range: range, withTemplate: " (bloc de code) ")
        }
        for symbol in ["*", "`", "#", ">", "|"] {
            t = t.replacingOccurrences(of: symbol, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Voix installées dans la langue de l'iPhone, les meilleures d'abord.
    static func voices() -> [AVSpeechSynthesisVoice] {
        let lang = String((Locale.preferredLanguages.first ?? "fr").prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "premium"
        case .enhanced: return "améliorée"
        default: return "standard"
        }
    }
}
