import SwiftUI
import SwiftData

struct ReportsListView: View {
    @Query(sort: \HazardReport.createdAt, order: .reverse) private var reports: [HazardReport]

    var body: some View {
        List {
            if reports.isEmpty {
                ContentUnavailableView(
                    "No reports yet",
                    systemImage: "mappin.slash",
                    description: Text("Community hazards will appear here after users submit them.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(reports, id: \.id) { report in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.type)
                            .font(.headline)
                        if !report.details.isEmpty {
                            Text(report.details)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text("Reported by \(report.reportingUsername)")
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
        .navigationTitle("Reports")
    }
}
