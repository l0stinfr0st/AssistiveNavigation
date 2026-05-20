import SwiftUI

struct LiDARCaptureTestView: View {
    @AppStorage("launch_lidar_capture_test") private var launchLiDARCaptureTest = true
    @EnvironmentObject private var streaming: DepthStreamingSettings
    @State private var showingStreamingSheet = false

    var body: some View {
        ZStack(alignment: .top) {
            LiDARDepthMapView(fillScreen: true)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    statusPill(
                        title: "Depth Test",
                        value: "ARKit depth + pose"
                    )

                    statusPill(
                        title: "Streaming",
                        value: streaming.enabled ? "\(streaming.host):\(streaming.port)" : "Off"
                    )
                }

                HStack(spacing: 10) {
                    Button("Streaming") {
                        showingStreamingSheet = true
                    }
                    .buttonStyle(OverlayActionButtonStyle())

                    Button("Open App") {
                        launchLiDARCaptureTest = false
                    }
                    .buttonStyle(OverlayActionButtonStyle())
                }
            }
            .padding(.horizontal)
            .padding(.top, 18)
        }
        .sheet(isPresented: $showingStreamingSheet) {
            NavigationStack {
                LiDARStreamingSettingsView()
                    .environmentObject(streaming)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func statusPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct LiDARStreamingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var streaming: DepthStreamingSettings

    var body: some View {
        Form {
            Section("Laptop streaming") {
                Toggle("Enable UDP streaming", isOn: $streaming.enabled)

                TextField("Host", text: $streaming.host)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()

                TextField("Port", value: $streaming.port, format: .number)
                    .keyboardType(.numberPad)

                HStack {
                    Text("Max FPS")
                    Spacer()
                    Text("\(Int(streaming.maxFPS))")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $streaming.maxFPS, in: 1...60, step: 1)
            }

            Section("Receiver") {
                Text("On your computer, run `python3 streaming/receive_depth_udp.py --port \(streaming.port)` from this repo.")
                    .font(.footnote)
            }
        }
        .navigationTitle("LiDAR Test")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

private struct OverlayActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(configuration.isPressed ? 0.65 : 0.45))
            .clipShape(Capsule())
    }
}
