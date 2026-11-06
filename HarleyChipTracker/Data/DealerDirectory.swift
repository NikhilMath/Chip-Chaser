import Foundation

/// The bundled list of Harley-Davidson locations (`dealers.json`).
nonisolated final class DealerDirectory: Sendable {
    static let shared = DealerDirectory()

    let dealers: [Dealer]
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
            self.generated = ""
            self.source = ""
            self.byID = [:]
            return
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
            self.dealers = payload.dealers
            self.generated = payload.generated
            self.source = payload.source
            self.byID = Dictionary(payload.dealers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            assertionFailure("Could not decode \(resource).json: \(error)")
            self.dealers = []
            self.generated = ""
            self.source = ""
            self.byID = [:]
        }
    }

    init(dealers: [Dealer], generated: String = "", source: String = "") {
        self.dealers = dealers
        self.generated = generated
        self.source = source
        self.byID = Dictionary(dealers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

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
