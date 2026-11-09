import CoreGraphics
import CoreLocation
import Foundation

/// Works out which dealers' chips are in a photo, from the text read off it.
///
/// Dealer chips print the store's name and town around the rim ("Bumpus Harley-Davidson ·
/// Memphis, TN"), so every location is scored by how much of its name and city turns up in
/// the text. Distinctive words count for more than common ones ("Bumpus" beats "Valley"),
/// and a misread letter or a word cut off by the curve of the chip still counts for part
/// of a match. Words every chip shares ("Harley-Davidson", "of") count for nothing.
///
/// Several chips in one photo are found one at a time: the best match claims the text that
/// identified it, and the leftover text is matched again.
nonisolated struct ChipMatcher: Sendable {
    /// One piece of text read off the photo.
    struct Snippet: Sendable, Hashable {
        var text: String
        /// Where the text sits in the photo: normalized to 0...1, origin top-left.
        var box: CGRect

        init(_ text: String, box: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
            self.text = text
            self.box = box
        }
    }

    /// A location the text points to.
    struct Candidate: Sendable, Identifiable {
        let dealer: Dealer
        /// Weighted evidence: about 6 for one rare word read cleanly, 2 for a common one.
        let score: Double
        /// How much of the dealer's name (or town, for names that are only "Harley-Davidson")
        /// was found, from 0 to 1.
        let coverage: Double

        var id: String { dealer.id }

        /// Confident enough to add without the collector picking it from a list.
        var isStrong: Bool { coverage >= 0.66 && score >= ChipMatcher.strongScore }
    }

    /// One chip found in the photo.
    struct Chip: Sendable {
        let best: Candidate
        /// Other locations the same text fits (same name in another town, a similar name).
        let alternatives: [Candidate]
        /// Where the text that identified it sits: normalized, origin top-left.
        let region: CGRect
    }

    struct Findings: Sendable {
        /// Chips identified with confidence, best first.
        var chips: [Chip]
        /// Weaker matches, offered when no chip was identified.
        var suggestions: [Candidate]
    }

    static let strongScore = 3.5
    static let possibleScore = 1.8

    /// Words on nearly every chip, or too generic to tell stores apart.
    static let stopWords: Set<String> = [
        "harley", "davidson", "hd", "of", "the", "and", "at", "in", "on", "by", "shop", "store",
        "apparel", "gift", "gifts", "motorcycle", "motorcycles", "motor", "co", "company",
        "inc", "llc", "ltd", "dealer", "dealership",
    ]

    private struct Entry: Sendable {
        let dealer: Dealer
        /// Distinctive words of the store's name.
        let name: [String]
        /// Words of the town that aren't already in the name.
        let city: [String]
        let regionCode: String
        let regionName: [String]
    }

    private let entries: [Entry]
    private let weights: [String: Double]

    init(dealers: [Dealer]) {
        var seen = Set<String>()
        var entries: [Entry] = []
        for dealer in dealers where seen.insert(dealer.id).inserted {
            let name = Self.distinctive(Self.words(in: dealer.name))
            let city = Self.distinctive(Self.words(in: dealer.city)).filter { !name.contains($0) }
            entries.append(Entry(
                dealer: dealer,
                name: name,
                city: city,
                regionCode: dealer.region.lowercased(),
                regionName: Self.distinctive(Self.words(in: dealer.regionName))
            ))
        }
        self.entries = entries

        // Rarer words are stronger evidence: inverse document frequency over name and town.
        var counts: [String: Int] = [:]
        for entry in entries {
            for word in Set(entry.name + entry.city) { counts[word, default: 0] += 1 }
        }
        let total = Double(max(entries.count, 1))
        self.weights = counts.mapValues { log(1 + total / Double($0)) }
    }

    // MARK: - Matching

    /// Every chip the text identifies, plus weaker suggestions when it identifies none.
    ///
    /// `location` (where the photo was taken) breaks ties toward stores nearby, since a new
    /// chip is usually photographed at the counter. It never counts without some text.
    func findChips(in snippets: [Snippet], near location: CLLocation? = nil, limit: Int = 12) -> Findings {
        let readings = Self.readings(from: snippets)
        guard !readings.isEmpty else { return Findings(chips: [], suggestions: []) }
        let strengths = tokenStrengths(in: readings)

        var active = [Bool](repeating: true, count: readings.count)
        var chosen = Set<String>()
        var chips: [Chip] = []

        for _ in 0..<(limit * 3) where chips.count < limit {
            let ranked = rank(strengths: strengths, active: active, near: location, excluding: chosen)
            // The best confident match, even if a nearby store with half its name read scores higher.
            guard let top = ranked.first(where: \.isStrong) else { break }
            chosen.insert(top.id)

            let entry = entries.first { $0.dealer.id == top.id }
            let evidence = entry.map { onOneChip(evidenceReadings(for: $0, strengths: strengths, active: active),
                                                 for: $0, readings: readings, strengths: strengths) } ?? []
            let region = Self.region(of: evidence.map { readings[$0].box })
            for index in evidence { active[index] = false }

            // Text left over on a chip already counted (part of its name misread, or its state
            // matching a store named after the state) isn't another chip.
            let middle = CGPoint(x: region.midX, y: region.midY)
            let onCountedChip = !evidence.isEmpty && chips.contains { chip in
                chip.region.contains(middle) && chip.region.width * chip.region.height >= region.width * region.height * 0.5
            }
            if onCountedChip { continue }

            let alternatives = ranked
                .filter { $0.id != top.id && $0.score >= max(Self.possibleScore, top.score * 0.6) }
                .prefix(8)
            chips.append(Chip(best: top, alternatives: Array(alternatives), region: region))
            guard !evidence.isEmpty else { break }
        }

        var suggestions: [Candidate] = []
        if chips.isEmpty {
            let everything = [Bool](repeating: true, count: readings.count)
            suggestions = Array(rank(strengths: strengths, active: everything, near: location, excluding: [])
                .filter { $0.score >= Self.possibleScore }
                .prefix(8))
        }
        return Findings(chips: chips, suggestions: suggestions)
    }

    /// Where a chip's text sits. Lines of text pin it down better than a reading of a whole
    /// ring, which can be the guessed ring across the middle of the photo.
    private static func region(of boxes: [CGRect]) -> CGRect {
        let lines = boxes.filter { $0.width * $0.height <= 0.3 }
        let union = (lines.isEmpty ? boxes : lines).reduce(CGRect.null) { $0.union($1) }
        return union.isNull ? .zero : union
    }

    /// Locations within `radius` meters of `location`, nearest first.
    func dealers(near location: CLLocation, within radius: CLLocationDistance) -> [Dealer] {
        entries
            .compactMap { entry -> (Dealer, CLLocationDistance)? in
                guard let spot = entry.dealer.location else { return nil }
                let distance = location.distance(from: spot)
                return distance <= radius ? (entry.dealer, distance) : nil
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func rank(strengths: [String: [Double]], active: [Bool], near location: CLLocation?, excluding chosen: Set<String>) -> [Candidate] {
        func found(_ word: String) -> Double {
            guard let values = strengths[word] else { return 0 }
            var best = 0.0
            for index in values.indices where active[index] && values[index] > best { best = values[index] }
            return best
        }

        var candidates: [Candidate] = []
        for entry in entries where !chosen.contains(entry.dealer.id) {
            var nameHit = 0.0, nameTotal = 0.0
            for word in entry.name {
                let weight = weights[word] ?? 1
                nameTotal += weight
                nameHit += weight * found(word)
            }
            var cityHit = 0.0, cityTotal = 0.0
            for word in entry.city {
                let weight = weights[word] ?? 1
                cityTotal += weight
                cityHit += weight * found(word)
            }
            guard nameHit > 0 || cityHit > 0 else { continue }

            var score = nameHit + 0.7 * cityHit
            if hasRegion(entry, strengths: strengths, active: active) { score += 0.6 }
            if let location, let spot = entry.dealer.location {
                let distance = location.distance(from: spot)
                if distance < 2_000 { score += 2 } else if distance < 25_000 { score += 0.75 }
            }

            let coverage: Double
            if nameTotal > 0 {
                coverage = nameHit / nameTotal
            } else {
                coverage = cityTotal > 0 ? cityHit / cityTotal : 0
            }
            candidates.append(Candidate(dealer: entry.dealer, score: score, coverage: coverage))
        }

        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.coverage != rhs.coverage { return lhs.coverage > rhs.coverage }
            if lhs.dealer.isClosed != rhs.dealer.isClosed { return !lhs.dealer.isClosed }
            return Dealer.byName(lhs.dealer, rhs.dealer)
        }
    }

    /// The state's code ("WI") as its own word, or its full name.
    private func hasRegion(_ entry: Entry, strengths: [String: [Double]], active: [Bool]) -> Bool {
        if let values = strengths["#" + entry.regionCode],
           values.indices.contains(where: { active[$0] && values[$0] > 0 }) {
            return true
        }
        guard !entry.regionName.isEmpty else { return false }
        return entry.regionName.allSatisfy { word in
            guard let values = strengths[word] else { return false }
            return values.indices.contains { active[$0] && values[$0] >= 0.8 }
        }
    }

    /// The readings that identify `entry`: they get used up once its chip is counted.
    private func evidenceReadings(for entry: Entry, strengths: [String: [Double]], active: [Bool]) -> [Int] {
        // Only the name and town claim text: two chips from one state both need the state's name.
        var indices = Set<Int>()
        for word in entry.name + entry.city {
            guard let values = strengths[word] else { continue }
            for index in values.indices where active[index] && values[index] >= 0.5 { indices.insert(index) }
        }
        return indices.sorted()
    }

    /// The part of `evidence` on one chip: the one that spells out the most of `entry`.
    ///
    /// Several chips from one state all carry the state's name, which can be a store's name
    /// too ("Wisconsin Harley-Davidson"). Readings sit on the same chip when one's middle falls
    /// inside another's box, as every line on a chip does inside its unrolled rim.
    private func onOneChip(_ evidence: [Int], for entry: Entry, readings: [Reading], strengths: [String: [Double]]) -> [Int] {
        guard evidence.count > 1 else { return evidence }
        var parent = Array(evidence.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        for first in evidence.indices {
            let a = readings[evidence[first]].box
            for second in evidence.indices where second > first {
                let b = readings[evidence[second]].box
                if a.contains(CGPoint(x: b.midX, y: b.midY)) || b.contains(CGPoint(x: a.midX, y: a.midY)) {
                    parent[root(first)] = root(second)
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in evidence.indices { groups[root(index), default: []].append(evidence[index]) }
        guard groups.count > 1 else { return evidence }

        func score(_ group: [Int]) -> Double {
            var total = 0.0
            for (words, share) in [(entry.name, 1.0), (entry.city, 0.7)] {
                for word in words {
                    guard let values = strengths[word] else { continue }
                    total += share * (weights[word] ?? 1) * (group.map { values[$0] }.max() ?? 0)
                }
            }
            return total
        }
        let best = groups.values.max { lhs, rhs in
            let left = score(lhs), right = score(rhs)
            return left != right ? left < right : lhs.count < rhs.count
        }
        return (best ?? evidence).sorted()
    }

    // MARK: - Reading the text

    private struct Reading {
        let words: Set<String>
        /// Letters and digits only, so "HOUSEOF HAR LEY" still contains "house".
        let squashed: String
        let bytes: [UInt8]
        let bigrams: Set<UInt16>
        let box: CGRect
    }

    private static func readings(from snippets: [Snippet]) -> [Reading] {
        var seen = Set<String>()
        var readings: [Reading] = []
        for snippet in snippets {
            let words = Self.words(in: snippet.text)
            let squashed = words.joined()
            guard squashed.count >= 2 else { continue }
            // The same text read in several passes only needs matching once, but keep its spots.
            let key = squashed + "@\(Int(snippet.box.midX * 20)),\(Int(snippet.box.midY * 20))"
            guard seen.insert(key).inserted else { continue }
            let bytes = Array(squashed.utf8)
            readings.append(Reading(words: Set(words), squashed: squashed, bytes: bytes,
                                    bigrams: bigrams(of: bytes), box: snippet.box))
        }
        return readings
    }

    /// For every word that could matter, how strongly each reading contains it (0...1).
    /// State codes are keyed "#wi" so they only ever match as whole words.
    private func tokenStrengths(in readings: [Reading]) -> [String: [Double]] {
        var vocabulary = Set<String>()
        var codes = Set<String>()
        for entry in entries {
            vocabulary.formUnion(entry.name)
            vocabulary.formUnion(entry.city)
            vocabulary.formUnion(entry.regionName)
            codes.insert(entry.regionCode)
        }

        var strengths: [String: [Double]] = [:]
        for word in vocabulary {
            let bytes = Array(word.utf8)
            let bigrams = Self.bigrams(of: bytes)
            var values = [Double](repeating: 0, count: readings.count)
            var any = false
            for (index, reading) in readings.enumerated() {
                let value = Self.strength(of: word, bytes: bytes, bigrams: bigrams, in: reading)
                if value > 0 { values[index] = value; any = true }
            }
            if any { strengths[word] = values }
        }
        for code in codes where !code.isEmpty {
            let values = readings.map { $0.words.contains(code) ? 1.0 : 0 }
            if values.contains(where: { $0 > 0 }) { strengths["#" + code] = values }
        }
        return strengths
    }

    /// How well `word` appears in a reading: 1 as a whole word, less for a near miss
    /// ("DAVIDS0N", a letter dropped) or a fragment cut off at the edge of the chip.
    private static func strength(of word: String, bytes: [UInt8], bigrams: Set<UInt16>, in reading: Reading) -> Double {
        if reading.words.contains(word) { return 1 }
        let length = bytes.count
        guard length >= 4 else { return 0 }
        if reading.squashed.contains(word) { return 0.95 }
        guard length >= 5 else { return 0 }

        // Cheap filter: a near miss or a long fragment shares several letter pairs.
        let shared = bigrams.reduce(0) { $0 + (reading.bigrams.contains($1) ? 1 : 0) }
        let needed = length >= 8 ? min(length - 5, 4) : min(length - 3, 4)
        guard shared >= max(needed, 1) else { return 0 }

        let distance = approximateDistance(of: bytes, in: reading.bytes)
        if distance == 1 { return 0.8 }
        if length >= 8 && distance == 2 { return 0.7 }
        if length >= 6 {
            let run = longestCommonRun(bytes, reading.bytes)
            if run >= 5 && Double(run) >= 0.6 * Double(length) {
                return 0.55 * Double(run) / Double(length)
            }
        }
        return 0
    }

    // MARK: - Text helpers

    /// Lowercased words without accents or punctuation: "McDaniel's H-D" → ["mcdaniels", "h", "d"].
    static func words(in text: String) -> [String] {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        return folded
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .map(String.init)
    }

    /// Words that tell one store from another: no "Harley-Davidson", nothing under 3 letters.
    static func distinctive(_ words: [String]) -> [String] {
        var result: [String] = []
        for word in words where word.count >= 3 && !stopWords.contains(word) && !result.contains(word) {
            result.append(word)
        }
        return result
    }

    private static func bigrams(of bytes: [UInt8]) -> Set<UInt16> {
        guard bytes.count >= 2 else { return [] }
        var set = Set<UInt16>()
        for index in 0..<(bytes.count - 1) {
            set.insert(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        }
        return set
    }

    /// Fewest edits to turn `pattern` into some stretch of `text` (Sellers' algorithm).
    static func approximateDistance(of pattern: [UInt8], in text: [UInt8]) -> Int {
        guard !pattern.isEmpty else { return 0 }
        guard !text.isEmpty else { return pattern.count }
        var previous = [Int](repeating: 0, count: text.count + 1)
        var current = [Int](repeating: 0, count: text.count + 1)
        for i in 1...pattern.count {
            current[0] = i
            for j in 1...text.count {
                let cost = pattern[i - 1] == text[j - 1] ? 0 : 1
                current[j] = min(previous[j - 1] + cost, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous.min() ?? pattern.count
    }

    /// Length of the longest stretch the two share.
    static func longestCommonRun(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: rhs.count + 1)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        var best = 0
        for i in 1...lhs.count {
            for j in 1...rhs.count {
                current[j] = lhs[i - 1] == rhs[j - 1] ? previous[j - 1] + 1 : 0
                best = max(best, current[j])
            }
            swap(&previous, &current)
            current[0] = 0
        }
        return best
    }
}
