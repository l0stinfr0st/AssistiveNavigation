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

            Section("Audio") {
                Slider(value: $profile.audioVolume, in: 0.2...1.0, step: 0.05) {
                    Text("Spoken feedback volume")
                }
                .accessibilityLabel("Spoken feedback volume")

                Slider(value: $profile.speechRate, in: 0.35...1.1, step: 0.05) {
                    Text("Speech rate")
                }
                .accessibilityLabel("Speech rate")
            }

            Section("Accessibility") {
                Toggle("Voice control for dictation", isOn: $profile.voiceControlEnabled)
                    .accessibilityHint("Allows speaking hazard descriptions on the report screen")

                Toggle("Spoken feedback", isOn: $profile.spokenFeedbackEnabled)
                    .accessibilityHint("Announces confirmations, errors, and navigation cues")
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
