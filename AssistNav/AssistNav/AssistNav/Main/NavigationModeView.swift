import SwiftUI

struct NavigationModeView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ZStack {
            AppBackgroundView(overlayOpacity: 0.55)

            VStack(spacing: 24) {
                Text("Lane guidance")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 8) {
                    Text("Status: \(vm.navigationPausedForReport ? "Paused for report" : "Active")")
                        .font(.title3)
                        .foregroundStyle(vm.navigationPausedForReport ? .orange : .green)

                    Text(vm.liveNavigationStatusLine.isEmpty ? "Starting sensors…" : vm.liveNavigationStatusLine)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal)

                    Text(
                        String(
                            format: "Distance: %.1f meters ahead (simulated preview)",
                            vm.simulatedAheadDistanceMeters
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityLabel(
                        String(format: "Distance about %.1f meters ahead", vm.simulatedAheadDistanceMeters)
                    )
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 0)

                VStack(spacing: 14) {
                    Button("Stop Navigation") {
                        vm.stopNavigation()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    Button("Report Hazard") {
                        vm.openReportFromNavigation()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange.opacity(0.95))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}
