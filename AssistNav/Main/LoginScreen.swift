import SwiftUI

struct LoginView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ZStack {
            AppBackgroundView()

            VStack(spacing: 20) {

                Text("LogIn")
                    .font(.largeTitle)
                    .foregroundColor(.white)

                TextField(
                    "",
                    text: $vm.usernameOrEmail,
                    prompt: Text("Email").foregroundStyle(.black.opacity(0.55))
                )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.default)
                    .foregroundColor(.black)
                    .tint(.black)
                    .padding()
                    .background(Color.white)
                    .cornerRadius(10)
                    .colorScheme(.light)

                SecureField(
                    "",
                    text: $vm.password,
                    prompt: Text("Password").foregroundStyle(.black.opacity(0.55))
                )
                    .foregroundColor(.black)
                    .tint(.black)
                    .padding()
                    .background(Color.white)
                    .cornerRadius(10)
                    .colorScheme(.light)

                if let msg = vm.bannerMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel(msg)
                }

                Button("Login") {
                    vm.login()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue.opacity(0.8))
                .foregroundColor(.white)
                .cornerRadius(10)

                Button("Register") {
                    vm.switchToRegister()
                }
                .foregroundColor(.white)

                Button("Continue as guest") {
                    vm.continueAsGuest()
                }
                .foregroundColor(.white.opacity(0.9))
            }
            .padding()
        }
    }
}
