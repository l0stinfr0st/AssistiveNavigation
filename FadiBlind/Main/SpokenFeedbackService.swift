import AVFoundation

@MainActor
final class SpokenFeedbackService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    private var pendingFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        _ text: String,
        volume: Double = 1.0,
        rateMultiplier: Double = 1.0,
        includeFinishHandler: Bool = false
    ) {
        guard !text.isEmpty else { return }
        if !includeFinishHandler {
            let old = pendingFinish
            pendingFinish = nil
            old?()
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.volume = Float(volume)
        let base = AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = Float(base) * Float(rateMultiplier)
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0.05
        synthesizer.speak(utterance)
    }

    func speakAndWait(_ text: String, volume: Double, rateMultiplier: Double) async {
        guard !text.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pendingFinish = { cont.resume() }
            speak(text, volume: volume, rateMultiplier: rateMultiplier, includeFinishHandler: true)
        }
    }

    func stopImmediately() {
        pendingFinish = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let finish = pendingFinish
            pendingFinish = nil
            finish?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let finish = pendingFinish
            pendingFinish = nil
            finish?()
        }
    }
}
