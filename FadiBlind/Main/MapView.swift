import SwiftUI
import MapKit
import SwiftData

struct MapView: View {
    @EnvironmentObject var vm: AppViewModel
    @Query(sort: \HazardReport.createdAt, order: .reverse) private var hazards: [HazardReport]

    var body: some View {
        NavigationStack {
            Map {
                ForEach(hazards, id: \.id) { h in
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
}
