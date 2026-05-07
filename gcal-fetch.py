#!/usr/bin/env python3
"""Fetch Google Calendar events for hord-agenda display.

Outputs tab-separated lines to stdout:
  DATE\tTIME\tSUMMARY\tCALENDAR

Requires the same OAuth credentials as gtasks-mcp.

Usage: python3 gcal-fetch.py [days]
  days: number of days ahead to fetch (default: 7)
"""

import json
import os
import sys
from datetime import datetime, timezone, timedelta
from urllib.request import Request, urlopen
from urllib.error import URLError

CREDS_FILE = os.path.expanduser("~/proj/gtasks-mcp/.chenla-credentials.json")
OAUTH_FILE = os.path.expanduser("~/proj/gtasks-mcp/chenla-oauth.keys.json")

# Calendars to fetch from
CALENDARS = [
    ("brad@chenla.la", "personal"),
    ("en.hong_kong#holiday@group.v.calendar.google.com", "HK holiday"),
    ("en.japanese#holiday@group.v.calendar.google.com", "JP holiday"),
    ("en.kh#holiday@group.v.calendar.google.com", "KH holiday"),
    ("en.usa#holiday@group.v.calendar.google.com", "US holiday"),
    ("ht3jlfaac5lfd6263ulfh4tql8@group.calendar.google.com", "Moon"),
]


def get_access_token():
    """Get a valid access token, refreshing if needed."""
    with open(CREDS_FILE) as f:
        creds = json.load(f)

    expiry = creds.get("expiry_date", 0)
    now_ms = datetime.now(timezone.utc).timestamp() * 1000

    if now_ms < (expiry - 60000):
        return creds["access_token"]

    # Refresh
    with open(OAUTH_FILE) as f:
        keys = json.load(f)
    installed = keys.get("installed", keys.get("web", {}))
    client_id = installed["client_id"]
    client_secret = installed["client_secret"]
    refresh_token = creds["refresh_token"]

    data = (
        f"client_id={client_id}&client_secret={client_secret}"
        f"&refresh_token={refresh_token}&grant_type=refresh_token"
    ).encode()

    req = Request("https://oauth2.googleapis.com/token", data=data)
    req.add_header("Content-Type", "application/x-www-form-urlencoded")

    with urlopen(req, timeout=15) as resp:
        result = json.loads(resp.read())

    creds["access_token"] = result["access_token"]
    creds["expiry_date"] = now_ms + (result["expires_in"] * 1000)

    with open(CREDS_FILE, "w") as f:
        json.dump(creds, f)

    return result["access_token"]


def fetch_events(token, calendar_id, start, end, event_types=None):
    """Fetch events from a single calendar.
    event_types: list of types to fetch (makes one request per type).
    Defaults to ['default']."""
    from urllib.parse import quote

    if event_types is None:
        event_types = ["default"]

    seen_ids = set()
    all_items = []
    for etype in event_types:
        url = (
            f"https://www.googleapis.com/calendar/v3/calendars/"
            f"{quote(calendar_id, safe='')}/events"
            f"?timeMin={start}&timeMax={end}"
            f"&singleEvents=true&orderBy=startTime&maxResults=100"
            f"&eventType={etype}"
        )

        req = Request(url)
        req.add_header("Authorization", f"Bearer {token}")

        try:
            with urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
                for item in data.get("items", []):
                    eid = item.get("id")
                    if eid not in seen_ids:
                        seen_ids.add(eid)
                        all_items.append(item)
        except URLError:
            pass

    return all_items


def parse_event_date(event):
    """Extract date and time from an event."""
    start = event.get("start", {})

    if "dateTime" in start:
        # Timed event
        dt_str = start["dateTime"]
        # Parse ISO format, handle timezone offset
        if "+" in dt_str[10:] or dt_str.endswith("Z"):
            # Has timezone info
            dt_str_clean = dt_str.replace("Z", "+00:00")
            # Simple parse - just get date and time
            date = dt_str[:10]
            time = dt_str[11:16]
        else:
            date = dt_str[:10]
            time = dt_str[11:16]
        return date, time
    elif "date" in start:
        # All-day event
        date_str = start["date"]
        if "T" in date_str:
            date_str = date_str[:10]
        return date_str, "all-day"

    return None, None


def main():
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 7

    now = datetime.now(timezone.utc)
    start = now.strftime("%Y-%m-%dT00:00:00Z")
    end = (now + timedelta(days=days)).strftime("%Y-%m-%dT23:59:59Z")

    try:
        token = get_access_token()
    except Exception as e:
        print(f"Auth error: {e}", file=sys.stderr)
        sys.exit(1)

    events = []
    for cal_id, cal_label in CALENDARS:
        etypes = ["default", "fromGmail"] if cal_id == "brad@chenla.la" else None
        for event in fetch_events(token, cal_id, start, end, event_types=etypes):
            date, time = parse_event_date(event)
            if date:
                summary = event.get("summary", "(no title)")
                events.append((date, time, summary, cal_label))

    # Sort by date, then time
    events.sort(key=lambda e: (e[0], e[1] if e[1] != "all-day" else "00:00"))

    for date, time, summary, cal in events:
        print(f"{date}\t{time}\t{summary}\t{cal}")


if __name__ == "__main__":
    main()
