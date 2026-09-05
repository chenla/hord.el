;; MELPA Recipe for hord.el
;;
;; To submit: fork https://github.com/melpa/melpa, add this as
;; recipes/hord, then open a PR.
;;
;; File should be named just "hord" (no extension) in the recipes/ dir.
;; Content below (without this comment block):

(hord :fetcher github :repo "chenla/hord.el")

;; PR title: "Add hord"
;;
;; PR body template:
;;
;;   **Description:** Emacs major mode for browsing and navigating
;;   Hoard knowledge graphs — semantic metadata overlays for git repos.
;;
;;   **Upstream:** https://github.com/chenla/hord.el
;;   **Homepage:** https://github.com/chenla/hord.el
;;
;;   Features: card browser with typed relations, live filtering (18
;;   filter types), agenda view (merged hord tasks + Google Calendar),
;;   triage workflow, blob management, Readwise integration.
;;
;;   Requires: Emacs 28.1+, compiled hord (via the `hoard-git` Python
;;   package: `pipx install hoard-git`).
;;
;; Checklist before submitting:
;;   [ ] Package lints clean: M-x package-lint-current-buffer
;;   [ ] Byte-compiles without warnings
;;   [ ] Header conventions correct (already verified)
;;   [ ] README exists (yes)
;;   [ ] License in header (MIT, line 4)
