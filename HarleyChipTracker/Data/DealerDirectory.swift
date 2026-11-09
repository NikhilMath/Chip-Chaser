import Foundation

/// The bundled list of Harley-Davidson locations (`dealers.json`).
///
/// Collectors' chips are keyed by these IDs, so the list only ever grows: a location that
/// leaves the locator stays in the file marked `closed` (see `Tools/update_dealers.py`).
nonisolated final class DealerDirectory: Sendable {
    /// The list the app uses: the bundled one, or a newer one downloaded since (`DealerListUpdate`).
    static let shared = DealerDirectory.newest()

    /// Locations that are open now: the chips still out there to collect.
    let dealers: [Dealer]
    /// Locations that have closed. They only show up for collectors who have their chip.
    let closedDealers: [Dealer]
    /// ISO date the bundled list was pulled from the dealer locator.
    let generated: String
    let source: String
    private let byID: [String: Dealer]

    private struct Payload: Decodable {
        let source: String
        let generated: String
        let dealers: [Dealer]
    }

    init(bundle: Bundle = .main, resource: String = "dealers") {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            assertionFailure("\(resource).json is missing from the app bundle")
            self.dealers = []
            self.closedDealers = []
            self.generated = ""
            self.source = ""
            self.byID = [:]
            return
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
            self.dealers = payload.dealers.filter { !$0.isClosed }
            self.closedDealers = payload.dealers.filter(\.isClosed)
            self.generated = payload.generated
            self.source = payload.source
            self.byID = Dictionary(payload.dealers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            assertionFailure("Could not decode \(resource).json: \(error)")
            self.dealers = []
            self.closedDealers = []
            self.generated = ""
            self.source = ""
            self.byID = [:]
        }
    }

    init(dealers: [Dealer], generated: String = "", source: String = "") {
        self.dealers = dealers.filter { !$0.isClosed }
        self.closedDealers = dealers.filter(\.isClosed)
        self.generated = generated
        self.source = source
        self.byID = Dictionary(dealers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Reads a `dealers.json` file's contents. Nil when it isn't one.
    convenience init?(data: Data) {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        self.init(dealers: payload.dealers, generated: payload.generated, source: payload.source)
    }

    /// The bundled list, unless the downloaded one at `url` is newer and safe to use instead.
    static func newest(bundled: DealerDirectory = DealerDirectory(), downloaded url: URL = DealerListUpdate.fileURL) -> DealerDirectory {
        guard let data = try? Data(contentsOf: url), let update = DealerDirectory(data: data),
              update.canReplace(bundled) else { return bundled }
        return update
    }

    /// Whether this list can stand in for `other`: it's newer, and it still has every location
    /// `other` has. Chips are keyed by these IDs, so a list that lost one is never used.
    func canReplace(_ other: DealerDirectory) -> Bool {
        let isDate = generated.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
        return isDate && generated > other.generated && !dealers.isEmpty
            && other.byID.keys.allSatisfy { byID[$0] != nil }
    }

    /// Any bundled location, open or closed.
    func dealer(id: String) -> Dealer? { byID[id] }

    /// "Nov 6, 2026" for the About screen.
    var generatedDisplay: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: generated) else { return generated }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
