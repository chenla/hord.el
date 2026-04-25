# hord.el

Emacs major mode for browsing and navigating [Hoard](https://github.com/chenla/hoard) knowledge graphs.

## Setup

```elisp
(add-to-list 'load-path "~/proj/hord.el/")
(require 'hord)

;; Point to your hord (default: ~/proj/hord/)
(setq hord-root "~/proj/hord/")
```

Requires a compiled hord — run `hord compile` first.

## Usage

| Binding     | Command           | Description                    |
|-------------|-------------------|--------------------------------|
| `C-c W f`   | `hord-find`       | Open card by title (with completion) |
| `C-c W l`   | `hord-list`       | Browse all cards in a list     |

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
| `s`         | Search by title                 |
| `t`         | Filter by type                  |
| `?`         | Show keybindings                |
| `q`         | Quit                            |

## Requirements

- Emacs 28.1+
- A compiled hord (`.hord/index.tsv` and `.hord/quads/`)

## License

MIT
