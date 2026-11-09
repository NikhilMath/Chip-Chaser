import Foundation

/// Keeps the dealer list current between app updates.
///
/// Dealers open, close and change their hours more often than the app ships. About once a day
/// the app downloads the project's published `dealers.json` (the same file that's bundled) and,
/// if it's newer and still has every location this build knows, saves it for the next launch.
/// Nothing about the collector is sent: it's a plain download of a public file. A list that
/// can't be read, is older, or has lost a location is thrown away, and the bundled list always
/// remains as the fallback (`DealerDirectory.newest`).
nonisolated enum DealerListUpdate {
    static let source = URL(string: "https://raw.githubusercontent.com/NikhilMath/Chip-Chaser/main/HarleyChipTracker/Resources/dealers.json")!

    static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Dealer List/dealers.json", directoryHint: .notDirectory)
    }

    static let lastCheckKey = "dealerList.lastCheck"
    static let interval: TimeInterval = 24 * 60 * 60

    /// Downloads a newer list if a day has passed since the last look. Never throws: with no
    /// connection the app just keeps the list it has.
    static func refreshIfDue(current: DealerDirectory = .shared, defaults: UserDefaults = .standard,
                             source: URL = DealerListUpdate.source, saveTo fileURL: URL = DealerListUpdate.fileURL,
                             now: Date = .now) async {
        // Not while the tests are running.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let lastCheck = defaults.double(forKey: lastCheckKey)
        guard now.timeIntervalSince1970 - lastCheck >= interval else { return }

        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        defaults.set(now.timeIntervalSince1970, forKey: lastCheckKey)
        try? save(data, ifNewerThan: current, to: fileURL)
    }

    /// Saves a downloaded list when it can replace `current`. Returns whether it did.
    @discardableResult
    static func save(_ data: Data, ifNewerThan current: DealerDirectory, to fileURL: URL = DealerListUpdate.fileURL) throws -> Bool {
        guard data.count < 8_000_000, let update = DealerDirectory(data: data), update.canReplace(current) else { return false }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return true
    }
}
