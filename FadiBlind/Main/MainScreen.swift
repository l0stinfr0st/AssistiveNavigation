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
                HistoryView()
            }
            .tabItem {
                Label("History", systemImage: "clock.fill")
            }
            .tag(MainTab.history)
        }
    }
}

private struct HomeContentView: View {
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
                Text("Assistive Navigation")
                    .foregroundStyle(.white)
                    .font(.title)
                    .accessibilityAddTraits(.isHeader)

                Button("Start Navigation") {
                    vm.startNavigation()
                }
                .buttonStyle(PrimaryNavButtonStyle())

                Button("View Hazard Map") {
                    vm.openMap()
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
                    vm.openSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .accessibilityLabel("Settings")
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
    }
}
