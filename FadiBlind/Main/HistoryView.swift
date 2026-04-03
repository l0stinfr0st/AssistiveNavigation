import SwiftUI
import SwiftData

struct HistoryView: View {
    @EnvironmentObject var vm: AppViewModel
    @Query(sort: \HazardReport.createdAt, order: .reverse) private var allReports: [HazardReport]
    @Query(sort: \NavigationSession.startedAt, order: .reverse) private var allSessions: [NavigationSession]

    var body: some View {
        List {
            Section("My hazard reports") {
                let mine = allReports.filter { $0.reportingUserID == vm.activeUser?.id }
                if mine.isEmpty {
                    Text("You have not submitted any reports yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mine, id: \.id) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.type).font(.headline)
                            if !r.details.isEmpty {
                                Text(r.details).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(r.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section("Navigation activity") {
                let nav = allSessions.filter { $0.userID == vm.activeUser?.id }
                if nav.isEmpty {
                    Text("No saved navigation sessions yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(nav, id: \.id) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Session — \(s.status)")
                                .font(.headline)
                            Text("Started \(s.startedAt, format: .dateTime.month().day().hour().minute())")
                                .font(.caption)
                            if let end = s.endedAt {
                                Text("Ended \(end, format: .dateTime.hour().minute())")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Hazard reports during session: \(s.reportCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("History")
    }
}
