@preconcurrency import CoreLocation
import MapKit
import SwiftUI

/// Pick a point on the map and send it as a `.location` message.
/// Opens centred on the user's current location when authorisation is
/// granted; otherwise drops the user on a sane default and lets them
/// pan. The pin always tracks the map's centre — tap "Send" to commit
/// whatever coordinates are under the crosshair.
///
/// Privacy: we don't ship the user's location automatically. Only
/// triggered when they explicitly hit Send. No background tracking,
/// no live updates — that's a separate sheet (planned).
struct LocationPickerSheet: View {
    let onSend: (CLLocationCoordinate2D) -> Void
    let onCancel: () -> Void

    @StateObject private var auth = LocationAuthorisation.shared
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 41.0082, longitude: 28.9784),  // Istanbul, neutral fallback
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05),
    )
    @State private var didCentre = false
    /// `CLLocationCoordinate2D` isn't Equatable, so `.onChange` can't
    /// watch the published coord directly — bump this monotonically
    /// each time `LocationAuthorisation` emits a fix and watch that.
    @State private var locationVersion: Int = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Map(coordinateRegion: $region, showsUserLocation: true)
                    .ignoresSafeArea(edges: .bottom)
                // Fixed crosshair anchored to the map centre; the
                // region moves under it as the user pans.
                VStack(spacing: -2) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(Theme.Color.accent)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    // Tiny spacer so the pin tail lands on the actual coordinate.
                    Rectangle().fill(Color.clear).frame(width: 1, height: 14)
                }
                .allowsHitTesting(false)
            }
            .navigationTitle("chat.location.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("chat.location.send".localized) {
                        onSend(region.center)
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                auth.requestWhenInUseIfNeeded()
                locationVersion = auth.fixCount
            }
            .onChange(of: auth.fixCount) { _ in
                guard let new = auth.currentLocation, !didCentre else { return }
                didCentre = true
                withAnimation(.easeInOut(duration: 0.25)) {
                    region = MKCoordinateRegion(
                        center: new,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01),
                    )
                }
            }
        }
    }
}

/// Thin CLLocationManager wrapper. Asks for when-in-use permission on
/// first use, surfaces the most recent fix via `@Published`. No
/// background updates, no significant-location monitoring — the
/// picker sheet only needs a one-shot fix to centre itself.
@MainActor
final class LocationAuthorisation: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationAuthorisation()

    @Published var currentLocation: CLLocationCoordinate2D?
    /// Monotonic counter — bumped on every accepted fix. Use this as
    /// `.onChange` value since CLLocationCoordinate2D isn't Equatable.
    @Published var fixCount: Int = 0

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestWhenInUseIfNeeded() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        Task { @MainActor in self.manager.requestLocation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.currentLocation = coord
            self.fixCount &+= 1
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Soft-fail — the picker still works with the fallback region;
        // the user just has to pan to where they want to drop the pin.
    }
}
