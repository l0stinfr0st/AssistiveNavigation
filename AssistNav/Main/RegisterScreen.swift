import SwiftUI

struct RegisterView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ZStack {
            AppBackgroundView()

            VStack(spacing: 20) {
                Text("Register")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 16) {
                    TextField(
                        "",
                        text: $vm.registerUsername,
                        prompt: Text("Username").foregroundStyle(.black.opacity(0.55))
                    )
                        .foregroundColor(.black)
                        .tint(.black)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .colorScheme(.light)

                    TextField(
                        "",
                        text: $vm.registerEmail,
                        prompt: Text("Email").foregroundStyle(.black.opacity(0.55))
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.default)
                        .foregroundColor(.black)
                        .tint(.black)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .colorScheme(.light)

                    SecureField(
                        "",
                        text: $vm.registerPassword,
                        prompt: Text("Password").foregroundStyle(.black.opacity(0.55))
                    )
                        .foregroundColor(.black)
                        .tint(.black)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .colorScheme(.light)

                    SecureField(
                        "",
                        text: $vm.registerConfirmPassword,
                        prompt: Text("Confirm password").foregroundStyle(.black.opacity(0.55))
                    )
                        .foregroundColor(.black)
                        .tint(.black)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .colorScheme(.light)
                }

                if let msg = vm.bannerMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel(msg)
                }

                Button("Register") {
                    vm.register()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.white.opacity(0.95))
                .foregroundStyle(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button("Have an account?") {
                    vm.switchToLogin()
                }
                .foregroundStyle(.white)

                Button("Continue as guest") {
                    vm.continueAsGuest()
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            .padding()
        }
    }
}
