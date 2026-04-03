import SwiftUI

struct RegisterView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue, Color.blue.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Register")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 16) {
                    TextField("Username", text: $vm.registerUsername)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    TextField("Email", text: $vm.registerEmail)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    SecureField("Password", text: $vm.registerPassword)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    SecureField("Confirm password", text: $vm.registerConfirmPassword)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
            }
            .padding()
        }
    }
}
