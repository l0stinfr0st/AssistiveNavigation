import SwiftUI
import MapKit

struct MapView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var selectedHazard: HazardReportRow?

    var body: some View {
        ZStack {
            AppBackgroundView(overlayOpacity: 0.3)

            NavigationStack {
                Map {
                    ForEach(vm.hazardReports.filter(\.isAccepted)) { h in
                        Annotation(h.type, coordinate: CLLocationCoordinate2D(latitude: h.latitude, longitude: h.longitude)) {
                            Button {
                                selectedHazard = h
                            } label: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .padding(6)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(h.type) reported here")
                        }
                    }
                    UserAnnotation()
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .navigationTitle("Hazard map")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") {
                            vm.closeMap()
                        }
                    }
                }
            }
        }
        .task {
            await vm.refreshPublicHazards()
        }
        .sheet(item: $selectedHazard) { hazard in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let image = hazard.previewImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                        Text(hazard.type)
                            .font(.title2.weight(.semibold))

                        Text("\(hazard.dangerLevel) danger • \(hazard.persistenceLevel) persistence")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(hazard.details.isEmpty ? "No description provided." : hazard.details)
                            .font(.body)

                        Text("Reported by \(hazard.reporterUsername)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
                .navigationTitle("Hazard")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
