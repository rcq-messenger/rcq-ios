import CoreLocation
import MapKit
import SwiftUI

/// Render a `.location` message — small static map snapshot with a
/// pin overlay + tap to open in Apple Maps or Google Maps (whichever
/// the recipient prefers). Snapshot is rendered once via
/// `MKMapSnapshotter` and cached in-memory so scrolling past doesn't
/// redraw.
struct LocationBubble: View {
    let message: Message
    var maxWidth: CGFloat = 240
    var height: CGFloat = 140

    @State private var snapshot: UIImage?
    @State private var showingOpenSheet = false

    private var coord: CLLocationCoordinate2D? {
        guard let lat = message.latitude, let lng = message.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// Show the Google Maps row only when the user actually has the
    /// app installed — otherwise tapping it would open Safari + the
    /// universal-link fallback, which is less obvious. `canOpenURL`
    /// requires `comgooglemaps` in `LSApplicationQueriesSchemes`.
    private var hasGoogleMaps: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    var body: some View {
        Button { showingOpenSheet = true } label: {
            ZStack(alignment: .center) {
                if let snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Theme.Color.bgSecondary)
                    ProgressView()
                        .tint(Theme.Color.accent)
                }
                if snapshot != nil {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(Theme.Color.accent)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                }
            }
            .frame(width: maxWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(coord == nil)
        .task(id: message.id) { await loadSnapshot() }
        .confirmationDialog(
            "chat.location.open_in".localized,
            isPresented: $showingOpenSheet,
            titleVisibility: .visible,
        ) {
            Button("chat.location.open.apple".localized) { openInAppleMaps() }
            if hasGoogleMaps {
                Button("chat.location.open.google".localized) { openInGoogleMaps() }
            }
            Button("chat.location.copy".localized) { copyCoords() }
            Button("common.cancel".localized, role: .cancel) {}
        }
    }

    private func openInAppleMaps() {
        guard let coord else { return }
        let placemark = MKPlacemark(coordinate: coord)
        let item = MKMapItem(placemark: placemark)
        item.name = "Location"
        item.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coord),
        ])
    }

    private func openInGoogleMaps() {
        guard let coord else { return }
        let lat = coord.latitude
        let lng = coord.longitude
        // App-scheme first, https fallback if the app is uninstalled
        // (happens if the user offloaded it between checks).
        let app = URL(string: "comgooglemaps://?q=\(lat),\(lng)&center=\(lat),\(lng)")!
        let web = URL(string: "https://maps.google.com/?q=\(lat),\(lng)")!
        let target = UIApplication.shared.canOpenURL(app) ? app : web
        UIApplication.shared.open(target)
    }

    private func copyCoords() {
        guard let coord else { return }
        UIPasteboard.general.string = String(format: "%.6f, %.6f", coord.latitude, coord.longitude)
    }

    private func loadSnapshot() async {
        guard snapshot == nil, let coord else { return }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008),
        )
        options.size = CGSize(width: maxWidth, height: height)
        options.scale = UIScreen.main.scale
        // System map renderer — same Apple Maps tile set the picker uses.
        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let result = try await snapshotter.start()
            await MainActor.run { snapshot = result.image }
        } catch {
            // Soft-fail — bubble shows the placeholder + spinner. Tap still works.
        }
    }
}
