import SwiftUI
import Speech
import AVFoundation

struct ReportView: View {
    @EnvironmentObject var vm: AppViewModel
    @StateObject private var dictation = SpeechDictationService()

    @State private var hazardType = "Hole"
    @State private var descriptionText = ""
    @State private var localBanner: String?

    private let types = ["Hole", "Broken stairs", "Other obstacle"]

    var body: some View {
        NavigationStack {
            Form {
                if let msg = localBanner ?? vm.bannerMessage {
                    Section {
                        Text(msg)
                            .foregroundStyle(.red)
                            .accessibilityLabel(msg)
                    }
                }

                Section("Hazard type") {
                    Picker("Type", selection: $hazardType) {
                        ForEach(types, id: \.self) { t in
                            Text(t).tag(t)
                        }
                    }
                    .accessibilityHint("Choose the type of obstacle you are reporting")
                }

                Section("Description") {
                    TextField("Describe what you encountered", text: $descriptionText, axis: .vertical)
                        .lineLimit(3...6)

                    Button {
                        Task { await toggleVoice() }
                    } label: {
                        Label(
                            dictation.isListening ? "Stop voice input" : "Speak description",
                            systemImage: dictation.isListening ? "stop.circle" : "mic.circle"
                        )
                    }
                    .disabled(!(vm.activeUser?.voiceControlEnabled ?? true))

                    if let err = dictation.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Submit Report") {
                        submit()
                    }
                    .disabled(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)

                    Button("Cancel", role: .cancel) {
                        dictation.stopDictation()
                        vm.cancelReportFlow()
                    }
                }
            }
            .navigationTitle("Report hazard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func submit() {
        localBanner = nil
        let text = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else {
            localBanner = "Add a short description (or use voice input)."
            vm.announceToUser(localBanner!)
            return
        }
        dictation.stopDictation()
        vm.submitReport(type: hazardType, details: text)
        descriptionText = ""
    }

    private func toggleVoice() async {
        localBanner = nil
        let mic = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        guard mic else {
            dictation.lastError = "Microphone access denied."
            vm.announceToUser("Microphone access is required for voice input.")
            return
        }

        let speech = await dictation.requestAuthorization()
        guard speech == .authorized else {
            dictation.lastError = "Speech recognition is not authorized."
            vm.announceToUser("Enable speech recognition in Settings to dictate descriptions.")
            return
        }

        if dictation.isListening {
            dictation.stopDictation()
        } else {
            dictation.startDictation { partial in
                descriptionText = partial
            }
        }
    }
}
