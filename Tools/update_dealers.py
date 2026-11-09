#!/usr/bin/env python3
"""Refresh HarleyChipTracker/Resources/dealers.json from Harley-Davidson's public dealer locator.

Runs ~150 radius searches over a lat/long grid covering the US (incl. Alaska, Hawaii,
Puerto Rico, Guam) and Canada, de-duplicates by dealer ID, and keeps only the fields the
app needs (no staff names or email addresses).

Opening hours are kept as seven strings, Sunday first ("closed", "09:00-18:00"), in the
store's own time zone. Each location's IANA time zone is looked up from its coordinates with
the timezonefinder package (pip3 install timezonefinder); without it, time zones carry over
from the previous list and new locations go without one (the app then shows their weekly
hours but not whether they're open right now).

Collectors' chips are keyed by these dealer IDs, so the list only ever grows. A location
from the previous list that's gone from the locator is kept, marked "closed" with the date
it disappeared, and the app keeps showing it to anyone who has its chip. Every ID ever
shipped is also listed in HarleyChipTrackerTests/Fixtures/known-dealer-ids.txt, and a test
fails if one of them stops resolving.

Usage:
    python3 Tools/update_dealers.py              # writes the bundled dealers.json
    python3 Tools/update_dealers.py --cache /tmp/hd-cache   # reuse raw responses between runs
"""
import argparse
import datetime
import json
import os
import re
import sys
import time
import urllib.request
from collections import Counter

try:
    from timezonefinder import TimezoneFinder
except ImportError:  # optional, see the docstring
    TimezoneFinder = None

ENDPOINT = (
    "https://www.harley-davidson.com/dealerservices/services/rest/dealers/proximitySearch.json"
    "?_type=json&size=500&latlng={lat},{lon}&miles={miles}&locale=en_US"
)
RADIUS_MILES = 300
PAGE_SIZE = 500

# authCode -> app kind. D = dealership, SRL = secondary retail (satellite) store,
# ARO = apparel/retail outlet (boutique gift shop). Others (e.g. MISC) are skipped.
KIND = {"D": "dealer", "SRL": "satellite", "ARO": "shop"}
# Feed country -> (app country, region override)
COUNTRY = {"USA": ("US", None), "PRI": ("US", "PR"), "GUM": ("US", "GU"), "CAN": ("CA", None)}

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(REPO, "HarleyChipTracker", "Resources", "dealers.json")
KNOWN_IDS = os.path.join(REPO, "HarleyChipTrackerTests", "Fixtures", "known-dealer-ids.txt")
DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
TIME = r"(\d{1,2}):(\d{2})\s*([AP])\.?M\.?"


def grid_points():
    points = []
    lat = 24.0
    while lat <= 50:  # lower 48, every 4 degrees
        lon = -125.0
        while lon <= -66:
            points.append((lat, lon))
            lon += 4
        lat += 4
    for lat in (52, 56):  # southern and central Canada
        for lon in range(-130, -55, 5):
            points.append((lat, lon))
    points += [
        (61.2, -149.9), (64.8, -147.7), (58.3, -134.4),  # Alaska
        (21.3, -157.9), (19.7, -155.1),  # Hawaii
        (18.4, -66.1), (13.5, 144.8),  # Puerto Rico, Guam
        (47.5, -52.7), (46.2, -63.1), (60.7, -135.0), (62.4, -114.4),  # Atlantic Canada, territories
        (48.5, -123.4), (45.5, -73.6), (43.7, -79.4), (46.8, -71.2), (48.4, -89.2), (46.5, -84.3),
    ]
    return points


def fetch(lat, lon, cache_dir):
    cache_file = os.path.join(cache_dir, f"{lat}_{lon}.json") if cache_dir else None
    if cache_file and os.path.exists(cache_file):
        with open(cache_file, "rb") as fh:
            return json.loads(fh.read())
    url = ENDPOINT.format(lat=lat, lon=lon, miles=RADIUS_MILES)
    request = urllib.request.Request(url, headers={"User-Agent": "HarleyChipTracker dealer list refresh"})
    for attempt in range(3):
        try:
            data = urllib.request.urlopen(request, timeout=60).read()
            break
        except Exception as error:  # noqa: BLE001 - retry any network failure
            print(f"  retry {lat},{lon}: {error}", file=sys.stderr)
            time.sleep(3 * (attempt + 1))
    else:
        raise RuntimeError(f"Could not fetch {lat},{lon}")
    if cache_file:
        with open(cache_file, "wb") as fh:
            fh.write(data)
    time.sleep(0.8)  # be polite
    return json.loads(data)


def clean(value):
    return re.sub(r"\s+", " ", (value or "").strip())


def clock(hour, minute, half):
    """("06", "30", "P") -> "18:30"."""
    return f"{int(hour) % 12 + (12 if half.upper() == 'P' else 0):02d}:{minute}"


def parse_hours(text):
    """'Sunday: Closed<br/>Monday: 09:00 AM - 06:00 PM<br/>...' -> ["closed", "09:00-18:00", ...].

    Sunday first. Returns None when no hours are listed, or when every day is closed: a few
    seasonal shops list the whole week as closed off-season, and the app shouldn't call them
    closed when the season comes round. Raises ValueError on a line it can't read.
    """
    days = {}
    for line in re.split(r"<br\s*/?>|\n", text or "", flags=re.IGNORECASE):
        line = clean(line)
        if not line:
            continue
        name, _, value = line.partition(":")
        name, value = name.strip().title(), value.strip()
        if name not in DAY_NAMES or name in days:
            raise ValueError(f"unexpected day in {line!r}")
        if value.lower() == "closed":
            days[name] = "closed"
            continue
        ranges = []
        for part in re.split(r"\s*[,&]\s*", value):
            match = re.fullmatch(TIME + r"\s*[-\u2013]\s*" + TIME, part, flags=re.IGNORECASE)
            if not match:
                raise ValueError(f"unreadable hours {line!r}")
            ranges.append(clock(*match.groups()[:3]) + "-" + clock(*match.groups()[3:]))
        days[name] = ",".join(ranges)
    if not days or all(value == "closed" for value in days.values()):
        return None
    if set(days) != set(DAY_NAMES):
        raise ValueError(f"missing days: {sorted(set(DAY_NAMES) - set(days))}")
    return [days[name] for name in DAY_NAMES]


def time_zone_finder(previous):
    """Returns a function (id, lat, lon) -> IANA time zone or None."""
    known = {r["id"]: r["timeZone"] for r in previous if r.get("timeZone")}
    if TimezoneFinder is None:
        print("warning: timezonefinder isn't installed (pip3 install timezonefinder); "
              "reusing time zones from the previous list", file=sys.stderr)
        return lambda dealer_id, lat, lon: known.get(dealer_id)
    finder = TimezoneFinder()

    def zone_for(dealer_id, lat, lon):
        # On land only: a point just offshore would otherwise get an "Etc/GMT+5" sea zone,
        # which never observes daylight saving time.
        zone = finder.timezone_at_land(lat=lat, lng=lon) if lat is not None else None
        return zone or known.get(dealer_id)

    return zone_for


def to_record(raw, zone_for):
    kind = KIND.get(raw.get("authCode"))
    contact = raw.get("contact") or {}
    mapped = COUNTRY.get(contact.get("country"))
    if not kind or not mapped:
        return None
    country, region_override = mapped
    city = clean(contact.get("city"))
    if city.isupper():
        city = city.title()
    try:
        lat = round(float(contact["latitude"]), 6)
        lon = round(float(contact["longitude"]), 6)
    except (KeyError, TypeError, ValueError):
        lat = lon = None
    website = clean(raw.get("website"))
    if website and not website.lower().startswith("http"):
        website = "https://" + website
    record = {
        "id": "hd-" + str(raw["id"]).lstrip("0"),
        "name": clean(raw.get("dbaName") or raw.get("name")),
        "kind": kind,
        "address": clean(contact.get("address1")),
        "city": city,
        "region": region_override or clean(contact.get("state")).upper(),
        "postalCode": clean(contact.get("postalCode")),
        "country": country,
        "latitude": lat,
        "longitude": lon,
        "phone": clean(contact.get("phoneNumber")) or None,
        "website": website or None,
    }
    if raw.get("parentId") and kind != "dealer":
        record["parentId"] = "hd-" + str(raw["parentId"]).lstrip("0")
    record["timeZone"] = zone_for(record["id"], lat, lon)
    try:
        record["hours"] = parse_hours((raw.get("hours") or {}).get("dealerHours"))
    except ValueError as error:
        print(f"warning: {record['name']} ({record['id']}): {error}; leaving its hours out", file=sys.stderr)
    return {key: value for key, value in record.items() if value not in (None, "")}


def load_previous(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)["dealers"]
    except FileNotFoundError:
        return []


def carry_over_closed(records, previous, today):
    """Keeps every location from the previous list that the locator no longer returns.

    Marked "closed" with the date it went missing (kept from an earlier run if it was already
    closed), without its old opening hours. One that comes back in the locator is fresh from
    the feed, so it reopens.
    """
    current = {r["id"] for r in records}
    closed = []
    for old in previous:
        if old["id"] not in current:
            kept = {key: value for key, value in old.items() if key != "hours"}
            closed.append({**kept, "closed": old.get("closed") or today})
    return records + closed, len(closed)


def update_known_ids(ids):
    """Adds any new IDs to the list of every dealer ID the app has shipped."""
    known = set()
    if os.path.exists(KNOWN_IDS):
        with open(KNOWN_IDS, encoding="utf-8") as fh:
            known = {line.strip() for line in fh if line.strip() and not line.startswith("#")}
    missing = known - set(ids)
    if missing:
        sys.exit(f"these shipped dealer IDs would disappear: {sorted(missing)}")
    with open(KNOWN_IDS, "w", encoding="utf-8") as fh:
        fh.write("# Every dealer ID Chip Chaser has ever bundled. Collectors' chips are keyed by them,\n")
        fh.write("# so each one must stay in dealers.json (closed if need be). Tools/update_dealers.py adds to it.\n")
        fh.write("\n".join(sorted(known | set(ids), key=lambda i: (len(i), i))) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--cache", help="directory to cache raw responses in")
    args = parser.parse_args()
    if args.cache:
        os.makedirs(args.cache, exist_ok=True)

    raw = {}
    points = grid_points()
    for index, (lat, lon) in enumerate(points, 1):
        dealers = fetch(lat, lon, args.cache)["dealerResponse"].get("dealers") or []
        if len(dealers) >= PAGE_SIZE:
            print(f"warning: {lat},{lon} hit the page size; shrink RADIUS_MILES", file=sys.stderr)
        for dealer in dealers:
            raw[dealer["id"]] = dealer
        print(f"[{index}/{len(points)}] {lat},{lon}: {len(dealers)} (unique so far {len(raw)})", flush=True)

    previous = load_previous(args.out)
    zone_for = time_zone_finder(previous)
    records = [r for r in (to_record(d, zone_for) for d in raw.values()) if r]
    today = datetime.date.today().isoformat()
    records, closed_count = carry_over_closed(records, previous, today)
    records.sort(key=lambda r: (r["country"] != "US", r["country"], r["region"], r["name"].lower(), r["city"]))
    ids = [r["id"] for r in records]
    if len(ids) != len(set(ids)):
        sys.exit("duplicate dealer IDs in output")
    if args.out == DEFAULT_OUT:
        update_known_ids(ids)

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write('{\n  "source": "Harley-Davidson public dealer locator",\n')
        fh.write(f'  "generated": "{today}",\n  "dealers": [\n')
        fh.write(",\n".join("    " + json.dumps(r, ensure_ascii=False) for r in records))
        fh.write("\n  ]\n}\n")

    print(f"Wrote {len(records)} locations to {args.out}")
    print("  by country:", dict(Counter(r["country"] for r in records)))
    print("  by kind:", dict(Counter(r["kind"] for r in records)))
    print(f"  closed, kept so collectors keep their chips: {closed_count}")
    open_records = [r for r in records if not r.get("closed")]
    print(f"  open with hours: {sum('hours' in r for r in open_records)} of {len(open_records)}")
    print(f"  without a time zone: {[r['id'] for r in records if 'timeZone' not in r]}")
    print("  by time zone:", dict(Counter(r.get("timeZone") for r in records).most_common()))


if __name__ == "__main__":
    main()
