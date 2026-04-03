import SwiftUI

struct LoginView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue, Color.blue.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {

                Text("LogIn")
                    .font(.largeTitle)
                    .foregroundColor(.white)

                TextField("Username or Email", text: $vm.usernameOrEmail)
                    .padding()
                    .background(Color.white)
                    .cornerRadius(10)

                SecureField("Password", text: $vm.password)
                    .padding()
                    .background(Color.white)
                    .cornerRadius(10)

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
            }
            .padding()
        }
    }
}
