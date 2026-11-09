import CoreLocation
import Foundation

/// The kind of Harley-Davidson location. Every kind sells its own chip.
nonisolated enum DealerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A full dealership (bikes, service, parts, MotorClothes).
    case dealer
    /// A secondary store owned by a dealership, usually with bikes on the floor.
    case satellite
    /// A boutique apparel & gift shop (tourist towns, airports, cruise ports).
    case shop
    /// A location the collector added by hand.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dealer: "Dealership"
        case .satellite: "Satellite Store"
        case .shop: "Apparel & Gift Shop"
        case .custom: "Added by You"
        }
    }

    var symbol: String {
        switch self {
        case .dealer: "storefront"
        case .satellite: "building.2"
        case .shop: "bag"
        case .custom: "person.crop.circle.badge.plus"
        }
    }
}

/// A single Harley-Davidson location, which means one chip to collect.
nonisolated struct Dealer: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var kind: DealerKind
    var address: String?
    var city: String
    /// State or province code, e.g. "WI" or "ON".
    var region: String
    var postalCode: String?
    /// ISO country code, "US" or "CA" for bundled dealers.
    var country: String
    var latitude: Double?
    var longitude: Double?
    var phone: String?
    var website: String?
    /// For satellite stores and shops: the dealership that runs them.
    var parentId: String?
    /// When the location dropped out of Harley-Davidson's locator ("2027-03-01"), if it has.
    /// Closed locations stay in the bundled list forever so chips collected there never vanish.
    var closed: String?
    /// Regular weekly hours from the dealer locator, in the store's own time zone. Optional, so
    /// lists and backups from before hours were added still decode.
    var hours: OpeningHours?
    /// The store's IANA time zone ("America/Chicago"), worked out from its coordinates when
    /// `dealers.json` is built. Hours are read in this zone, never the phone's.
    var timeZone: String?

    var isClosed: Bool { closed != nil }

    /// Hours worth showing: listed with some opening time, for a location that's still open.
    var openingHours: OpeningHours? {
        guard !isClosed, let hours, hours.hasOpenTime else { return nil }
        return hours
    }

    var storeTimeZone: TimeZone? { timeZone.flatMap(TimeZone.init(identifier:)) }

    /// Open or closed at `date`, by the store's own clock. Nil without hours or a time zone.
    func openStatus(at date: Date = .now) -> OpeningHours.Status? {
        guard let hours = openingHours, let zone = storeTimeZone else { return nil }
        return hours.status(at: date, in: zone)
    }

    var regionKey: RegionKey { RegionKey(country: country, code: region) }

    var regionName: String { Regions.name(for: region, country: country) }

    var cityLine: String {
        region.isEmpty ? city : "\(city), \(region)"
    }

    var fullAddress: String {
        var lines: [String] = []
        if let address, !address.isEmpty { lines.append(address) }
        var cityPart = cityLine
        if let postalCode, !postalCode.isEmpty {
            cityPart += " " + Dealer.displayPostalCode(postalCode)
        }
        lines.append(cityPart)
        return lines.joined(separator: "\n")
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation? {
        guard let latitude, let longitude else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    var websiteURL: URL? {
        guard let website, !website.isEmpty else { return nil }
        return URL(string: website)
    }

    var phoneURL: URL? {
        guard let phone else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:\(digits)")
    }

    /// Apple Maps link that drops a pin on the dealer (and offers directions).
    var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        var items = [URLQueryItem(name: "q", value: name)]
        if let latitude, let longitude {
            items.append(URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"))
        } else {
            items.append(URLQueryItem(name: "address", value: fullAddress.replacingOccurrences(of: "\n", with: ", ")))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Words a search can match: name, city, state code and name, ZIP. Every word typed has to
    /// match something, so "milwaukee wi" or "bartels marina" narrow the list instead of emptying it.
    func matches(search text: String) -> Bool {
        let words = text.split { $0.isWhitespace || $0 == "," }
        return words.allSatisfy { word in
            name.localizedStandardContains(word)
                || city.localizedStandardContains(word)
                || region.caseInsensitiveCompare(word) == .orderedSame
                || regionName.localizedStandardContains(word)
                || (postalCode?.hasPrefix(word) ?? false)
        }
    }

    /// "53202-1234" stays as is, but the feed's "99840-0000" placeholder drops its "-0000".
    static func displayPostalCode(_ code: String) -> String {
        code.hasSuffix("-0000") ? String(code.dropLast(5)) : code
    }
}

/// Identifies a state or province within a country.
nonisolated struct RegionKey: Hashable, Codable, Sendable, Identifiable {
    var country: String
    var code: String
    var id: String { "\(country)-\(code)" }
    var name: String { Regions.name(for: code, country: country) }
}
