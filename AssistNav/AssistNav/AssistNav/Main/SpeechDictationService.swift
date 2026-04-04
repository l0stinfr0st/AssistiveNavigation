import Speech
import AVFoundation

@MainActor
final class SpeechDictationService: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published var lastError: String?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    func startDictation(onPartialResult: @escaping (String) -> Void) {
        lastError = nil
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition is not available."
            return
        }

        stopDictation()
        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request else { return }
        request.shouldReportPartialResults = true

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try audioEngine.start()
        } catch {
            lastError = "Could not start microphone."
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result {
                    onPartialResult(result.bestTranscription.formattedString)
                    if result.isFinal {
                        self.stopDictation()
                    }
                }
                if error != nil {
                    self.lastError = error?.localizedDescription
                    self.stopDictation()
                }
            }
        }
    }

    func stopDictation() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
