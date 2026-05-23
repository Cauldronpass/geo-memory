"""
create_visits_db.py
-------------------
Creates the Notion "Visits" relational database under the same parent page
as the existing Places database.

Run once:
    NOTION_TOKEN=secret_xxx python3 create_visits_db.py

After running, copy the printed VISITS_DATABASE_ID into:
  - save-place-worker.js  (as VISITS_DATABASE_ID const)
  - Your Cloudflare Worker secrets

Then add these rollup properties MANUALLY in Notion on the Places database:
  - "Visit Count"   → rollup of Visits relation → Count all
  - "Last Visited"  → rollup of Visits relation → Date Visited → Latest date
"""

import os
import sys
import json
import requests

NOTION_TOKEN   = os.environ.get("NOTION_TOKEN", "")
NOTION_VERSION = "2022-06-28"
PLACES_DB_ID   = "3edc903daeaa41eaa82f93fb0ec55e60"

HEADERS = {
    "Authorization":  f"Bearer {NOTION_TOKEN}",
    "Content-Type":   "application/json",
    "Notion-Version": NOTION_VERSION,
}


def get_places_parent():
    """Return the parent object of the Places database."""
    r = requests.get(
        f"https://api.notion.com/v1/databases/{PLACES_DB_ID}",
        headers=HEADERS,
    )
    r.raise_for_status()
    db = r.json()
    return db["parent"]  # e.g. {"type": "page_id", "page_id": "..."}


def create_visits_database(parent):
    payload = {
        "parent": parent,
        "title": [{"type": "text", "text": {"content": "Visits"}}],
        "properties": {
            # Title — auto-set to "Visit - Place Name - YYYY-MM-DD"
            "Name": {
                "title": {}
            },
            # Relation back to Places
            "Place": {
                "relation": {
                    "database_id": PLACES_DB_ID,
                    "single_property": {}
                }
            },
            # Date of the visit
            "Date Visited": {
                "date": {}
            },
            # Occasion
            "Occasion": {
                "select": {
                    "options": [
                        {"name": "Solo",         "color": "blue"},
                        {"name": "Date/Partner", "color": "pink"},
                        {"name": "Friends",      "color": "green"},
                        {"name": "Family",       "color": "orange"},
                        {"name": "Client/Work",  "color": "purple"},
                    ]
                }
            },
            # Thumbs up / down sentiment
            "Sentiment": {
                "select": {
                    "options": [
                        {"name": "Good", "color": "green"},
                        {"name": "Bad",  "color": "red"},
                    ]
                }
            },
            # Free-form notes for this specific visit
            "Notes": {
                "rich_text": {}
            },
        },
    }

    r = requests.post(
        "https://api.notion.com/v1/databases",
        headers=HEADERS,
        json=payload,
    )
    if r.status_code != 200:
        print("ERROR creating database:")
        print(json.dumps(r.json(), indent=2))
        sys.exit(1)

    return r.json()


def main():
    if not NOTION_TOKEN:
        print("ERROR: NOTION_TOKEN environment variable is not set.")
        sys.exit(1)

    print("Fetching Places database parent…")
    parent = get_places_parent()
    print(f"  Parent: {parent}")

    print("Creating Visits database…")
    db = create_visits_database(parent)
    db_id = db["id"]

    print()
    print("=" * 60)
    print("SUCCESS — Visits database created!")
    print(f"  VISITS_DATABASE_ID = {db_id}")
    print("=" * 60)
    print()
    print("Next steps:")
    print("1. Copy the ID above into save-place-worker.js as VISITS_DATABASE_ID")
    print("2. Add VISITS_DATABASE_ID as a Cloudflare Worker secret (or env var)")
    print("3. In Notion → Places database, add two Rollup properties manually:")
    print("   - 'Visit Count'  → relation: Visits → Count all")
    print("   - 'Last Visited' → relation: Visits → Date Visited → Latest date")


if __name__ == "__main__":
    main()
