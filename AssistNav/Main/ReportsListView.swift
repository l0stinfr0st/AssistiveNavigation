import SwiftUI

struct ReportsListView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ZStack {
            AppBackgroundView()

            ScrollView {
                LazyVStack(spacing: 12) {
                    if let banner = vm.bannerMessage {
                        Text(banner)
                            .font(.callout)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(bannerBackgroundColor(for: banner))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    if vm.hazardReports.isEmpty {
                        ContentUnavailableView(
                            "No reports yet",
                            systemImage: "mappin.slash",
                            description: Text("Community hazards will appear here after users submit them.")
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(vm.hazardReports) { report in
                            HazardReportCard(report: report)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 88)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.large)
        .task {
            vm.bannerMessage = nil
            await vm.refreshPublicHazards()
        }
        .refreshable {
            await vm.refreshPublicHazards()
        }
    }

    private func bannerBackgroundColor(for message: String) -> Color {
        let lowercased = message.lowercased()
        let isNegative =
            lowercased.contains("could not") ||
            lowercased.contains("already") ||
            lowercased.contains("needs") ||
            lowercased.contains("required") ||
            lowercased.contains("denied") ||
            lowercased.contains("error") ||
            lowercased.contains("failed")

        if !isNegative && (lowercased.contains("saved") || lowercased.contains("submitted")) {
            return .green.opacity(0.78)
        }
        return .red.opacity(0.75)
    }
}

private struct HazardReportCard: View {
    @EnvironmentObject private var vm: AppViewModel
    let report: HazardReportRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.type)
                        .font(.headline)
                    Text("\(report.dangerLevel) danger • \(report.persistenceLevel) persistence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                statusBadge
            }

            if let image = report.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if !report.details.isEmpty {
                Text(report.details)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            HStack {
                Text("Confirmations: \(report.confirmationCount)")
                Text("Resolve votes: \(report.resolveCount)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Text("Reported by \(report.reporterUsername)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(report.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !report.isResolved, vm.profile != nil {
                HStack(spacing: 10) {
                    Button("Confirm Hazard") {
                        vm.confirmHazard(report)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Resolve Hazard") {
                        vm.resolveHazard(report)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var statusBadge: some View {
        Text(report.statusLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(report.statusColor.opacity(0.18))
            .foregroundStyle(report.statusColor)
            .clipShape(Capsule())
    }
}
