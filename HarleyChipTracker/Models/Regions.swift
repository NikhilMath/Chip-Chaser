import Foundation

/// Display names for US states/territories and Canadian provinces.
nonisolated enum Regions {
    static let unitedStates: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
        "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "DC": "District of Columbia",
        "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois",
        "IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana",
        "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
        "MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
        "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
        "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon",
        "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
        "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia",
        "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
        "PR": "Puerto Rico", "GU": "Guam", "VI": "U.S. Virgin Islands", "AS": "American Samoa",
        "MP": "Northern Mariana Islands",
    ]

    static let canada: [String: String] = [
        "AB": "Alberta", "BC": "British Columbia", "MB": "Manitoba", "NB": "New Brunswick",
        "NL": "Newfoundland and Labrador", "NS": "Nova Scotia", "NT": "Northwest Territories",
        "NU": "Nunavut", "ON": "Ontario", "PE": "Prince Edward Island", "QC": "Quebec",
        "SK": "Saskatchewan", "YT": "Yukon",
    ]

    static func name(for code: String, country: String) -> String {
        let upper = code.uppercased()
        switch country {
        case "US": return unitedStates[upper] ?? code
        case "CA": return canada[upper] ?? code
        default: return code.isEmpty ? countryName(country) : code
        }
    }

    static func countryName(_ code: String) -> String {
        switch code {
        case "US": "United States"
        case "CA": "Canada"
        default: Locale.current.localizedString(forRegionCode: code) ?? "Other"
        }
    }

    /// Sort order for countries: US first, then Canada, then everything else.
    static func countryRank(_ code: String) -> Int {
        switch code {
        case "US": 0
        case "CA": 1
        default: 2
        }
    }
}
