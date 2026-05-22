#!/usr/bin/env python3
"""
Enrich Notion Geo Memory records where Enrichment Status = New.
Calls Google Places API to fill in lat/lng, address, city, country,
neighborhood, category, Google Maps URL, and Google Place ID.

Run by GitHub Actions hourly, or manually:
  NOTION_TOKEN=ntn_xxx GOOGLE_PLACES_API_KEY=xxx python3 enrich_places.py
"""

import os
import sys
import time
import requests

NOTION_TOKEN       = os.environ.get("NOTION_TOKEN")
GOOGLE_PLACES_KEY  = os.environ.get("GOOGLE_PLACES_API_KEY")
DATABASE_ID        = "3edc903daeaa41eaa82f93fb0ec55e60"
NOTION_VERSION     = "2022-06-28"

CATEGORY_MAP = {
    "restaurant": "Restaurant",
    "food": "Restaurant",
    "cafe": "Cafe",
    "coffee": "Cafe",
    "bar": "Bar",
    "night_club": "Bar",
    "lodging": "Hotel",
    "hotel": "Hotel",
    "store": "Shop",
    "shopping_mall": "Shop",
    "tourist_attraction": "Attraction",
    "museum": "Attraction",
    "park": "Attraction",
    "point_of_interest": "Attraction",
}


def notion_headers():
    return {
        "Authorization": f"Bearer {NOTION_TOKEN}",
        "Content-Type": "application/json",
        "Notion-Version": NOTION_VERSION,
    }


def fetch_new_places():
    """Fetch all Notion records where Enrichment Status = New."""
    pages = []
    cursor = None
    while True:
        body = {
            "page_size": 100,
            "filter": {
                "property": "Enrichment Status",
                "select": {"equals": "New"}
            }
        }
        if cursor:
            body["start_cursor"] = cursor
        resp = requests.post(
            f"https://api.notion.com/v1/databases/{DATABASE_ID}/query",
            headers=notion_headers(),
            json=body,
        )
        resp.raise_for_status()
        data = resp.json()
        pages.extend(data.get("results", []))
        if not data.get("has_more"):
            break
        cursor = data.get("next_cursor")
        time.sleep(0.3)
    return pages


def get_text(prop):
    if not prop:
        return ""
    items = prop.get("rich_text") or prop.get("title") or []
    return "".join(t.get("plain_text", "") for t in items)


def get_select(prop):
    if not prop:
        return ""
    sel = prop.get("select")
    return sel.get("name", "") if sel else ""


def lookup_place(name, city, country):
    """Search Google Places for the place, return enriched data dict."""
    query = name
    if city:
        query += f" {city}"
    if country:
        query += f" {country}"

    # Text search
    search_resp = requests.get(
        "https://maps.googleapis.com/maps/api/place/findplacefromtext/json",
        params={
            "input": query,
            "inputtype": "textquery",
            "fields": "place_id,name,geometry,formatted_address,types,url",
            "key": GOOGLE_PLACES_KEY,
        }
    )
    search_resp.raise_for_status()
    search_data = search_resp.json()

    candidates = search_data.get("candidates", [])
    if not candidates:
        return None

    candidate = candidates[0]
    place_id = candidate.get("place_id")
    if not place_id:
        return None

    # Get place details
    detail_resp = requests.get(
        "https://maps.googleapis.com/maps/api/place/details/json",
        params={
            "place_id": place_id,
            "fields": "place_id,name,geometry,formatted_address,address_components,types,url",
            "key": GOOGLE_PLACES_KEY,
        }
    )
    detail_resp.raise_for_status()
    detail = detail_resp.json().get("result", {})

    # Extract coordinates
    location = detail.get("geometry", {}).get("location", {})
    lat = location.get("lat")
    lng = location.get("lng")

    # Extract address components
    components = detail.get("address_components", [])
    city_val = ""
    country_val = ""
    neighborhood_val = ""
    for comp in components:
        types = comp.get("types", [])
        if "locality" in types:
            city_val = comp.get("long_name", "")
        elif "country" in types:
            country_val = comp.get("long_name", "")
        elif "neighborhood" in types or "sublocality_level_1" in types:
            neighborhood_val = comp.get("long_name", "")

    # Map Google types to our category
    types = detail.get("types", [])
    category = "Other"
    for t in types:
        if t in CATEGORY_MAP:
            category = CATEGORY_MAP[t]
            break

    return {
        "lat": lat,
        "lng": lng,
        "address": detail.get("formatted_address", ""),
        "city": city_val,
        "country": country_val,
        "neighborhood": neighborhood_val,
        "category": category,
        "google_place_id": place_id,
        "google_maps_url": detail.get("url", ""),
    }


def patch_notion_page(page_id, enriched):
    """PATCH the Notion page with enriched data and set status to Enriched."""
    props = {
        "Enrichment Status": {"select": {"name": "Enriched"}},
    }

    if enriched.get("lat") is not None:
        props["Latitude"] = {"number": enriched["lat"]}
    if enriched.get("lng") is not None:
        props["Longitude"] = {"number": enriched["lng"]}
    if enriched.get("address"):
        props["Address"] = {"rich_text": [{"text": {"content": enriched["address"]}}]}
    if enriched.get("city"):
        props["City"] = {"rich_text": [{"text": {"content": enriched["city"]}}]}
    if enriched.get("country"):
        props["Country"] = {"rich_text": [{"text": {"content": enriched["country"]}}]}
    if enriched.get("neighborhood"):
        props["Neighborhood"] = {"rich_text": [{"text": {"content": enriched["neighborhood"]}}]}
    if enriched.get("category"):
        props["Category"] = {"select": {"name": enriched["category"]}}
    if enriched.get("google_place_id"):
        props["Google Place ID"] = {"rich_text": [{"text": {"content": enriched["google_place_id"]}}]}
    if enriched.get("google_maps_url"):
        props["Google Maps URL"] = {"url": enriched["google_maps_url"]}

    resp = requests.patch(
        f"https://api.notion.com/v1/pages/{page_id}",
        headers=notion_headers(),
        json={"properties": props},
    )
    resp.raise_for_status()


def mark_failed(page_id):
    """Mark a page as Needs Review if enrichment failed."""
    requests.patch(
        f"https://api.notion.com/v1/pages/{page_id}",
        headers=notion_headers(),
        json={"properties": {"Enrichment Status": {"select": {"name": "Needs Review"}}}},
    )


def main():
    if not NOTION_TOKEN:
        print("ERROR: Set NOTION_TOKEN environment variable.")
        sys.exit(1)
    if not GOOGLE_PLACES_KEY:
        print("ERROR: Set GOOGLE_PLACES_API_KEY environment variable.")
        sys.exit(1)

    print("Fetching New records from Notion…")
    pages = fetch_new_places()
    print(f"Found {len(pages)} records to enrich")

    if not pages:
        print("Nothing to do.")
        return

    enriched_count = 0
    failed_count = 0

    for page in pages:
        props = page.get("properties", {})
        name = get_text(props.get("Name", {}))
        city = get_text(props.get("City", {}))
        country = get_text(props.get("Country", {}))
        page_id = page["id"]

        print(f"  Enriching: {name} ({city})")
        try:
            result = lookup_place(name, city, country)
            if result:
                patch_notion_page(page_id, result)
                print(f"    ✓ {result['lat']}, {result['lng']} — {result['city']}, {result['country']}")
                enriched_count += 1
            else:
                print(f"    ✗ No Google Places match found")
                mark_failed(page_id)
                failed_count += 1
        except Exception as e:
            print(f"    ✗ Error: {e}")
            mark_failed(page_id)
            failed_count += 1

        time.sleep(0.5)  # be polite to the API

    print(f"\nDone: {enriched_count} enriched, {failed_count} failed/needs review")


if __name__ == "__main__":
    main()
