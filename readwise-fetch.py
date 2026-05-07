#!/usr/bin/env python3
"""Fetch new Readwise Reader highlights since last sync.

Outputs org-mode formatted highlights to stdout.
Stores last sync timestamp in ~/.config/readwise/last-sync.

Usage: python3 readwise-fetch.py
"""

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError

TOKEN_FILE = os.path.expanduser("~/.config/readwise/token")
SYNC_FILE = os.path.expanduser("~/.config/readwise/last-sync")
API_BASE = "https://readwise.io/api/v3"


def read_token():
    with open(TOKEN_FILE) as f:
        return f.read().strip()


def read_last_sync():
    if os.path.exists(SYNC_FILE):
        with open(SYNC_FILE) as f:
            return f.read().strip()
    return None


def save_last_sync(ts):
    Path(SYNC_FILE).parent.mkdir(parents=True, exist_ok=True)
    with open(SYNC_FILE, "w") as f:
        f.write(ts)


def api_get(token, path):
    req = Request(f"{API_BASE}/{path}")
    req.add_header("Authorization", f"Token {token}")
    with urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


def fetch_highlights(token, since):
    """Fetch highlight documents updated since timestamp."""
    url = f"list/?category=highlight"
    if since:
        url += f"&updatedAfter={since}"
    return api_get(token, url).get("results", [])


def fetch_document(token, doc_id):
    """Fetch a document by ID to get its title and author."""
    data = api_get(token, f"list/?id={doc_id}")
    results = data.get("results", [])
    if results:
        return results[0]
    return None


def main():
    try:
        token = read_token()
    except FileNotFoundError:
        print(f"No token at {TOKEN_FILE}", file=sys.stderr)
        sys.exit(1)

    last_sync = read_last_sync()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        highlights = fetch_highlights(token, last_sync)
    except URLError as e:
        print(f"API error: {e}", file=sys.stderr)
        sys.exit(1)

    if not highlights:
        sys.exit(0)

    # Group highlights by parent document
    by_parent = {}
    for h in highlights:
        pid = h.get("parent_id", "unknown")
        by_parent.setdefault(pid, []).append(h)

    # Resolve parent titles
    parent_info = {}
    for pid in by_parent:
        try:
            doc = fetch_document(token, pid)
            if doc:
                parent_info[pid] = {
                    "title": doc.get("title", "Unknown"),
                    "author": doc.get("author", ""),
                }
        except URLError:
            parent_info[pid] = {"title": "Unknown", "author": ""}

    # Output org-formatted highlights
    for pid, items in by_parent.items():
        info = parent_info.get(pid, {"title": "Unknown", "author": ""})
        title = info["title"]
        author = info["author"]
        header = title
        if author:
            header += f" — {author}"

        print(f"*** {header}")
        print()
        for h in sorted(items, key=lambda x: x.get("updated_at", "")):
            content = (h.get("content") or "").strip()
            note = (h.get("notes") or "").strip()
            if content:
                print("#+begin_quote")
                print(content)
                print("#+end_quote")
                if note:
                    print(f"Note: {note}")
                print()

    # Update sync timestamp
    save_last_sync(now)


if __name__ == "__main__":
    main()
