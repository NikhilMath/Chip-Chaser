#!/usr/bin/env python3
"""Refresh HarleyChipTracker/Resources/dealers.json from Harley-Davidson's public dealer locator.

Runs ~150 radius searches over a lat/long grid covering the US (incl. Alaska, Hawaii,
Puerto Rico, Guam) and Canada, de-duplicates by dealer ID, and keeps only the fields the
app needs (no staff names or email addresses).

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


def to_record(raw):
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
    return {key: value for key, value in record.items() if value not in (None, "")}


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

    records = [r for r in (to_record(d) for d in raw.values()) if r]
    records.sort(key=lambda r: (r["country"] != "US", r["country"], r["region"], r["name"].lower(), r["city"]))
    ids = [r["id"] for r in records]
    if len(ids) != len(set(ids)):
        sys.exit("duplicate dealer IDs in output")

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write('{\n  "source": "Harley-Davidson public dealer locator",\n')
        fh.write(f'  "generated": "{datetime.date.today().isoformat()}",\n  "dealers": [\n')
        fh.write(",\n".join("    " + json.dumps(r, ensure_ascii=False) for r in records))
        fh.write("\n  ]\n}\n")

    print(f"Wrote {len(records)} locations to {args.out}")
    print("  by country:", dict(Counter(r["country"] for r in records)))
    print("  by kind:", dict(Counter(r["kind"] for r in records)))


if __name__ == "__main__":
    main()
