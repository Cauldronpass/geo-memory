#!/usr/bin/env python3
"""
Fetch all places from Notion and write places.json for the Geo Memory map.
Run by GitHub Actions nightly, or manually:
  NOTION_TOKEN=secret_xxx python3 fetch_places.py
"""

import json
import os
import sys
import time
import requests

NOTION_TOKEN       = os.environ.get("NOTION_TOKEN")
DATABASE_ID        = "3edc903daeaa41eaa82f93fb0ec55e60"
VISITS_DATABASE_ID = "ecd8cdc617e74c78b090afc5092cbdee"
NOTION_VERSION     = "2022-06-28"
OUT_PATH           = os.path.join(os.path.dirname(__file__), "places.json")


def headers():
    return {
        "Authorization": f"Bearer {NOTION_TOKEN}",
        "Content-Type": "application/json",
        "Notion-Version": NOTION_VERSION,
    }


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


def get_number(prop):
    if not prop:
        return None
    return prop.get("number")


def get_multi_select(prop):
    if not prop:
        return []
    return [o.get("name", "") for o in prop.get("multi_select", [])]


def get_phone(prop):
    if not prop:
        return ""
    return prop.get("phone_number") or ""


def get_url(prop):
    if not prop:
        return ""
    return prop.get("url") or ""
def get_checkbox(prop):
    if not prop:
        return False
    return bool(prop.get("checkbox", False))


def get_rollup_number(prop):
    """Extract a count/number from a Notion rollup property."""
    if not prop:
        return None
    rollup = prop.get("rollup", {})
    return rollup.get("number")


def get_rollup_date(prop):
    """Extract the start date string from a Notion rollup date property."""
    if not prop:
        return None
    rollup = prop.get("rollup", {})
    date_val = rollup.get("date")
    if date_val:
        raw = date_val.get("start", "")
        # Return just YYYY-MM (e.g. "May 2026" displayed in UI)
        return raw[:7] if raw else None
    return None


def fetch_all_pages():
    """Fetch all places from the Places database."""
    pages = []
    cursor = None
    while True:
        body = {"page_size": 100}
        if cursor:
            body["start_cursor"] = cursor
        resp = requests.post(
            f"https://api.notion.com/v1/databases/{DATABASE_ID}/query",
            headers=headers(),
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


def fetch_all_visits():
    """Fetch all Visit records sorted by date desc."""
    visits = []
    cursor = None
    while True:
        body = {
            "page_size": 100,
            "sorts": [{"property": "Date Visited", "direction": "descending"}],
        }
        if cursor:
            body["start_cursor"] = cursor
        resp = requests.post(
            f"https://api.notion.com/v1/databases/{VISITS_DATABASE_ID}/query",
            headers=headers(),
            json=body,
        )
        resp.raise_for_status()
        data = resp.json()
        visits.extend(data.get("results", []))
        if not data.get("has_more"):
            break
        cursor = data.get("next_cursor")
        time.sleep(0.3)
    return visits


def build_last_visit_map(visits):
    """Return dict: notion_id (no dashes) → last visit snapshot.
    Assumes visits are sorted descending by date — first hit per place wins."""
    seen = {}
    for visit in visits:
        props = visit.get("properties", {})
        place_rel = props.get("Place", {}).get("relation", [])
        if not place_rel:
            continue
        place_id = place_rel[0].get("id", "").replace("-", "")
        if place_id in seen:
            continue  # already captured the most recent

        date_prop = props.get("Date Visited", {})
        date_val = ""
        if date_prop and date_prop.get("date"):
            date_val = date_prop["date"].get("start", "")

        rating_sel = props.get("Rating", {}).get("select")
        sentiment = rating_sel.get("name", "") if rating_sel else ""

        occasion_sel = props.get("Occasion", {}).get("select")
        occasion = occasion_sel.get("name", "") if occasion_sel else ""

        notes_items = props.get("Notes", {}).get("rich_text", [])
        notes = "".join(t.get("plain_text", "") for t in notes_items)

        seen[place_id] = {
            "last_visit_date":      date_val,
            "last_visit_sentiment": sentiment,
            "last_visit_occasion":  occasion,
            "last_visit_notes":     notes,
        }
    return seen


def main():
    if not NOTION_TOKEN:
        print("ERROR: Set NOTION_TOKEN environment variable.")
        sys.exit(1)

    print("Fetching places from Notion…")
    pages = fetch_all_pages()
    print(f"Fetched {len(pages)} place records")

    places = []
    skipped = 0
    for page in pages:
        props = page.get("properties", {})
        lat = get_number(props.get("Latitude"))
        lng = get_number(props.get("Longitude"))
        if lat is None or lng is None:
            skipped += 1
            continue
        notion_id = page.get("id", "").replace("-", "")
        places.append({
            "name":            get_text(props.get("Name", {})),
            "status":          get_select(props.get("Status")),
            "category":        get_select(props.get("Category")),
            "city":            get_text(props.get("City", {})),
            "country":         get_text(props.get("Country", {})),
            "lat":             lat,
            "lng":             lng,
            "rating":          get_number(props.get("Rating Personal")),
            "notes":           get_text(props.get("Notes Raw", {})),
            "tags":            get_multi_select(props.get("Tags Raw")),
            "notion_id":       notion_id,
            "google_place_id": get_text(props.get("Google Place ID", {})),
            "ai_summary":      get_text(props.get("AI Summary", {})),
            # Rollup fields
            "visit_count":     get_rollup_number(props.get("Visit Count")),
            "last_visited":    get_rollup_date(props.get("Last Visited")),
            # Google enrichment fields
            "phone":           get_phone(props.get("Phone")),
            "website":         get_url(props.get("Website")),
            "hours":           get_text(props.get("Hours", {})),
            "price_level":     get_number(props.get("Price Level")),
            "rating_external": get_number(props.get("Rating External")),
          "flagged":         get_checkbox(props.get("Flagged")),
            # Last visit snapshot — populated below if visits exist
            "last_visit_date":      "",
            "last_visit_sentiment": "",
            "last_visit_occasion":  "",
            "last_visit_notes":     "",
        })

    # Only query the Visits DB if at least one place has visits
    visited_places = [p for p in places if p.get("visit_count")]
    if visited_places:
        print(f"Fetching visit snapshots ({len(visited_places)} places with visits)…")
        visits = fetch_all_visits()
        print(f"Fetched {len(visits)} visit records")
        last_visit_map = build_last_visit_map(visits)
        for place in places:
            snap = last_visit_map.get(place["notion_id"], {})
            if snap:
                place["last_visit_date"]      = snap.get("last_visit_date", "")
                place["last_visit_sentiment"] = snap.get("last_visit_sentiment", "")
                place["last_visit_occasion"]  = snap.get("last_visit_occasion", "")
                place["last_visit_notes"]     = snap.get("last_visit_notes", "")
    else:
        print("No visited places — skipping Visits DB fetch")

    with open(OUT_PATH, "w") as f:
        json.dump(places, f, ensure_ascii=False, separators=(",", ":"))

    print(f"Wrote {len(places)} places to places.json  ({skipped} skipped — no coordinates)")


if __name__ == "__main__":
    main()
