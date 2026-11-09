import CoreLocation
import Foundation
import MapKit

/// One mark on the map: a single location, or several that would overlap at this zoom.
///
/// Around big cities a dozen stores sit within a thumb's width of each other when the map is
/// zoomed out. Grouping them keeps every pin tappable and the rider's own dot visible, and
/// only locations on screen are drawn at all.
nonisolated struct MapCluster: Identifiable, Sendable {
    let dealers: [Dealer]
    let coordinate: CLLocationCoordinate2D
    /// How many of `dealers` the collector has.
    let collected: Int

    var id: String {
        dealers.count == 1 ? dealers[0].id : "cluster-\(dealers[0].id)-\(dealers.count)"
    }

    /// The location, when this mark is just one.
    var single: Dealer? { dealers.count == 1 ? dealers[0] : nil }

    /// A region that shows every location in the cluster, with room around them.
    var region: MKCoordinateRegion {
        let latitudes = dealers.compactMap(\.latitude), longitudes = dealers.compactMap(\.longitude)
        guard let south = latitudes.min(), let north = latitudes.max(),
              let west = longitudes.min(), let east = longitudes.max() else {
            return MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((north - south) * 1.6, 0.02),
                                   longitudeDelta: max((east - west) * 1.6, 0.02))
        )
    }

    /// Below this span (a few miles across) every location gets its own pin, however close.
    static let alwaysSeparateSpan = 0.06

    /// Groups the locations inside `region` (plus a margin) that would land within about one
    /// pin's width of each other on a map `mapSize` points across.
    ///
    /// `keepSeparate` (the selected location) always gets its own pin.
    static func make(_ dealers: [Dealer], status: CollectionStatus, in region: MKCoordinateRegion,
                     mapSize: CGSize, pinSpacing: Double = 34, keepSeparate: String? = nil) -> [MapCluster] {
        let latitudeDelta = max(region.span.latitudeDelta, 0.0001)
        let longitudeDelta = max(region.span.longitudeDelta, 0.0001)
        let south = region.center.latitude - latitudeDelta * 0.65, north = region.center.latitude + latitudeDelta * 0.65
        let west = region.center.longitude - longitudeDelta * 0.65, east = region.center.longitude + longitudeDelta * 0.65
        let grouping = longitudeDelta > alwaysSeparateSpan
        let latitudeCell = latitudeDelta * pinSpacing / max(Double(mapSize.height), 200)
        let longitudeCell = longitudeDelta * pinSpacing / max(Double(mapSize.width), 200)

        // Greedy grouping: each location joins the first group whose seed is within a pin's
        // width, so neighbours never end up as two marks on top of each other. Sorted by ID so
        // the same view always groups the same way.
        struct Group { var x: Double, y: Double, members: [Dealer] }
        var groups: [Group] = []
        var marks: [MapCluster] = []

        for dealer in dealers.sorted(by: { $0.id < $1.id }) {
            guard let latitude = dealer.latitude, let longitude = dealer.longitude,
                  latitude >= south, latitude <= north, longitude >= west, longitude <= east else { continue }
            if !grouping || dealer.id == keepSeparate {
                marks.append(MapCluster(dealers: [dealer], coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                        collected: status.isCollected(dealer.id) ? 1 : 0))
                continue
            }
            let x = longitude / longitudeCell, y = latitude / latitudeCell
            if let index = groups.firstIndex(where: { ($0.x - x) * ($0.x - x) + ($0.y - y) * ($0.y - y) < 1 }) {
                groups[index].members.append(dealer)
            } else {
                groups.append(Group(x: x, y: y, members: [dealer]))
            }
        }

        // A group sits at the middle of its members, which can drift next to another group:
        // fold those together until every mark has room.
        func recenter(_ group: inout Group) {
            let count = Double(group.members.count)
            group.x = group.members.reduce(0) { $0 + ($1.longitude ?? 0) } / count / longitudeCell
            group.y = group.members.reduce(0) { $0 + ($1.latitude ?? 0) } / count / latitudeCell
        }
        for index in groups.indices { recenter(&groups[index]) }
        var merged = true
        while merged {
            merged = false
            search: for first in groups.indices {
                for second in groups.indices where second > first {
                    let dx = groups[first].x - groups[second].x, dy = groups[first].y - groups[second].y
                    guard dx * dx + dy * dy < 1 else { continue }
                    groups[first].members += groups[second].members
                    recenter(&groups[first])
                    groups.remove(at: second)
                    merged = true
                    break search
                }
            }
        }

        for group in groups {
            let members = group.members.sorted { $0.id < $1.id }
            let count = Double(members.count)
            let latitude = members.reduce(0) { $0 + ($1.latitude ?? 0) } / count
            let longitude = members.reduce(0) { $0 + ($1.longitude ?? 0) } / count
            marks.append(MapCluster(dealers: members, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                    collected: status.collectedCount(in: members)))
        }
        return marks
    }
}
