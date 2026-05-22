#!/usr/bin/env python3
"""
Enrich Notion Geo Memory records where Enrichment Status = New.
Calls Google Places API (New) to fill in lat/lng, address, city, country,
neighborhood, category, Google Maps URL, and Google Place ID.
Calls Claude API to generate a one-sentence AI Summary.

Run by GitHub Actions hourly, or manually:
  NOTION_TOKEN=ntn_xxx GOOGLE_PLACES_API_KEY=xxx ANTHROPIC_API_KEY=xxx python3 enrich_places.py
"""

import os
import sys
import time
import requests

NOTION_TOKEN       = os.environ.get("NOTION_TOKEN")
GOOGLE_PLACES_KEY  = os.environ.get("GOOGLE_PLACES_API_KEY")
ANTHROPIC_API_KEY  = os.environ.get("ANTHROPIC_API_KEY")
DATABASE_ID        = "3edc903daeaa41eaa82f93fb0ec55e60"
NOTION_VERSION     = "2022-06-28"

CATEGORY_MAP = {
    "restaurant": "Restaurant",
    "food": "Restaurant",
    "meal_takeaway": "Restaurant",
    "meal_delivery": "Restaurant",
    "bakery": "Restaurant",
    "cafe": "Cafe",
    "coffee_shop": "Cafe",
    "bar": "Bar",
    "night_club": "Bar",
    "pub": "Bar",
    "brewery": "Bar",
    "wine_bar": "Bar",
    "lodging": "Hotel",
    "hotel": "Hotel",
    "store": "Shop",
    "shopping_mall": "Shop",
    "clothing_store": "Shop",
    "tourist_attraction": "Attraction",
    "museum": "Attraction",
    "park": "Attraction",
    "art_gallery": "Attraction",
    "amusement_park": "Attraction",
    "point_of_interest": "Other",
}

# Priority order — restaurant types take precedence over bar
CATEGORY_PRIORITY = [
    "restaurant", "food", "meal_takeaway", "meal_delivery", "bakery",
    "cafe", "coffee_shop",
    "bar", "night_club", "pub", "brewery", "wine_bar",
    "lodging", "hotel",
    "store", "shopping_mall", "clothing_store",
    "tourist_attraction", "museum", "park", "art_gallery", "amusement_park",
    "point_of_interest",
]

USER_TAGS = [
    "Ice cream", "Mexican", "clothing", "Seafood", "farm-to-kitchen", "bar",
    "restaurant", "music", "Chinese", "coffee", "brunch", "pizza", "Italian",
    "breakfast", "bakery", "BBQ", "Asian", "Sushi", "Burger", "Conference Center",
    "Event", "Candy", "Brewery", "pub", "American", "sandwich", "healthy",
    "art gallery", "tapas", "Park", "steak", "hotel", "spa", "medical", "fun",
    "billiards", "work", "grocery", "pharmacy", "hospital", "electronics",
    "hardware", "auto", "gifts", "shopping", "Mediterranean", "lodging",
]


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
    """Search Google Places (New) for the place, return enriched data dict."""
    query = name
    if city:
        query += f" {city}"
    if country:
        query += f" {country}"

    # Places API (New) — Text Search
    search_resp = requests.post(
        "https://places.googleapis.com/v1/places:searchText",
        headers={
            "Content-Type": "application/json",
            "X-Goog-Api-Key": GOOGLE_PLACES_KEY,
            "X-Goog-FieldMask": "places.id,places.displayName,places.location,places.formattedAddress,places.addressComponents,places.types,places.googleMapsUri,places.nationalPhoneNumber,places.websiteUri,places.priceLevel,places.rating,places.currentOpeningHours",
        },
        json={"textQuery": query, "pageSize": 1},
    )
    search_resp.raise_for_status()
    search_data = search_resp.json()

    places = search_data.get("places", [])
    if not places:
        print(f"    No results returned")
        return None

    place = places[0]
    place_id = place.get("id")
    if not place_id:
        return None

    # Extract coordinates
    location = place.get("location", {})
    lat = location.get("latitude")
    lng = location.get("longitude")

    # Extract address components
    components = place.get("addressComponents", [])
    city_val = ""
    country_val = ""
    neighborhood_val = ""
    for comp in components:
        types = comp.get("types", [])
        if "locality" in types:
            city_val = comp.get("longText", "")
        elif "country" in types:
            country_val = comp.get("longText", "")
        elif "neighborhood" in types or "sublocality_level_1" in types:
            neighborhood_val = comp.get("longText", "")

    # Map Google types to our category — use priority order
    types = place.get("types", [])
    category = "Other"
    for priority_type in CATEGORY_PRIORITY:
        if priority_type in types:
            category = CATEGORY_MAP[priority_type]
            break

    # Build Google Maps URL
    maps_uri = place.get("googleMapsUri", f"https://maps.google.com/?cid={place_id}")

    # Price level — Google returns PRICE_LEVEL_INEXPENSIVE etc, map to 1-4
    price_map = {
        "PRICE_LEVEL_FREE": 0,
        "PRICE_LEVEL_INEXPENSIVE": 1,
        "PRICE_LEVEL_MODERATE": 2,
        "PRICE_LEVEL_EXPENSIVE": 3,
        "PRICE_LEVEL_VERY_EXPENSIVE": 4,
    }
    price_level = price_map.get(place.get("priceLevel", ""), None)

    # Opening hours — format as plain text
    hours_val = ""
    opening_hours = place.get("currentOpeningHours", {})
    weekday_text = opening_hours.get("weekdayDescriptions", [])
    if weekday_text:
        hours_val = "\n".join(weekday_text)

    return {
        "lat": lat,
        "lng": lng,
        "address": place.get("formattedAddress", ""),
        "city": city_val,
        "country": country_val,
        "neighborhood": neighborhood_val,
        "category": category,
        "google_place_id": place_id,
        "google_maps_url": maps_uri,
        "phone": place.get("nationalPhoneNumber", ""),
        "website": place.get("websiteUri", ""),
        "price_level": price_level,
        "rating_external": place.get("rating"),
        "hours": hours_val,
    }


def generate_summary_and_tag(name, category, neighborhood, city, country, address):
    """Call Claude to generate a summary and pick the best tag from USER_TAGS."""
    if not ANTHROPIC_API_KEY:
        return "", ""
    tags_str = ", ".join(USER_TAGS)
    prompt = (
        f"You are enriching a personal place memory database. Given the place below, return JSON with two fields:\n"
        f"1. \"summary\": one sentence describing the place — specific, useful, mention what it's known for. Do not start with the place name.\n"
        f"2. \"tag\": pick the single most relevant tag from this list: {tags_str}\n\n"
        f"Return only valid JSON, nothing else. Example: {{\"summary\": \"...\", \"tag\": \"Italian\"}}\n\n"
        f"Place: {name}\n"
        f"Category: {category}\n"
        f"Neighborhood: {neighborhood}\n"
        f"City: {city}, {country}\n"
        f"Address: {address}"
    )
    try:
        resp = requests.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": ANTHROPIC_API_KEY,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 200,
                "messages": [{"role": "user", "content": prompt}],
            },
        )
        resp.raise_for_status()
        import json as json_lib
        text = resp.json()["content"][0]["text"].strip()
        data = json_lib.loads(text)
        return data.get("summary", ""), data.get("tag", "")
    except Exception as e:
        print(f"    Summary/tag generation failed: {e}")
        return "", ""


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
    if enriched.get("ai_summary"):
        props["AI Summary"] = {"rich_text": [{"text": {"content": enriched["ai_summary"]}}]}
    if enriched.get("phone"):
        props["Phone"] = {"phone_number": enriched["phone"]}
    if enriched.get("website"):
        props["Website"] = {"url": enriched["website"]}
    if enriched.get("price_level") is not None:
        props["Price Level"] = {"number": enriched["price_level"]}
    if enriched.get("rating_external") is not None:
        props["Rating External"] = {"number": enriched["rating_external"]}
    if enriched.get("hours"):
        props["Hours"] = {"rich_text": [{"text": {"content": enriched["hours"]}}]}
    if enriched.get("ai_tag"):
        props["Tags Raw"] = {"multi_select": [{"name": enriched["ai_tag"]}]}

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
                summary, tag = generate_summary_and_tag(
                    name,
                    result.get("category", ""),
                    result.get("neighborhood", ""),
                    result.get("city", ""),
                    result.get("country", ""),
                    result.get("address", ""),
                )
                result["ai_summary"] = summary
                result["ai_tag"] = tag
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
