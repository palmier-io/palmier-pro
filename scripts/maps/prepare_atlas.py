#!/usr/bin/env python3
"""Prepare the bundled atlas from Natural Earth's public-domain GeoJSON files."""

import argparse
import hashlib
import json
import math
from pathlib import Path


def coordinate(point):
    return {"longitude": round(point[0], 5), "latitude": round(point[1], 5)}


def polygons(geometry):
    raw = geometry["coordinates"]
    if geometry["type"] == "Polygon":
        raw = [raw]
    if geometry["type"] not in ("Polygon", "MultiPolygon"):
        raise ValueError("Expected polygon geometry")
    return [[[coordinate(point) for point in ring] for ring in polygon] for polygon in raw]


def center(geometry):
    raw = geometry["coordinates"]
    if geometry["type"] == "Polygon":
        raw = [raw]
    ring = max((polygon[0] for polygon in raw), key=len)
    radians = [math.radians(point[0]) for point in ring]
    longitude = math.degrees(math.atan2(sum(map(math.sin, radians)), sum(map(math.cos, radians))))
    return {"longitude": round(longitude, 5), "latitude": round(sum(p[1] for p in ring) / len(ring), 5)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    regions = []
    for filename, level in (("countries.geojson", "country"), ("admin1.geojson", "subdivision")):
        data = json.loads((args.source / filename).read_text())
        for feature in data["features"]:
            p = feature["properties"]
            if level == "country":
                name, code, country = p["NAME_EN"], p["ADM0_A3"], p["ADMIN"]
                identifier = "country:" + code
                aliases = [p.get("NAME"), p.get("NAME_LONG"), p.get("ISO_A2"), code]
                if code == "USA":
                    aliases += ["United States", "USA", "US"]
                if code == "GBR":
                    aliases += ["United Kingdom", "UK"]
                if code == "GEO":
                    aliases += ["Georgia (country)"]
                location = center(feature["geometry"])
            else:
                name, country = p.get("name_en") or p["name"], p["admin"]
                identifier = "subdivision:" + p["iso_3166_2"]
                aliases = [p.get("name"), p["iso_3166_2"], name + " (" + country + ")"]
                if p["iso_3166_2"] == "US-GA":
                    aliases += ["Georgia (US state)"]
                location = {"longitude": p["longitude"], "latitude": p["latitude"]}
            regions.append({
                "id": identifier, "name": name, "country": country, "level": level,
                "classification": p.get("TYPE") if level == "country" else p.get("type"),
                "aliases": sorted({a for a in aliases if a and a != "-99" and a != name}),
                "center": location, "polygons": polygons(feature["geometry"]),
            })
    regions.sort(key=lambda region: region["id"])
    canonical = json.dumps(regions, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    result = {
        "version": "natural-earth-" + hashlib.sha256(canonical).hexdigest()[:16],
        "attribution": "Natural Earth, public domain. Country boundaries at 1:110m; available subdivisions at 1:50m. Editorial centroids and generalized boundaries; not navigation or survey data.",
        "sources": [
            "https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_110m_admin_0_countries.geojson",
            "https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_50m_admin_1_states_provinces.geojson",
        ],
        "regions": regions,
    }
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    args.destination.write_text(json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
    print(f"Prepared {len(regions)} regions: {args.destination}")


if __name__ == "__main__":
    main()
