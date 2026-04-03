import SwiftUI

struct RootView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {

        if vm.activeUser == nil {
            if vm.authMode == .login {
                LoginView()
            } else {
                RegisterView()
            }
        } else {
            switch vm.currentScreen {
            case .main:
                MainView()
            case .navigation:
                NavigationModeView()
            case .report:
                ReportView()
            case .map:
                MapView()
            case .settings:
                SettingsView()
            }
        }
    }
}
