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

| Binding     | Command                    | Description                    |
|-------------|----------------------------|--------------------------------|
| `C-c W f`   | `hord-find`                | Open card by title (with completion) |
| `C-c W l`   | `hord-list`                | Browse all cards in a list     |
| `C-c W r`   | `hord-suggest-rt`          | Suggest RT links for current card (org-mode) |
| `C-c W c`   | `hord-lookup-cite-at-point`| Look up cite:key at point      |
| `C-c W s`   | `hord-scratch`             | Open today's scratch pad       |
| `C-c W S`   | `hord-scratch-list`        | Browse scratch files           |

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
| `+text`  | Directory            | `+capture` `+content`            |
| `text`   | Title (or citekey with `@cite`) | `braudel economic`     |

Examples: `@per alexander`, `@cite mann:2018`, `+capture @con`, `@wrk #scott`

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

### Scratch pad

`C-c W s` opens a daily scratch file (`YYYY-MM-DD.org`) for working
notes.  On first open each day, pending items from the Orgzly inbox
(synced via Syncthing) are automatically imported under a "Mobile
inbox" heading.

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
