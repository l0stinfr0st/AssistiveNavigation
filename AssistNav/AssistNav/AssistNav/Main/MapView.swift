import SwiftUI
import MapKit

struct MapView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ZStack {
            AppBackgroundView(overlayOpacity: 0.3)

            NavigationStack {
                Map {
                    ForEach(vm.hazardReports) { h in
                        Annotation(h.type, coordinate: CLLocationCoordinate2D(latitude: h.latitude, longitude: h.longitude)) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .padding(6)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
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
    }
}
