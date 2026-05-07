# hord.el

Emacs major mode for browsing and navigating [Hoard](https://github.com/chenla/hoard) knowledge graphs.

## Setup

```elisp
(add-to-list 'load-path "~/proj/hord.el/")
(require 'hord)

;; Point to your hord (default: ~/proj/hord/)
(setq hord-root "~/proj/hord/")

;; External viewers for media files (optional — these are the defaults)
(setq hord-external-viewers
  '(("pdf"  . "okular")
    ("epub" . "xdg-open")
    ("djvu" . "djview")
    ("mobi" . "xdg-open")))
```

Requires a compiled hord — run `hord compile` first.

## Usage

### Global commands

| Binding     | Command                    | Description                    |
|-------------|----------------------------|--------------------------------|
| `C-c W f`   | `hord-find`                | Open card by title (with completion) |
| `C-c W l`   | `hord-list`                | Browse all cards in a list     |
| `C-c W r`   | `hord-suggest-rt`          | Suggest RT links for current card (org-mode) |
| `C-c W c`   | `hord-lookup-cite-at-point`| Look up cite:key at point      |
| `C-c W a`   | `hord-add-blob`            | Add file to blob store (prompts for citekey) |
| `C-c W L`   | `hord-link-add`            | Add thesaurus relation (BT/NT/RT/TT/UF/PT) |
| `C-c W s`   | `hord-scratch`             | Open today's scratch pad       |
| `C-c W S`   | `hord-scratch-list`        | Browse scratch files           |
| `C-c W A`   | `hord-agenda`              | Context-aware agenda view      |
| `C-c W t`   | `hord-triage-to-task`      | Create hord task card from heading at point |
| `C-c W T`   | `hord-triage-to-gtask`     | Create Google Task from heading at point |

### Card view

| Key         | Action                          |
|-------------|---------------------------------|
| `RET`       | Follow link under point         |
| `TAB`       | Jump to next link               |
| `S-TAB`     | Jump to previous link           |
| `b`         | Back (history)                  |
| `e`         | Edit underlying org file (split window) |
| `g`         | Refresh card view               |
| `s`         | Search by title                 |
| `t`         | Filter by type                  |
| `l`         | List all cards                  |
| `?`         | Show keybindings                |
| `q`         | Quit                            |

### List view

| Key         | Action                          |
|-------------|---------------------------------|
| `RET`       | Open card                       |
| `s`         | Live filter (updates as you type) |
| `S`         | Set filter (apply on enter)     |
| `c`         | Clear filter                    |
| `t`         | Filter by type                  |
| `g`         | Refresh (reload from disk)      |
| `?`         | Show keybindings                |
| `q`         | Quit                            |

### Filter syntax

Filter tokens are space-separated and ANDed together:

| Prefix   | Matches              | Example                          |
|----------|----------------------|----------------------------------|
| `@type`  | Card type            | `@con` concepts, `@wrk` works    |
| `@cite`  | Switch to citekey mode | `@cite mann` citekeys matching "mann" |
| `#text`  | Author               | `#alexander` `#braudel`          |
| `~tag`   | Tag                  | `~tps` `~hoard`                  |
| `%name`  | Persona              | `%researcher` `%musician`        |
| `!level` | Priority             | `!high` `!medium` `!low`         |
| `*`      | Relevant only        | cards marked relevant in any persona |
| `=status`| Task status          | `=todo` `=done` `=waiting`       |
| `/range` | Time range           | `/today` `/week` `/month` `/overdue` |
| `+text`  | Directory            | `+capture` `+content`            |
| `text`   | Title (or citekey with `@cite`) | `braudel economic`     |

Examples: `@per alexander`, `@cite mann:2018`, `+capture @con`, `@wrk #scott`,
`%researcher !high`, `~tps @con`, `* %researcher`,
`=todo /week`, `@task =todo %researcher /month`

### Blob store

`C-c W a` adds a file (PDF, EPUB, etc.) to `lib/blob/` and creates a
`wh:wrk` card for it.  Prompts for the file path and a citekey
(`author:yearslug`).  The file is copied to the blob store and a card
is created with the citekey as its identifier.

### Thesaurus relations

`C-c W L` adds a relation to the current card.  Prompts for relation
type (BT, NT, RT, TT, UF, PT) and target:

| Type | Meaning              | Target           |
|------|----------------------|------------------|
| BT   | Broader Term         | Card (by title)  |
| NT   | Narrower Term        | Card (by title)  |
| RT   | Related Term         | Card (by title)  |
| TT   | Top Term             | Card (by title)  |
| UF   | Used For (alias)     | Text string      |
| PT   | Preferred Term       | Text string      |

Relations are written into the card's `** Relations` section and
compiled into the quad store.

### Citation links

`cite:key` references in card bodies and references sections are
clickable links in the hord reader.  Clicking a cite link looks up:

- A word-hord card whose `CITEKEY` property matches the key
- Media files (pdf, epub, djvu, etc.) in `lib/blob/` whose filename
  starts with the key

If both a card and media files exist, a completing-read menu lets you
choose.  Use `C-c W c` to do the same lookup from any buffer
(org-mode, etc.) with point on a `cite:key` reference.

### External viewers

Media files from `lib/blob/` are opened using external applications
configured in `hord-external-viewers`.  Files whose extension is not
in the list (e.g. `.md`, `.org`, `.txt`) open in Emacs.

### Agenda view

`C-c W A` opens a combined agenda showing hord task cards and
Google Calendar events.  Calendar events are fetched via
`gcal-fetch.py` (cached for 5 minutes).

| Key         | Action                          |
|-------------|---------------------------------|
| `RET`       | Open item (card or calendar event) |
| `e`         | Edit item                       |
| `d`         | Mark done                       |
| `g`         | Refresh                         |
| `v`         | View full card                  |
| `w`         | Week view                       |
| `m`         | Month view                      |
| `f`         | Filter by text                  |
| `/`         | Toggle show all (include done/waiting/delegated) |
| `q`         | Quit                            |

The agenda merges two sources:
- **Hord cards** with `SCHEDULED` or `DEADLINE` dates
- **Google Calendar** events (holidays, flights, appointments)

Items are colour-coded: overdue (red), today (green), upcoming (default).

### Triage

From a scratch buffer, position point on a heading and use:

| Binding     | Action                          |
|-------------|---------------------------------|
| `C-c W t`   | Create a hord task card (prompts for due date and status) |
| `C-c W T`   | Create a Google Task (prompts for due date) |

`C-c W t` creates a `wh:cap` card in `capture/` with task metadata
(status, due date) and compiles it into the quad store so it appears
in the agenda.

`C-c W T` creates the task directly in Google Tasks via the
gtasks-mcp API.

### Scratch pad

`C-c W s` opens a daily scratch file (`YYYY-MM-DD.org`) for working
notes.  On first open each day, two automatic imports run:

1. **Orgzly inbox** — pending items from mobile (synced via
   Syncthing) are imported under a "Mobile inbox" heading
2. **Readwise highlights** — new highlights since last sync are
   appended under a "Readwise highlights" heading

From a scratch buffer:

| Key         | Action                          |
|-------------|---------------------------------|
| `C-c C-t`   | Move subtree to tomorrow's scratch file |

Customizable paths:

```elisp
(setq hord-scratch-directory "~/proj/ybr/bench/scratch/")
(setq hord-scratch-inbox-file "~/proj/org/gtd/inbox.org")
```

## Requirements

- Emacs 28.1+
- A compiled hord (`.hord/index.tsv` and `.hord/quads/`)

## License

MIT
