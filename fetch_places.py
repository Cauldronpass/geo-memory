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

NOTION_TOKEN  = os.environ.get("NOTION_TOKEN")
DATABASE_ID   = "3edc903daeaa41eaa82f93fb0ec55e60"
NOTION_VERSION = "2022-06-28"
OUT_PATH      = os.path.join(os.path.dirname(__file__), "places.json")


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


def fetch_all_pages():
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


def main():
    if not NOTION_TOKEN:
        print("ERROR: Set NOTION_TOKEN environment variable.")
        sys.exit(1)

    print("Fetching from Notion…")
    pages = fetch_all_pages()
    print(f"Fetched {len(pages)} records")

    places = []
    skipped = 0
    for page in pages:
        props = page.get("properties", {})
        lat = get_number(props.get("Latitude"))
        lng = get_number(props.get("Longitude"))
        if lat is None or lng is None:
            skipped += 1
            continue
        places.append({
            "name":     get_text(props.get("Name", {})),
            "status":   get_select(props.get("Status")),
            "category": get_select(props.get("Category")),
            "city":     get_text(props.get("City", {})),
            "country":  get_text(props.get("Country", {})),
            "lat":      lat,
            "lng":      lng,
            "rating":   get_number(props.get("Rating Personal")),
            "notes":    get_text(props.get("Notes Raw", {})),
            "tags":     get_multi_select(props.get("Tags Raw")),
        })

    with open(OUT_PATH, "w") as f:
        json.dump(places, f, ensure_ascii=False, separators=(",", ":"))

    print(f"Wrote {len(places)} places to places.json  ({skipped} skipped — no coordinates)")


if __name__ == "__main__":
    main()
