import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ZStack {
            AppBackgroundView()

            List {
                Section("My hazard reports") {
                    if vm.myHazardReports.isEmpty {
                        Text("You have not submitted any reports yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.myHazardReports) { r in
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
                    if vm.myNavigationSessions.isEmpty {
                        Text("No saved navigation sessions yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.myNavigationSessions) { s in
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
            .scrollContentBackground(.hidden)
            .navigationTitle("History")
        }
        .task {
            await vm.refreshMyHistory()
        }
        .refreshable {
            await vm.refreshMyHistory()
        }
    }
}
