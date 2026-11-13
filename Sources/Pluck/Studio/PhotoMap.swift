import MapKit
import SwiftUI

/// Photos close together on the map, shown as one pin.
struct PhotoCluster: Identifiable, Hashable {
    var paths: [String]
    var latitude: Double
    var longitude: Double
    var id: String { paths[0] }
    var centre: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// The photos grouped by a grid over the part of the map shown (about 8 across): one pin per
    /// square that has any, where its photos are on average. Without a region, the whole world.
    static func make(_ places: [(path: String, place: CLLocationCoordinate2D)], region: MKCoordinateRegion?, across: Double = 8) -> [PhotoCluster] {
        let latStep = max((region?.span.latitudeDelta ?? 180) / (across * 0.75), 1e-6)
        let lonStep = max((region?.span.longitudeDelta ?? 360) / across, 1e-6)
        var cells: [[Int]: [(String, CLLocationCoordinate2D)]] = [:]
        // Zoomed in, only what's on screen and around it (thousands of pins off screen would slow the map).
        let near = places.filter { _, place in
            guard let region else { return true }
            return abs(place.latitude - region.center.latitude) <= region.span.latitudeDelta * 1.5
                && abs(remainder(place.longitude - region.center.longitude, 360)) <= region.span.longitudeDelta * 1.5
        }
        for (path, place) in near {
            cells[[Int((place.latitude / latStep).rounded(.down)), Int((place.longitude / lonStep).rounded(.down))], default: []].append((path, place))
        }
        return cells.values.map { members in
            let n = Double(members.count)
            return PhotoCluster(paths: members.map(\.0).sorted(), latitude: members.map(\.1.latitude).reduce(0, +) / n,
                                longitude: members.map(\.1.longitude).reduce(0, +) / n)
        }
        .sorted { $0.id < $1.id }
    }
}

/// The Map source: every photo with a place, as pins (with a photo, and how many) that group as
/// you zoom out. A pin chooses its photos for the grid under the map.
struct PhotoMapView: View {
    let places: [(path: String, place: CLLocationCoordinate2D)]
    @Binding var picked: Set<String>?
    @State private var position = MapCameraPosition.automatic
    @State private var region: MKCoordinateRegion?

    var body: some View {
        let clusters = PhotoCluster.make(places, region: region)
        Map(position: $position) {
            ForEach(clusters) { cluster in
                Annotation(PhotoCatalog.displayName(cluster.id), coordinate: cluster.centre, anchor: .bottom) {
                    MapPhotoPin(path: cluster.id, count: cluster.paths.count, chosen: picked == Set(cluster.paths))
                        .onTapGesture { picked = picked == Set(cluster.paths) ? nil : Set(cluster.paths) }
                        .accessibilityAddTraits(.isButton)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapControls { MapZoomStepper(); MapCompass() }
        .onMapCameraChange(frequency: .onEnd) { region = $0.region }
        .overlay {
            if places.isEmpty {
                Text("No photos with a place yet").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: .capsule)
            }
        }
        .overlay(alignment: .topLeading) {
            if picked != nil {
                Button("Show All", systemImage: "xmark.circle.fill") { picked = nil }
                    .buttonStyle(StudioFlatButtonStyle())
                    .controlSize(.small)
                    .padding(10)
            }
        }
    }
}

/// A pin: one of its photos, small, with how many there are.
private struct MapPhotoPin: View {
    let path: String
    let count: Int
    let chosen: Bool
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.4)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.small).strokeBorder(chosen ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(.white), lineWidth: chosen ? 3 : 2))
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text(verbatim: "\(count)")
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Design.Brand.violet))
                    .offset(x: 6, y: -6)
            }
        }
        .shadow(radius: 2)
        .help(Text("^[\(count) photo](inflect: true)"))
        .accessibilityLabel(Text("^[\(count) photo](inflect: true)"))
        .task(id: path) {
            let path = path
            image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: PhotoCatalog.file(of: path)) as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 120,
                                                kCGImageSourceCreateThumbnailWithTransform: true]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
        }
    }
}
