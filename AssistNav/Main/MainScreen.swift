import SwiftUI

struct MainView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        TabView(selection: $vm.mainTab) {
            NavigationStack {
                HomeContentView()
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(MainTab.home)

            NavigationStack {
                ReportsListView()
            }
            .tabItem {
                Label("Reports", systemImage: "exclamationmark.triangle.fill")
            }
            .tag(MainTab.reports)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(MainTab.settings)
        }
    }
}

private struct HomeContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @AppStorage("launch_lidar_capture_test") private var launchLiDARCaptureTest = false

    var body: some View {
        ZStack {
            AppBackgroundView()

            VStack(spacing: 20) {
                Text("Assistive Navigation")
                    .foregroundStyle(.white)
                    .font(.title)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .accessibilityAddTraits(.isHeader)

                Button("Start Navigation") {
                    vm.startNavigation()
                }
                .buttonStyle(PrimaryNavButtonStyle())

                Button("View Hazard Map") {
                    vm.openMap()
                }
                .buttonStyle(PrimaryNavButtonStyle())

                Button("LiDAR Depth Test") {
                    launchLiDARCaptureTest = true
                }
                .buttonStyle(PrimaryNavButtonStyle())

                Button("Report Hazard") {
                    vm.openReportFromHome()
                }
                .buttonStyle(PrimaryNavButtonStyle())
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    vm.selectSettingsTab()
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .accessibilityLabel("Open Settings tab")
            }
        }
    }
}

private struct PrimaryNavButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.white.opacity(configuration.isPressed ? 0.75 : 0.95))
            .foregroundStyle(Color.blue)
            .font(.headline)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
    }
}
