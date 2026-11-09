import SwiftUI

/// Whether a store is open right now, opening to its weekly hours.
///
/// Everything is read by the store's own clock (`timeZone`), so a rider in Chicago looking at a
/// Denver dealer sees Denver's hours, with a note when the store keeps a different time.
struct StoreHoursRow: View {
    let hours: OpeningHours
    /// The store's time zone. Without one the weekly hours still show, but not open or closed.
    let timeZone: TimeZone?

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            TimelineView(.everyMinute) { context in
                schedule(now: context.date)
            }
        } label: {
            TimelineView(.everyMinute) { context in
                Label {
                    status(now: context.date)
                } icon: {
                    Image(systemName: "clock")
                }
            }
        }
    }

    @ViewBuilder
    private func status(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let timeZone, let status = hours.status(at: now, in: timeZone) {
                let headline = Text(status.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(status.isOpen ? Color.green : Color.secondary)
                if let detail = status.detail(now: now, timeZone: timeZone) {
                    Text("\(headline) · \(detail)")
                } else {
                    headline
                }
                if timeZone.secondsFromGMT(for: now) != TimeZone.current.secondsFromGMT(for: now),
                   let zoneName = zoneName(timeZone) {
                    Text("Store hours in \(zoneName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Hours")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func schedule(now: Date) -> some View {
        let today = timeZone.map { OpeningHours.calendar(in: $0).component(.weekday, from: now) }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.weekdays, id: \.self) { weekday in
                HStack(alignment: .firstTextBaseline) {
                    Text(Calendar.current.weekdaySymbols[weekday - 1])
                    Spacer(minLength: 12)
                    Text(hours.text(forWeekday: weekday))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(weekday == today ? HierarchicalShapeStyle.primary : .secondary)
                }
                .fontWeight(weekday == today ? .semibold : .regular)
                .accessibilityElement(children: .combine)
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    private var footnote: String {
        let source = "Regular hours from Harley-Davidson's dealer list. Holiday hours may differ."
        guard let timeZone, let zoneName = zoneName(timeZone) else { return source }
        return "Times are \(zoneName). \(source)"
    }

    private func zoneName(_ zone: TimeZone) -> String? {
        zone.localizedName(for: .generic, locale: .current)
    }

    /// The week in the order the phone's calendar starts it (Sunday first in the US).
    private static var weekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
}

#Preview {
    Form {
        StoreHoursRow(
            hours: OpeningHours(strings: ["closed", "09:00-18:00", "09:00-18:00", "09:00-18:00",
                                          "09:00-19:00", "09:00-18:00", "09:00-16:00"]),
            timeZone: TimeZone(identifier: "America/Denver")
        )
    }
}
