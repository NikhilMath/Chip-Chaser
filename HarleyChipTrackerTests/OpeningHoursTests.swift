import Foundation
import Testing
@testable import HarleyChipTracker

/// Store hours: reading the dealers.json form, and open or closed by the store's own clock.
struct OpeningHoursTests {
    typealias Interval = OpeningHours.Interval

    /// House of Harley-Davidson's listing: closed Sunday, 9 to 6 on weekdays, 9 to 4 Saturday.
    let weekly = OpeningHours(strings: ["closed", "09:00-18:00", "09:00-18:00", "09:00-18:00",
                                        "09:00-18:00", "09:00-18:00", "09:00-16:00"])
    let chicago = TimeZone(identifier: "America/Chicago")!
    let denver = TimeZone(identifier: "America/Denver")!
    let locale = Locale(identifier: "en_US")

    /// An instant written with its UTC offset, like "2026-11-10T09:30:00-06:00".
    private func at(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso), "bad date \(iso)")
    }

    /// The status line, with ICU's narrow no-break spaces ("6\u{202F}PM") made plain.
    private func statusText(_ hours: OpeningHours, at date: Date, in zone: TimeZone) throws -> String {
        let status = try #require(hours.status(at: date, in: zone))
        return plain(status.text(now: date, timeZone: zone, locale: locale))
    }

    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func dealer(hours: OpeningHours?, timeZone: String?, closed: String? = nil) -> Dealer {
        Dealer(id: "hd-1", name: "Test Harley-Davidson", kind: .dealer, city: "Greenfield", region: "WI",
               country: "US", latitude: 42.96, longitude: -87.99, closed: closed, hours: hours, timeZone: timeZone)
    }

    // MARK: Reading the listing

    @Test func readsTheListingFormat() {
        #expect(weekly.isComplete)
        #expect(weekly.hasOpenTime)
        #expect(weekly.days[0] == [])
        #expect(weekly.days[1] == [Interval(open: 540, close: 1080)])
        #expect(weekly.intervals(forWeekday: 7) == [Interval(open: 540, close: 960)])

        #expect(OpeningHours.parseDay("09:00-12:00,13:00-17:30") == [Interval(open: 540, close: 720),
                                                                     Interval(open: 780, close: 1050)])
        #expect(OpeningHours.parseDay(" Closed ") == [])
        #expect(OpeningHours.parseDay("10:00-24:00") == [Interval(open: 600, close: 0)])
        #expect(OpeningHours.parseDay(nil) == nil)
        #expect(OpeningHours.parseDay("9am-5pm") == nil)
        #expect(OpeningHours.parseDay("09:00-25:00") == nil)
        #expect(OpeningHours.parseDay("") == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(weekly)
        #expect(String(decoding: data, as: UTF8.self)
            == #"["closed","09:00-18:00","09:00-18:00","09:00-18:00","09:00-18:00","09:00-18:00","09:00-16:00"]"#)
        #expect(try JSONDecoder().decode(OpeningHours.self, from: data) == weekly)
    }

    /// Lists and backups from before hours existed must still load.
    @Test func olderDealerDataStillDecodes() throws {
        let json = #"{"id": "hd-1", "name": "Old", "kind": "dealer", "city": "Sturgis", "region": "SD", "country": "US"}"#
        let old = try JSONDecoder().decode(Dealer.self, from: Data(json.utf8))
        #expect(old.hours == nil)
        #expect(old.timeZone == nil)
        #expect(old.openingHours == nil)
        #expect(old.openStatus() == nil)
    }

    /// One store's odd hours must never stop the whole dealer list from loading.
    @Test func malformedHoursDecodeAsNotListed() throws {
        for hours in [#""9 to 5""#, "[1, 2, 3]", #"["closed", "whenever"]"#, "{}"] {
            let json = #"{"id": "hd-1", "name": "Odd", "kind": "dealer", "city": "Sturgis", "region": "SD", "country": "US", "#
                + #""timeZone": "America/Denver", "hours": \#(hours)}"#
            let dealer = try JSONDecoder().decode(Dealer.self, from: Data(json.utf8))
            #expect(dealer.openingHours == nil, "\(hours)")
            #expect(dealer.openStatus() == nil, "\(hours)")
        }
    }

    // MARK: Open or closed

    /// The same moment reads differently in Wisconsin and Colorado: each store keeps its own clock.
    @Test func usesTheStoresTimeZone() throws {
        let moment = try at("2026-11-10T15:30:00Z") // Tuesday, 9:30 AM in Chicago, 8:30 AM in Denver
        #expect(try statusText(weekly, at: moment, in: chicago) == "Open now · closes 6 PM")
        #expect(try statusText(weekly, at: moment, in: denver) == "Closed · opens 9 AM")

        let wisconsin = dealer(hours: weekly, timeZone: "America/Chicago")
        let colorado = dealer(hours: weekly, timeZone: "America/Denver")
        #expect(wisconsin.openStatus(at: moment)?.isOpen == true)
        #expect(colorado.openStatus(at: moment)?.isOpen == false)
    }

    @Test func closedDaysPointToTheNextOpening() throws {
        #expect(try statusText(weekly, at: at("2026-11-14T15:00:00-06:00"), in: chicago) == "Open now · closes 4 PM")
        #expect(try statusText(weekly, at: at("2026-11-14T16:00:00-06:00"), in: chicago) == "Closed · opens 9 AM Mon")
        #expect(try statusText(weekly, at: at("2026-11-08T12:00:00-06:00"), in: chicago) == "Closed · opens 9 AM Mon")
        #expect(try statusText(weekly, at: at("2026-11-09T08:59:00-06:00"), in: chicago) == "Closed · opens 9 AM")
        #expect(try statusText(weekly, at: at("2026-11-09T09:00:00-06:00"), in: chicago) == "Open now · closes 6 PM")
        #expect(try statusText(weekly, at: at("2026-11-13T18:00:00-06:00"), in: chicago) == "Closed · opens 9 AM Sat")
    }

    @Test func overnightHoursRunPastMidnight() throws {
        let lateFriday = OpeningHours(strings: ["closed", "closed", "closed", "closed", "closed", "20:00-02:00", "closed"])
        #expect(try statusText(lateFriday, at: at("2026-11-13T19:00:00-06:00"), in: chicago) == "Closed · opens 8 PM")
        #expect(try statusText(lateFriday, at: at("2026-11-13T23:00:00-06:00"), in: chicago) == "Open now · closes 2 AM Sat")
        // Saturday's own listing is "closed", but Friday night is still going.
        #expect(try statusText(lateFriday, at: at("2026-11-14T01:30:00-06:00"), in: chicago) == "Open now · closes 2 AM")
        #expect(try statusText(lateFriday, at: at("2026-11-14T02:00:00-06:00"), in: chicago) == "Closed · opens 8 PM Fri")
    }

    @Test func lateNightsThatRunIntoTheNextDaysHoursJoinUp() throws {
        let hours = OpeningHours(strings: Array(repeating: "09:00-00:00", count: 6) + ["00:00-00:00"])
        // Saturday is open all day, so Friday night carries on until Sunday at midnight.
        #expect(try statusText(hours, at: at("2026-11-13T23:00:00-06:00"), in: chicago) == "Open now · closes 12 AM Sun")
        #expect(try statusText(hours, at: at("2026-11-10T23:00:00-06:00"), in: chicago) == "Open now · closes 12 AM Wed")
    }

    @Test func openAroundTheClock() throws {
        let always = OpeningHours(strings: Array(repeating: "00:00-00:00", count: 7))
        #expect(try statusText(always, at: at("2026-11-10T03:00:00-06:00"), in: chicago) == "Open 24 hours")
        #expect(always.text(forWeekday: 3, locale: locale) == "Open 24 hours")
    }

    @Test func showsMinutesWhenNotOnTheHour() throws {
        let hours = OpeningHours(strings: Array(repeating: "10:00-23:30", count: 7))
        #expect(try statusText(hours, at: at("2026-11-10T22:00:00-06:00"), in: chicago) == "Open now · closes 11:30 PM")
    }

    /// Clocks jump on daylight-saving days; closing time must follow the store's wall clock.
    @Test func followsDaylightSavingTime() throws {
        let daily = OpeningHours(strings: Array(repeating: "09:00-18:00", count: 7))
        // Spring forward on Sunday, March 14, 2027: 9:30 AM is now UTC-5.
        let spring = try at("2027-03-14T09:30:00-05:00")
        #expect(try daily.status(at: spring, in: chicago) == .open(closes: at("2027-03-14T18:00:00-05:00")))
        // The evening before is still UTC-6, and the next opening is 9 AM daylight time.
        let saturdayNight = try at("2027-03-13T20:00:00-06:00")
        #expect(try daily.status(at: saturdayNight, in: chicago) == .closed(opens: at("2027-03-14T09:00:00-05:00")))
        // Fall back on Sunday, November 1, 2026.
        let fall = try at("2026-11-01T17:00:00-06:00")
        #expect(try daily.status(at: fall, in: chicago) == .open(closes: at("2026-11-01T18:00:00-06:00")))
    }

    /// Arizona doesn't observe daylight saving time, so in July it's an hour behind Denver.
    @Test func arizonaKeepsItsOwnTime() throws {
        let phoenix = try #require(TimeZone(identifier: "America/Phoenix"))
        let daily = OpeningHours(strings: Array(repeating: "09:00-18:00", count: 7))
        let moment = try at("2026-07-15T15:30:00Z") // 9:30 AM in Denver, 8:30 AM in Phoenix
        #expect(daily.status(at: moment, in: denver)?.isOpen == true)
        #expect(daily.status(at: moment, in: phoenix)?.isOpen == false)
    }

    // MARK: Missing data

    @Test func missingDataShowsNoStatus() {
        let moment = Date(timeIntervalSinceReferenceDate: 815_000_000)

        // A day that isn't listed could be open, so don't claim either way.
        let partial = OpeningHours(strings: ["closed", "09:00-18:00", nil, "09:00-18:00"])
        #expect(!partial.isComplete)
        #expect(partial.status(at: moment, in: chicago) == nil)
        #expect(partial.text(forWeekday: 3, locale: locale) == "Not listed")
        #expect(partial.text(forWeekday: 7, locale: locale) == "Not listed")

        // Hours but no time zone: the week still shows, the live status doesn't.
        let noZone = dealer(hours: weekly, timeZone: nil)
        #expect(noZone.openingHours != nil)
        #expect(noZone.openStatus(at: moment) == nil)
        #expect(dealer(hours: weekly, timeZone: "Not/AZone").openStatus(at: moment) == nil)

        // Seasonal shops list every day closed off-season. That isn't worth showing.
        let seasonal = OpeningHours(strings: Array(repeating: "closed", count: 7))
        #expect(dealer(hours: seasonal, timeZone: "America/Juneau").openingHours == nil)

        // A location that left the dealer list has no hours to show.
        #expect(dealer(hours: weekly, timeZone: "America/Chicago", closed: "2027-03-01").openingHours == nil)
        #expect(dealer(hours: nil, timeZone: "America/Chicago").openStatus(at: moment) == nil)
    }

    @Test func weeklyScheduleText() {
        #expect(plain(weekly.text(forWeekday: 1, locale: locale)) == "Closed")
        #expect(plain(weekly.text(forWeekday: 2, locale: locale)) == "9 AM – 6 PM")
        #expect(plain(weekly.text(forWeekday: 7, locale: locale)) == "9 AM – 4 PM")
        let split = OpeningHours(strings: Array(repeating: "09:00-12:00,13:00-17:30", count: 7))
        #expect(plain(split.text(forWeekday: 4, locale: locale)) == "9 AM – 12 PM, 1 PM – 5:30 PM")
        let late = OpeningHours(strings: Array(repeating: "20:00-02:00", count: 7))
        #expect(plain(late.text(forWeekday: 6, locale: locale)) == "8 PM – 2 AM")
    }
}

/// The hours and time zones bundled in dealers.json.
@MainActor
struct BundledHoursTests {
    let directory = DealerDirectory.shared

    @Test func mostLocationsHaveHoursAndEveryTimeZoneIsReal() {
        let withHours = directory.dealers.filter { $0.openingHours != nil }
        #expect(withHours.count > 600)
        for dealer in directory.dealers {
            #expect(dealer.timeZone != nil, "\(dealer.name) has no time zone")
            if let zone = dealer.timeZone {
                #expect(TimeZone(identifier: zone) != nil, "\(dealer.name): unknown time zone \(zone)")
            }
        }
        for dealer in withHours {
            #expect(dealer.openingHours?.isComplete == true, "\(dealer.name) is missing a day")
            #expect(dealer.openStatus() != nil, "\(dealer.name) has hours but no status")
        }
    }

    /// Time zones come from coordinates, so states split between two zones come out right.
    @Test func splitStatesGetTheRightZone() {
        let expected = [
            "hd-3833": "America/Chicago", // Greenfield, WI
            "hd-5357": "America/Denver", // Rapid City, SD (west river)
            "hd-4871": "America/Chicago", // Sioux Falls, SD
            "hd-3863": "America/Chicago", // Pensacola, FL (panhandle)
            "hd-5045": "America/Denver", // El Paso, TX
            "hd-93": "America/Phoenix", // Phoenix, AZ (no daylight saving time)
        ]
        for (id, zone) in expected {
            #expect(directory.dealer(id: id)?.timeZone == zone, "\(id)")
        }
        for dealer in directory.dealers where dealer.region == "HI" {
            #expect(dealer.timeZone == "Pacific/Honolulu", "\(dealer.name)")
        }
    }

    @Test func houseOfHarleyDavidsonHours() throws {
        let store = try #require(directory.dealer(id: "hd-3833"))
        let hours = try #require(store.openingHours)
        let locale = Locale(identifier: "en_US")
        #expect(hours.text(forWeekday: 1, locale: locale) == "Closed")
        #expect(hours.text(forWeekday: 2, locale: locale).replacingOccurrences(of: "\u{202F}", with: " ") == "9 AM – 6 PM")
    }
}
