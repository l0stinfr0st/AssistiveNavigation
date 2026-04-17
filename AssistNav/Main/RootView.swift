import SwiftUI


struct RootView: View {
    @EnvironmentObject var vm: AppViewModel
    @AppStorage("launch_lidar_capture_test") private var launchLiDARCaptureTest = true

    var body: some View {
        if launchLiDARCaptureTest {
            LiDARCaptureTestView()
        } else if vm.profile == nil {

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
            }
        }
    }
}
