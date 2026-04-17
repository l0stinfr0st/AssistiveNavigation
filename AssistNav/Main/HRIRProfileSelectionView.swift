import SwiftUI
import AVFoundation

struct HRIRProfileSelectionView: View {
    @ObservedObject var profile: EditableProfile

    @State private var selectedId: String
    @State private var tester = SpatialAudioTester()

    init(profile: EditableProfile) {
        self.profile = profile
        _selectedId = State(initialValue: profile.spatialAudio.hrirProfileRaw)
    }

    var body: some View {
        let items = HRIRProfileItem.defaultItems()

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose the HRIR that best matches your ear and head shape. Use the test at the bottom to compare.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("HRIR profile", selection: $selectedId) {
                        ForEach(items) { item in
                            Text(item.displayName).tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedId) { _, newValue in
                        profile.spatialAudio.hrirProfileRaw = newValue
                    }

                    if let selected = items.first(where: { $0.id == selectedId }) {
                        HRIRPreviewCard(item: selected)
                    }
                }
                .padding()
            }

            Divider()

            VStack(spacing: 10) {
                Text("Test spatial audio")
                    .font(.headline)

                Text("Plays a short moving sound so you can compare the profiles.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        tester.playTestSweep(
                            sweepSeconds: profile.spatialAudio.sweepDurationSeconds,
                            leftGain: profile.spatialAudio.leftVolume,
                            rightGain: profile.spatialAudio.rightVolume,
                            sensitivity: profile.spatialAudio.sensitivity
                        )
                    } label: {
                        Text(tester.isPlaying ? "Playing…" : "Play Test")
                            .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.92))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    Button(role: .cancel) {
                        tester.stop()
                    } label: {
                        Text("Stop")
                            .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .disabled(!tester.isPlaying)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle("HRIR Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { tester.stop() }
    }
}

private struct HRIRPreviewCard: View {
    let item: HRIRProfileItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.displayName)
                .font(.title3.weight(.semibold))
            Text(item.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Image(uiImage: item.previewImage)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct HRIRProfileItem: Identifiable {
    let id: String
    let displayName: String
    let description: String
    let previewImage: UIImage
    let sofaFilename: String

    static func defaultItems() -> [HRIRProfileItem] {
        [
            make(
                subject: "H5",
                description: "Subject H5 ear & head geometry",
                sofaFilename: "H5_48K_24bit_256tap_FIR_SOFA.sofa",
                screenshotFilename: "Screenshot 2026-04-07 at 15.23.59.png"
            ),
            make(
                subject: "H10",
                description: "Subject H10 ear & head geometry",
                sofaFilename: "H10_48K_24bit_256tap_FIR_SOFA.sofa",
                screenshotFilename: "Screenshot 2026-04-07 at 15.26.00.png"
            ),
            make(
                subject: "H20",
                description: "Subject H20 ear & head geometry",
                sofaFilename: "H20_48K_24bit_256tap_FIR_SOFA.sofa",
                screenshotFilename: "Screenshot 2026-04-07 at 15.26.12.png"
            ),
        ]
    }

    private static func make(subject: String, description: String, sofaFilename: String, screenshotFilename: String) -> HRIRProfileItem {
        let image = BundleImageLoader.loadImageFromHRIRFolder(filenameWithExtension: screenshotFilename) ?? UIImage()
        return HRIRProfileItem(
            id: subject,
            displayName: "HRIR \(subject)",
            description: description,
            previewImage: image,
            sofaFilename: sofaFilename
        )
    }
}

private enum BundleImageLoader {
    static func loadImageFromHRIRFolder(filenameWithExtension: String) -> UIImage? {
        // Files may be copied either:
        // - into the bundle root (when added as individual resources), or
        // - into a "HRIR Profiles" subdirectory (when added as a folder reference).
        if let url = Bundle.main.url(forResource: filenameWithExtension, withExtension: nil, subdirectory: "HRIR Profiles") {
            return UIImage(contentsOfFile: url.path)
        }
        if let url = Bundle.main.url(forResource: filenameWithExtension, withExtension: nil) {
            return UIImage(contentsOfFile: url.path)
        }

        // Fallback: scan all PNGs in the bundle and match by exact filename.
        if let urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil),
           let match = urls.first(where: { $0.lastPathComponent == filenameWithExtension })
        {
            return UIImage(contentsOfFile: match.path)
        }

        if let urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: "HRIR Profiles"),
           let match = urls.first(where: { $0.lastPathComponent == filenameWithExtension })
        {
            return UIImage(contentsOfFile: match.path)
        }

        return nil
    }
}

@MainActor
final class SpatialAudioTester {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let environment = AVAudioEnvironmentNode()

    private var stopTask: Task<Void, Never>?
    private(set) var isPlaying: Bool = false

    init() {
        engine.attach(player)
        engine.attach(environment)

        // Player -> Environment -> Output
        engine.connect(player, to: environment, format: nil)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        environment.renderingAlgorithm = .HRTFHQ
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.referenceDistance = 1.0
    }

    func playTestSweep(sweepSeconds: Double, leftGain: Double, rightGain: Double, sensitivity: Double) {
        stop()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }

        let duration = max(0.2, min(5.0, sweepSeconds))

        // Apply approximate L/R gains by shifting the source left/right across the sweep.
        // This isn't per-channel volume control, but it gives the user a clear comparison cue.
        let left = max(0.0, min(1.5, leftGain))
        let right = max(0.0, min(1.5, rightGain))

        do {
            try engine.start()
        } catch {
            return
        }

        // IMPORTANT: buffer format must match the player node's output format
        // or AVAudioPlayerNode will assert.
        let outputFormat = player.outputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : session.sampleRate
        let channels = max(1, Int(outputFormat.channelCount))
        let frameCount = AVAudioFrameCount(sampleRate * duration)

        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount

        // Simple tone burst – duplicated into all channels.
        let freq: Double = 740
        let ramp = max(0.05, min(0.25, 0.08 + (1.0 - sensitivity) * 0.15))
        let frames = Int(frameCount)
        for n in 0..<frames {
            let t = Double(n) / sampleRate
            let env = amplitudeEnvelope(t: t, total: duration, ramp: ramp)
            let s = Float(sin(2.0 * .pi * freq * t) * env)
            for c in 0..<channels {
                buffer.floatChannelData?[c][n] = s
            }
        }

        isPlaying = true
        player.play()

        // Schedule the buffer, while we move the source position over time.
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                self?.stop()
            }
        }

        stopTask = Task { [weak self] in
            guard let self else { return }
            let steps = 60
            for i in 0...steps {
                try? await Task.sleep(nanoseconds: UInt64((duration / Double(steps)) * 1_000_000_000))
                let p = Double(i) / Double(steps)
                // -90°..+90° azimuth; weight by "channel gains".
                let az = (-90.0 + 180.0 * p)
                let x = Float(sin(az * .pi / 180.0))
                let weightedX = x * Float(0.5 * (right + left)) * (x >= 0 ? Float(right) : Float(left))
                self.player.position = AVAudio3DPoint(x: weightedX, y: 0, z: -1)
            }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil

        if player.isPlaying {
            player.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
        isPlaying = false
    }

    private func amplitudeEnvelope(t: Double, total: Double, ramp: Double) -> Double {
        let r = max(0.001, min(total / 2.0, ramp))
        if t < r { return t / r }
        if t > total - r { return max(0, (total - t) / r) }
        return 1.0
    }
}

