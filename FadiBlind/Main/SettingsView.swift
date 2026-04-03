import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        NavigationStack {
            Group {
                if let user = vm.activeUser {
                    UserSettingsForm(user: user)
                } else {
                    ContentUnavailableView("Not signed in", systemImage: "person.crop.circle.badge.xmark")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct UserSettingsForm: View {
    @Bindable var user: AppUser
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        Form {
            Section("Audio") {
                Slider(value: $user.audioVolume, in: 0.2...1.0, step: 0.05) {
                    Text("Spoken feedback volume")
                }
                .accessibilityLabel("Spoken feedback volume")

                Slider(value: $user.speechRate, in: 0.35...1.1, step: 0.05) {
                    Text("Speech rate")
                }
                .accessibilityLabel("Speech rate")
            }

            Section("Accessibility") {
                Toggle("Voice control for dictation", isOn: $user.voiceControlEnabled)
                    .accessibilityHint("Allows speaking hazard descriptions on the report screen")

                Toggle("Spoken feedback", isOn: $user.spokenFeedbackEnabled)
                    .accessibilityHint("Announces confirmations, errors, and navigation cues")
            }

            Section {
                Button("Save") {
                    vm.savePreferencesFromSettings()
                    vm.closeSettings()
                }

                Button("Cancel", role: .cancel) {
                    vm.cancelSettingsEdits()
                }

                Button("Logout", role: .destructive) {
                    vm.logout()
                }
            }
        }
    }
}
