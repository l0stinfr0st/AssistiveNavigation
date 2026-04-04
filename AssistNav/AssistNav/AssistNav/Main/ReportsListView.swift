import SwiftUI

struct ReportsListView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ZStack {
            AppBackgroundView()

            List {
                if vm.hazardReports.isEmpty {
                    ContentUnavailableView(
                        "No reports yet",
                        systemImage: "mappin.slash",
                        description: Text("Community hazards will appear here after users submit them.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(vm.hazardReports) { report in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(report.type)
                                .font(.headline)
                            if !report.details.isEmpty {
                                Text(report.details)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Reported by \(report.reporterUsername)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(report.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Reports")
        }
        .task {
            await vm.refreshPublicHazards()
        }
        .refreshable {
            await vm.refreshPublicHazards()
        }
    }
}
