import SwiftUI
import PhotosUI
import Speech
import AVFoundation

struct ReportView: View {
    @EnvironmentObject var vm: AppViewModel
    @StateObject private var dictation = SpeechDictationService()

    @State private var hazardType = "Hole"
    @State private var descriptionText = ""
    @State private var dangerLevel = "Medium"
    @State private var persistenceLevel = "Medium"
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    @State private var localBanner: String?
    @State private var isSubmitting = false

    private let types = ["Hole", "Broken stairs", "Wet floor", "Obstacle", "Construction", "Other"]
    private let dangerLevels = ["Low", "Medium", "High", "Critical"]
    private let persistenceLevels = ["Temporary", "Short", "Medium", "Long", "Permanent"]

    var body: some View {
        ZStack {
            AppBackgroundView()

            NavigationStack {
                Form {
                    if let msg = localBanner ?? vm.bannerMessage {
                        Section {
                            Text(msg)
                                .foregroundStyle(.red)
                                .accessibilityLabel(msg)
                        }
                    }

                    Section("Hazard details") {
                        Picker("Type", selection: $hazardType) {
                            ForEach(types, id: \.self) { type in
                                Text(type).tag(type)
                            }
                        }

                        Picker("Danger level", selection: $dangerLevel) {
                            ForEach(dangerLevels, id: \.self) { level in
                                Text(level).tag(level)
                            }
                        }

                        Picker("Persistence", selection: $persistenceLevel) {
                            ForEach(persistenceLevels, id: \.self) { level in
                                Text(level).tag(level)
                            }
                        }
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
                        .disabled(!(vm.profile?.voiceControlEnabled ?? true))

                        if let err = dictation.lastError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label(selectedPhotoData == nil ? "Choose Photo" : "Change Photo", systemImage: "photo")
                        }

                        if let image = selectedUIImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            Button("Remove Photo", role: .destructive) {
                                selectedPhotoItem = nil
                                selectedPhotoData = nil
                            }
                        }
                    } header: {
                        Text("Photo (optional)")
                    } footer: {
                        Text("Reports need multiple confirmations before they are accepted, and multiple resolve votes before they disappear.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Button {
                            Task { await submitAsync() }
                        } label: {
                            if isSubmitting {
                                HStack {
                                    ProgressView()
                                    Text("Submitting…")
                                }
                            } else {
                                Text("Submit Report")
                            }
                        }
                        .disabled(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || isSubmitting)

                        Button("Cancel", role: .cancel) {
                            dictation.stopDictation()
                            vm.cancelReportFlow()
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationTitle("Report hazard")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: selectedPhotoItem) {
            if let selectedPhotoItem,
               let data = try? await selectedPhotoItem.loadTransferable(type: Data.self) {
                selectedPhotoData = compressJPEG(data: data)
            }
        }
        .onAppear {
            vm.primeLocationForReport()
        }
    }

    private var selectedUIImage: UIImage? {
        guard let selectedPhotoData else { return nil }
        return UIImage(data: selectedPhotoData)
    }

    private func submitAsync() async {
        localBanner = nil
        let text = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else {
            localBanner = "Add a short description (or use voice input)."
            return
        }

        dictation.stopDictation()
        isSubmitting = true
        await vm.submitReport(
            type: hazardType,
            details: text,
            dangerLevel: dangerLevel,
            persistenceLevel: persistenceLevel,
            photoJPEGBase64: selectedPhotoData?.base64EncodedString()
        )
        isSubmitting = false
        descriptionText = ""
        selectedPhotoItem = nil
        selectedPhotoData = nil
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
            return
        }

        let speech = await dictation.requestAuthorization()
        guard speech == .authorized else {
            dictation.lastError = "Speech recognition is not authorized."
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

    private func compressJPEG(data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.72)
    }
}
