import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ZStack {
            AppBackgroundView()

            NavigationStack {
                Group {
                    if let user = vm.profile {
                        UserSettingsForm(profile: user)
                    } else {
                        ContentUnavailableView("Not signed in", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

private struct UserSettingsForm: View {
    @ObservedObject var profile: EditableProfile
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject private var streaming: DepthStreamingSettings

    var body: some View {
        Form {
            Section("Account") {
                Text(profile.username)
                    .font(.headline)
                if let email = profile.email, !email.isEmpty {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Spatial audio") {
                NavigationLink {
                    HRIRProfileSelectionView(profile: profile)
                } label: {
                    HStack {
                        Text("HRIR profile")
                        Spacer()
                        Text(profile.spatialAudio.hrirProfileRaw.isEmpty ? "Select" : profile.spatialAudio.hrirProfileRaw)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Left channel volume")
                    Slider(value: $profile.spatialAudio.leftVolume, in: 0.0...1.25, step: 0.05)
                        .accessibilityLabel("Left channel volume")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Right channel volume")
                    Slider(value: $profile.spatialAudio.rightVolume, in: 0.0...1.25, step: 0.05)
                        .accessibilityLabel("Right channel volume")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sweep duration")
                    Slider(value: $profile.spatialAudio.sweepDurationSeconds, in: 0.2...3.0, step: 0.05)
                        .accessibilityLabel("Sweep duration")
                    Text("\(profile.spatialAudio.sweepDurationSeconds, format: .number.precision(.fractionLength(2))) seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sensitivity")
                    Slider(value: $profile.spatialAudio.sensitivity, in: 0.0...1.0, step: 0.01)
                        .accessibilityLabel("Sensitivity")
                    Text("\(profile.spatialAudio.sensitivity, format: .number.precision(.fractionLength(2)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Accessibility") {
                Toggle("Voice control for dictation", isOn: $profile.voiceControlEnabled)
                    .accessibilityHint("Allows speaking hazard descriptions on the report screen")
            }

            Section("LiDAR streaming") {
                Toggle("Stream depth to laptop", isOn: $streaming.enabled)

                TextField("Host (IP or hostname)", text: $streaming.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("5050", value: $streaming.port, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }

                HStack {
                    Text("Max FPS")
                    Spacer()
                    Text("\(Int(streaming.maxFPS))")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $streaming.maxFPS, in: 1...60, step: 1)
            }

            Section {
                Button("Save") {
                    vm.savePreferencesFromSettings()
                }

                Button("Cancel", role: .cancel) {
                    vm.cancelSettingsEdits()
                }

                Button("Logout", role: .destructive) {
                    vm.logout()
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}
