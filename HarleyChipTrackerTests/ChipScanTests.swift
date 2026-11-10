import CoreLocation
import Foundation
import Testing
import UIKit
@testable import HarleyChipTracker

/// Text read off chips → the right dealer.
@MainActor
struct ChipMatcherTests {
    let directory = DealerDirectory.shared
    let matcher = ChipMatcher(dealers: DealerDirectory.shared.dealers + DealerDirectory.shared.closedDealers)

    private func find(_ texts: [String], near location: CLLocation? = nil) -> ChipMatcher.Findings {
        matcher.findChips(in: texts.map { ChipMatcher.Snippet($0) }, near: location)
    }

    @Test func readsAClearChip() {
        let findings = find(["BUMPUS", "HARLEY-DAVIDSON", "MEMPHIS, TN"])
        #expect(findings.chips.count == 1)
        #expect(findings.chips.first?.best.id == "hd-4928")
    }

    @Test func townPicksBetweenStoresWithTheSameName() {
        let findings = find(["TEDDY MORSE'S COWBOY H-D", "BEAUMONT, TEXAS"])
        #expect(findings.chips.first?.best.id == "hd-5298")
        // Teddy Morse's other Cowboy stores fit the name too, so they're offered as alternatives.
        #expect(findings.chips.first?.alternatives.contains { $0.id == "hd-5299" } == true)
    }

    @Test func toleratesMisreadLetters() {
        let findings = find(["WHlTE LIGHTN1NG", "HARLEY-DAVIDS0N", "CHATTAN0OGA TN"])
        #expect(findings.chips.first?.best.id == "hd-1173")
    }

    @Test func wordsRunTogetherStillMatch() {
        let findings = find(["BLACKHILLSHARLEYDAVIDSON", "RAPIDCITY"])
        #expect(findings.chips.first?.best.id == "hd-5357")
    }

    @Test func fragmentsSuggestTheDealer() {
        // Half the name cut off by the curve of the chip: not sure enough to add, but suggested.
        let findings = find(["CHILKOOT PA", "SKAGW"])
        let top = findings.chips.first?.best.id ?? findings.suggestions.first?.id
        #expect(top == "hd-3409")
    }

    @Test func sameNameInOneTownListsEveryStore() {
        let lasVegas = directory.dealers.filter { $0.name == "Las Vegas Harley-Davidson" }.map(\.id)
        #expect(lasVegas.count > 1)
        let chip = find(["LAS VEGAS HARLEY-DAVIDSON"]).chips.first
        let offered = Set([chip?.best.id].compactMap { $0 } + (chip?.alternatives.map(\.id) ?? []))
        #expect(Set(lasVegas).isSubset(of: offered))
    }

    @Test func chipsFromOneStateStayApart() {
        // Three Wisconsin chips, one from a store named after the state: every chip says
        // "Wisconsin", but each match keeps to its own chip and a stray "WISCONSIN" read off the
        // Milwaukee chip isn't a fourth one.
        let milwaukee = CGRect(x: 0.04, y: 0.08, width: 0.45, height: 0.34)
        let oconomowoc = CGRect(x: 0.55, y: 0.24, width: 0.36, height: 0.27)
        let westBend = CGRect(x: 0.2, y: 0.58, width: 0.36, height: 0.27)
        let snippets = [
            ChipMatcher.Snippet("• MILWAUKEE HARLEY-DAVIDSON •", box: milwaukee),
            ChipMatcher.Snippet("MILWAUKEE, WISCONSIN", box: milwaukee),
            ChipMatcher.Snippet("WISCONSIN", box: CGRect(x: 0.23, y: 0.29, width: 0.16, height: 0.08)),
            ChipMatcher.Snippet("• WISCONSIN HARLEY-DAVIDSON •", box: oconomowoc),
            ChipMatcher.Snippet("OCONOMOWOC, WISCONSIN", box: oconomowoc),
            ChipMatcher.Snippet("WEST BEND HARLEY-DAVIDSON", box: westBend),
            ChipMatcher.Snippet("WEST BEND, WISCONSIN", box: westBend),
        ]
        let chips = matcher.findChips(in: snippets).chips
        #expect(chips.map(\.best.id).sorted() == ["hd-3276", "hd-5650", "hd-5651"])
        for chip in chips {
            let middle = CGPoint(x: chip.region.midX, y: chip.region.midY)
            let home = [milwaukee, oconomowoc, westBend].filter { $0.contains(middle) }
            #expect(home.count == 1, "\(chip.best.dealer.name) spans \(chip.region)")
            #expect(home.first.map { $0.insetBy(dx: -0.01, dy: -0.01).contains(chip.region) } == true)
        }
    }

    @Test func whereThePhotoWasTakenBreaksTies() throws {
        let store = try #require(directory.dealer(id: "hd-4448"))
        let there = try #require(store.location)
        let chip = find(["LAS VEGAS HARLEY-DAVIDSON"], near: there).chips.first
        #expect(chip?.best.id == "hd-4448")
    }

    @Test func aStrongMatchBeatsANearbyPartialOne() throws {
        // At the International Drive shop, a chip that just says "Orlando Harley-Davidson" is
        // still Orlando Harley-Davidson, but the nearby shop is offered too.
        let shop = try #require(directory.dealer(id: "hd-8238")?.location)
        let chip = find(["ORLANDO HARLEY-DAVIDSON", "ORLANDO, FL"], near: shop).chips.first
        #expect(chip?.best.id == "hd-708")
        #expect(chip?.alternatives.contains { $0.id == "hd-8238" } == true)
    }

    @Test func findsSeveralChipsInOnePhoto() {
        let left = CGRect(x: 0.05, y: 0.3, width: 0.35, height: 0.1)
        let right = CGRect(x: 0.6, y: 0.3, width: 0.35, height: 0.1)
        let snippets = [
            ChipMatcher.Snippet("BUMPUS HARLEY-DAVIDSON", box: left),
            ChipMatcher.Snippet("MEMPHIS TN", box: left.offsetBy(dx: 0, dy: 0.3)),
            ChipMatcher.Snippet("BLACK HILLS", box: right),
            ChipMatcher.Snippet("RAPID CITY, SD", box: right.offsetBy(dx: 0, dy: 0.3)),
        ]
        let chips = matcher.findChips(in: snippets).chips
        #expect(Set(chips.map(\.best.id)) == ["hd-4928", "hd-5357"])
        let layout = ChipRecognizer.layout(chips: chips.map(\.region), subjects: [], imageSize: CGSize(width: 2000, height: 1500))
        let separate = layout.filter(\.separate).count
        #expect(separate == 2, "two chips apart from each other should both be added")
    }

    @Test func genericChipTextFindsNothing() {
        let findings = find(["HARLEY-DAVIDSON", "MOTORCYCLES", "$5", "EST. 1903", "POKER RUN"])
        #expect(findings.chips.isEmpty)
    }

    @Test func approximateDistanceCountsEdits() {
        func distance(_ pattern: String, _ text: String) -> Int {
            ChipMatcher.approximateDistance(of: Array(pattern.utf8), in: Array(text.utf8))
        }
        #expect(distance("memphis", "xxmemphisxx") == 0)
        #expect(distance("memphis", "xxmenphisxx") == 1)
        #expect(distance("memphis", "mphis") == 2)
        #expect(ChipMatcher.longestCommonRun(Array("milwaukee".utf8), Array("xmilwau".utf8)) == 6)
    }
}

/// Real text recognition on rendered chips (on-device Vision, like the app).
@MainActor
struct ChipRecognizerTests {
    let matcher = ChipMatcher(dealers: DealerDirectory.shared.dealers)

    @Test func readsPrintedText() async throws {
        let image = try #require(ChipArt.label(["BUMPUS HARLEY-DAVIDSON", "MEMPHIS, TENNESSEE"]))
        let scan = try await ChipRecognizer.scan(image)
        #expect(matcher.findChips(in: scan.snippets).chips.first?.best.id == "hd-4928")
    }

    @Test func readsTextCurvedAroundAChip() async throws {
        let image = try #require(ChipArt.chip(top: "WHITE LIGHTNING HARLEY-DAVIDSON", bottom: "CHATTANOOGA, TENNESSEE"))
        let scan = try await ChipRecognizer.scan(image)
        let chips = matcher.findChips(in: scan.snippets).chips
        #expect(chips.first?.best.id == "hd-1173", "read: \(scan.snippets.map(\.text))")
        #expect(chips.count == 1)
    }

    @Test(arguments: [0.0, 100.0, 200.0, 290.0])
    func readsAChipHoweverItIsTurned(degrees: Double) async throws {
        let image = try #require(ChipArt.chip(top: "SUSQUEHANNA VALLEY HARLEY-DAVIDSON", bottom: "HARRISBURG, PENNSYLVANIA",
                                              turnedBy: degrees * .pi / 180, smallerBy: 0.7))
        let scan = try await ChipRecognizer.scan(image)
        let chips = matcher.findChips(in: scan.snippets).chips
        #expect(chips.first?.best.id == "hd-4341", "turned \(degrees)°, read: \(scan.snippets.map(\.text))")
    }

    @Test func findsTwoChipsSideBySide() async throws {
        let image = try #require(ChipArt.pair(
            (top: "BLACK HILLS HARLEY-DAVIDSON", bottom: "RAPID CITY, SOUTH DAKOTA"),
            (top: "TOAD SUCK HARLEY-DAVIDSON", bottom: "CONWAY, ARKANSAS")
        ))
        let scan = try await ChipRecognizer.scan(image)
        let chips = matcher.findChips(in: scan.snippets).chips
        #expect(Set(chips.map(\.best.id)) == ["hd-5357", "hd-4150"], "read: \(scan.snippets.map(\.text))")
        let size = CGSize(width: image.width, height: image.height)
        let layout = ChipRecognizer.layout(chips: chips.map(\.region), subjects: scan.subjects, imageSize: size)
        let separate = layout.filter(\.separate).count
        #expect(separate == 2)
        // Each chip's crop sits over its own half of the photo.
        let centers = layout.map(\.crop.midX).sorted()
        #expect(centers.count == 2 && centers[0] < 0.5 && centers[1] > 0.5)
    }

    @Test func findsTheRoundChipsInAPhoto() throws {
        let image = try #require(ChipArt.pair(
            (top: "BLACK HILLS HARLEY-DAVIDSON", bottom: "RAPID CITY, SOUTH DAKOTA"),
            (top: "TOAD SUCK HARLEY-DAVIDSON", bottom: "CONWAY, ARKANSAS")
        ))
        let circles = ChipRecognizer.chipCircles(in: image)
        for center in [CGPoint(x: 500, y: 550), CGPoint(x: 1_500, y: 550)] {
            // The rim (430) or the inlay (344): either way the unrolled ring takes in the text.
            let match = circles.contains { hypot($0.center.x - center.x, $0.center.y - center.y) < 30 && (320...470).contains($0.radius) }
            #expect(match, "no chip found at \(center) in \(circles)")
        }
    }

    @Test func textFoundOnATurnedPassLandsWhereItIs() async throws {
        // Sideways text in the top-left corner: the turned pass that reads it maps its box back there.
        let image = try #require(ChipArt.sideways("SKAGWAY ALASKA", at: CGPoint(x: 0.2, y: 0.3)))
        let scan = try await ChipRecognizer.scan(image)
        let hits = scan.snippets.filter { $0.text.uppercased().contains("SKAGWAY") }
        #expect(hits.contains { $0.box.midX < 0.4 && $0.box.midY < 0.6 && $0.box.width < 0.3 },
                "read: \(hits.map { "\($0.text) \($0.box)" })")
    }
}

/// Photos saved on the iPhone, one per chip.
@MainActor
struct ChipPhotoStoreTests {
    private func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "ChipPhotoStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func sampleImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 1_200), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 1_200))
        }
    }

    @Test func exportedBackupCarriesPhotosToAnotherPhone() async throws {
        let directory = temporaryDirectory(), other = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: other)
        }
        let store = ChipPhotoStore(directory: directory)
        try store.save(sampleImage(), for: "hd-1")
        try store.save(sampleImage(), for: "hd-2")

        let backup = CollectionBackup(exportedAt: .now, chips: [.init(dealerID: "hd-1", quantity: 1, collectedAt: nil, notes: "")],
                                      customStores: [])
        let data = try CollectionExport(backup: backup, photoFiles: store.photoFiles).data()
        let decoded = try CollectionBackup.decoder.decode(CollectionBackup.self, from: data)
        #expect(decoded.photos?.count == 2)

        // The other phone already has its own photo of one chip: that one is left alone.
        let second = ChipPhotoStore(directory: other)
        try second.save(sampleImage(), for: "hd-2")
        let revision = second.revision(for: "hd-2")
        #expect(await decoded.restorePhotos(into: second) == 1)
        #expect(second.hasPhoto(for: "hd-1"))
        #expect(await second.thumbnail(for: "hd-1") != nil)
        #expect(ChipPhotoStore(directory: other).count == 2, "imported photos are on disk")
        #expect(second.revision(for: "hd-2") == revision)

        // Backups without photos (automatic ones, or from before 1.4) still read.
        let plain = try CollectionBackup.decoder.decode(CollectionBackup.self, from: CollectionBackup.encoder.encode(backup))
        #expect(plain.photos == nil)
        #expect(await plain.restorePhotos(into: second) == 0)
    }

    @Test func savesReopensAndRemoves() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = CustomDealer.dealerID(for: UUID())

        let store = ChipPhotoStore(directory: directory)
        #expect(!store.hasPhoto(for: id))
        try store.save(sampleImage(), for: id)
        #expect(store.hasPhoto(for: id))
        let firstRevision = store.revision(for: id)

        let reopened = ChipPhotoStore(directory: directory)
        #expect(reopened.hasPhoto(for: id), "photos must still be there after the app restarts")
        #expect(reopened.count == 1)
        let photo = try #require(await reopened.photo(for: id))
        #expect(max(photo.size.width, photo.size.height) <= 1_200)
        #expect(await reopened.thumbnail(for: id) != nil)

        try store.save(sampleImage(), for: id)
        #expect(store.revision(for: id) != firstRevision, "replacing a photo should refresh it on screen")

        store.removePhoto(for: id)
        #expect(!store.hasPhoto(for: id))
        #expect(ChipPhotoStore(directory: directory).count == 0)
    }

    @Test func everyIDMakesASafeFileName() {
        for id in ["hd-1069", CustomDealer.dealerID(for: UUID()), "odd/id with spaces.%"] {
            let name = ChipPhotoStore.fileName(for: id)
            #expect(!name.contains("/") && !name.contains("."))
            #expect(ChipPhotoStore.dealerID(fromFileName: name + ".jpg") == id)
        }
    }
}

/// Draws stand-in chips for the recognizer tests: an original design, not any real chip.
enum ChipArt {
    static func label(_ lines: [String]) -> CGImage? {
        render(size: CGSize(width: 1_400, height: 900)) { context in
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_400, height: 900))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 64, weight: .heavy),
                                                             .foregroundColor: UIColor.black]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 80, y: 260 + CGFloat(index) * 140), withAttributes: attributes)
            }
        }
    }

    /// One chip on a wooden table, turned by `angle` radians and `smallerBy` of the frame
    /// off center, like a quick photo.
    static func chip(top: String, bottom: String, turnedBy angle: Double = 0, smallerBy share: CGFloat = 1) -> CGImage? {
        render(size: CGSize(width: 1_500, height: 1_200)) { context in
            UIColor(red: 0.42, green: 0.36, blue: 0.3, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_500, height: 1_200))
            let cg = context.cgContext
            let center = CGPoint(x: share < 1 ? 820 : 750, y: share < 1 ? 560 : 600)
            cg.translateBy(x: center.x, y: center.y)
            cg.rotate(by: angle)
            drawChip(in: cg, center: .zero, radius: 520 * share, top: top, bottom: bottom)
        }
    }

    static func pair(_ first: (top: String, bottom: String), _ second: (top: String, bottom: String)) -> CGImage? {
        render(size: CGSize(width: 2_000, height: 1_100)) { context in
            UIColor(red: 0.2, green: 0.3, blue: 0.22, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_000, height: 1_100))
            drawChip(in: context.cgContext, center: CGPoint(x: 500, y: 550), radius: 430, top: first.top, bottom: first.bottom)
            drawChip(in: context.cgContext, center: CGPoint(x: 1_500, y: 550), radius: 430, top: second.top, bottom: second.bottom)
        }
    }

    static func sideways(_ text: String, at point: CGPoint) -> CGImage? {
        render(size: CGSize(width: 1_200, height: 1_200)) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 1_200))
            let cg = context.cgContext
            cg.translateBy(x: point.x * 1_200, y: point.y * 1_200)
            cg.rotate(by: -.pi / 2)
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 56, weight: .bold),
                                                             .foregroundColor: UIColor.black]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
        }
    }

    /// A clay chip: colored rim with edge spots, a light inlay, and text around the inlay.
    static func drawChip(in context: CGContext, center: CGPoint, radius: CGFloat, top: String, bottom: String) {
        context.setFillColor(UIColor(red: 0.75, green: 0.12, blue: 0.1, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setFillColor(UIColor.white.cgColor)
        for spot in 0..<8 {
            let angle = Double(spot) * .pi / 4
            context.saveGState()
            context.translateBy(x: center.x + cos(angle) * radius * 0.93, y: center.y + sin(angle) * radius * 0.93)
            context.rotate(by: angle)
            context.fill(CGRect(x: -radius * 0.07, y: -radius * 0.09, width: radius * 0.14, height: radius * 0.18))
            context.restoreGState()
        }
        let inlay = radius * 0.8
        context.setFillColor(UIColor(white: 0.96, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - inlay, y: center.y - inlay, width: inlay * 2, height: inlay * 2))
        context.setFillColor(UIColor(white: 0.1, alpha: 1).cgColor)
        let shield = inlay * 0.38
        context.fill(CGRect(x: center.x - shield, y: center.y - shield * 0.7, width: shield * 2, height: shield * 1.4))

        let font = UIFont.systemFont(ofSize: radius * 0.105, weight: .heavy)
        drawArc(top, in: context, center: center, radius: inlay * 0.82, font: font, onTop: true)
        drawArc(bottom, in: context, center: center, radius: inlay * 0.82, font: font, onTop: false)
    }

    /// Text along a circle: over the top reading clockwise, under the bottom reading upright.
    private static func drawArc(_ text: String, in context: CGContext, center: CGPoint, radius: CGFloat, font: UIFont, onTop: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let letters = text.map { String($0) as NSString }
        let widths = letters.map { $0.size(withAttributes: attributes).width + font.pointSize * 0.06 }
        let sweep = widths.reduce(0, +) / radius
        var angle = onTop ? -.pi / 2 - sweep / 2 : .pi / 2 + sweep / 2
        for (letter, width) in zip(letters, widths) {
            let half = width / 2 / radius
            angle += onTop ? half : -half
            context.saveGState()
            context.translateBy(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            context.rotate(by: onTop ? angle + .pi / 2 : angle - .pi / 2)
            let size = letter.size(withAttributes: attributes)
            UIGraphicsPushContext(context)
            letter.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
            UIGraphicsPopContext()
            context.restoreGState()
            angle += onTop ? half : -half
        }
    }

    private static func render(size: CGSize, draw: (UIGraphicsImageRendererContext) -> Void) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw).cgImage
    }
}

/// The round camera crops the photo to the circle the collector lined the chip up in.
@MainActor
struct ChipCameraCropTests {
    @Test func cropMatchesTheCircleOnScreen() throws {
        // A 3024×4032 portrait photo aspect-filled into a 402×874 screen.
        let view = CGSize(width: 402, height: 874)
        let image = CGSize(width: 3024, height: 4032)
        let circle = ChipCamera.circle(in: view)
        let rect = try #require(ChipCamera.cropRect(imageSize: image, circle: circle, viewSize: view))

        #expect(abs(rect.width - rect.height) <= 2, "a square around the circle")
        #expect(abs(rect.midX - image.width / 2) <= 2, "centered left to right")
        // The circle sits a little above the middle of the screen, and so of the photo.
        let scale = max(view.width / image.width, view.height / image.height)
        let offsetY = (view.height - image.height * scale) / 2
        #expect(abs(rect.midY - (circle.midY - offsetY) / scale) <= 2)
        #expect(CGRect(origin: .zero, size: image).contains(rect))
    }

    @Test func cropStaysInsideThePhoto() throws {
        let view = CGSize(width: 400, height: 400)
        let image = CGSize(width: 1000, height: 1000)
        let huge = CGRect(x: -50, y: -50, width: 500, height: 500)
        let rect = try #require(ChipCamera.cropRect(imageSize: image, circle: huge, viewSize: view))
        #expect(rect == CGRect(origin: .zero, size: image))
    }
}
