;;; hord.el --- Browse and navigate Hoard knowledge graphs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ford Collins
;; Author: Ford Collins <brad@chenla.la>
;; URL: https://github.com/chenla/hord.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: outlines, hypermedia, knowledge

;; This file is not part of GNU Emacs.

;; MIT License

;;; Commentary:

;; hord.el provides a read-only browser for Hoard knowledge graphs.
;; It reads the compiled quad store (.hord/quads/) and index
;; (.hord/index.tsv) to render navigable card views with clickable
;; relations and incoming link discovery.
;;
;; Main entry points:
;;   M-x hord-find    — open a card by title (completing-read)
;;   M-x hord-list    — browse all cards in a tabulated list
;;
;; In card view:
;;   RET   — follow link under point
;;   b     — back (history)
;;   e     — edit underlying org file
;;   l     — list all cards
;;   s     — search by title
;;   t     — filter by type
;;   g     — refresh current card
;;   q     — quit

;;; Code:

(require 'cl-lib)
(require 'seq)

;; ── Customization ─────────────────────────────────────────

(defgroup hord nil
  "Browse and navigate Hoard knowledge graphs."
  :group 'outlines
  :prefix "hord-")

(defcustom hord-root "~/proj/hord/"
  "Root directory of the hord."
  :type 'directory
  :group 'hord)

(defcustom hord-external-viewers
  '(("pdf"  . "okular")
    ("epub" . "xdg-open")
    ("djvu" . "djview")
    ("mobi" . "xdg-open"))
  "Alist mapping file extensions to external viewer commands.
Each entry is (EXTENSION . COMMAND).  The file path is passed as
the first argument to COMMAND.  Extensions not listed here are
opened in Emacs (e.g. md, org, txt)."
  :type '(alist :key-type string :value-type string)
  :group 'hord)

(defcustom hord-type-labels
  '(("wh:con" . "Concept")
    ("wh:pat" . "Pattern")
    ("wh:key" . "Keystone")
    ("wh:wrk" . "Work")
    ("wh:per" . "Person")
    ("wh:cat" . "Category")
    ("wh:sys" . "System")
    ("wh:pla" . "Place")
    ("wh:evt" . "Event")
    ("wh:obj" . "Object")
    ("wh:org" . "Organization")
    ("wh:cap" . "Capture"))
  "Mapping from vocab type IDs to human-readable labels."
  :type '(alist :key-type string :value-type string)
  :group 'hord)

(defcustom hord-relation-labels
  '(("v:tt"   . "TT")
    ("v:pt"   . "PT")
    ("v:bt"   . "BT")
    ("v:btg"  . "BTG")
    ("v:bti"  . "BTI")
    ("v:btp"  . "BTP")
    ("v:nt"   . "NT")
    ("v:ntg"  . "NTG")
    ("v:nti"  . "NTI")
    ("v:ntp"  . "NTP")
    ("v:rt"   . "RT")
    ("v:uf"   . "UF")
    ("v:use"  . "USE")
    ("v:s-wo" . "WO")
    ("v:s-eo" . "EO")
    ("v:s-mo" . "MO")
    ("v:s-io" . "IO"))
  "Mapping from vocab predicate IDs to display labels."
  :type '(alist :key-type string :value-type string)
  :group 'hord)

;; ── Faces ─────────────────────────────────────────────────

(defface hord-title
  '((t :inherit info-title-1 :weight bold))
  "Face for card titles in hord view."
  :group 'hord)

(defface hord-section-header
  '((t :inherit info-title-3 :weight bold))
  "Face for section headers (Relations, Incoming, Notes)."
  :group 'hord)

(defface hord-metadata-key
  '((t :inherit font-lock-keyword-face))
  "Face for metadata labels."
  :group 'hord)

(defface hord-metadata-value
  '((t :inherit font-lock-string-face))
  "Face for metadata values."
  :group 'hord)

(defface hord-link
  '((t :inherit link))
  "Face for clickable links."
  :group 'hord)

(defface hord-relation-type
  '((t :inherit font-lock-type-face :weight bold))
  "Face for relation type labels (BT, RT, etc.)."
  :group 'hord)

(defface hord-incoming-source
  '((t :inherit font-lock-comment-face))
  "Face for incoming link source indicator."
  :group 'hord)

(defface hord-cite-link
  '((t :inherit font-lock-constant-face :underline t))
  "Face for cite:key references that resolve to a card or blob."
  :group 'hord)

(defface hord-cite-link-unresolved
  '((t :inherit font-lock-comment-face))
  "Face for cite:key references with no matching card or blob."
  :group 'hord)

;; ── Data structures ───────────────────────────────────────

(cl-defstruct hord-quad
  "A single quad from the store."
  subject predicate object context)

(cl-defstruct hord-entity
  "An entity assembled from quads."
  uuid title type filepath quads)

;; ── Data layer ────────────────────────────────────────────

(defvar hord--index nil "Hash table: UUID → relative path.")
(defvar hord--index-reverse nil "Hash table: relative path → UUID.")
(defvar hord--titles nil "Hash table: UUID → title.")
(defvar hord--types nil "Hash table: UUID → type.")
(defvar hord--quads nil "Hash table: UUID → list of quads.")
(defvar hord--authors nil "Hash table: UUID → author string.")
(defvar hord--incoming nil "Hash table: UUID → list of (predicate . source-uuid).")
(defvar hord--citekeys nil "Hash table: citekey → UUID.")
(defvar hord--citekeys-reverse nil "Hash table: UUID → citekey.")
(defvar hord--loaded-root nil "Root that was last loaded.")

(defun hord--ensure-loaded ()
  "Load index and quads if not already loaded for current `hord-root'."
  (let ((root (expand-file-name hord-root)))
    (unless (and hord--loaded-root
                 (string= hord--loaded-root root))
      (hord--load root))))

(defun hord--load (root)
  "Load the hord at ROOT into memory."
  (message "Loading hord from %s..." root)
  (let ((index-file (expand-file-name ".hord/index.tsv" root))
        (quads-dir (expand-file-name ".hord/quads/" root)))
    (unless (file-exists-p index-file)
      (error "No compiled hord at %s — run `hord compile' first" root))
    ;; Initialize tables
    (setq hord--index (make-hash-table :test 'equal)
          hord--index-reverse (make-hash-table :test 'equal)
          hord--titles (make-hash-table :test 'equal)
          hord--types (make-hash-table :test 'equal)
          hord--authors (make-hash-table :test 'equal)
          hord--quads (make-hash-table :test 'equal)
          hord--incoming (make-hash-table :test 'equal))
    ;; Load index
    (with-temp-buffer
      (insert-file-contents index-file)
      (forward-line 1) ; skip header
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (when (string-match "\\(.+\\)\t\\(.+\\)" line)
            (let ((path (match-string 1 line))
                  (uuid (match-string 2 line)))
              (puthash uuid path hord--index)
              (puthash path uuid hord--index-reverse))))
        (forward-line 1)))
    ;; Load all quad files
    (hord--load-quads quads-dir)
    ;; Build citekey index
    (hord--build-citekey-index root)
    (setq hord--loaded-root root)
    (message "Loaded hord: %d entities, %d citekeys"
             (hash-table-count hord--index)
             (hash-table-count hord--citekeys))))

(defun hord--load-quads (quads-dir)
  "Load all quad files from QUADS-DIR."
  (dolist (shard-dir (directory-files quads-dir t "^[0-9a-f]"))
    (when (file-directory-p shard-dir)
      (dolist (quad-file (directory-files shard-dir t "\\.tsv$"))
        (hord--load-quad-file quad-file)))))

(defun hord--load-quad-file (filepath)
  "Load quads from a single TSV FILEPATH."
  (with-temp-buffer
    (insert-file-contents filepath)
    (forward-line 1) ; skip header
    (let (uuid quads)
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (when (string-match "\\([^\t]+\\)\t\\([^\t]+\\)\t\\([^\t]+\\)\t\\([^\t]*\\)" line)
            (let ((s (match-string 1 line))
                  (p (match-string 2 line))
                  (o (match-string 3 line))
                  (c (match-string 4 line)))
              (setq uuid s)
              (push (make-hord-quad :subject s :predicate p :object o :context c) quads)
              ;; Index title and type
              (cond
               ((string= p "v:title")
                ;; Collapse multiline whitespace from bib imports
                (puthash s (replace-regexp-in-string "[\n\t ]+" " " o) hord--titles))
               ((string= p "v:type") (puthash s o hord--types))
               ((string= p "v:author") (puthash s o hord--authors)))
              ;; Build incoming links index (skip PT, title, type)
              (when (and (not (string= p "v:pt"))
                         (not (string= p "v:title"))
                         (not (string= p "v:type"))
                         (not (string= p "v:uf"))
                         ;; Object looks like a UUID
                         (string-match-p "^[0-9a-f]\\{8\\}-" o))
                (push (cons p s)
                      (gethash o hord--incoming nil))))))
        (forward-line 1))
      (when uuid
        (puthash uuid (nreverse quads) hord--quads)))))

(defun hord--build-citekey-index (root)
  "Build citekey → UUID index by scanning org files for :CITEKEY: properties."
  (setq hord--citekeys (make-hash-table :test 'equal))
  (setq hord--citekeys-reverse (make-hash-table :test 'equal))
  (let* ((default-directory root)
         (output (shell-command-to-string
                  "grep -r --include='*.org' ':CITEKEY:' content/ capture/ 2>/dev/null")))
    (dolist (line (split-string output "\n" t))
      (when (string-match "^\\(.+\\.org\\):\\s-*:CITEKEY:\\s-+\\(.+\\)" line)
        (let* ((filepath (match-string 1 line))
               (citekey (string-trim (match-string 2 line)))
               (uuid (gethash filepath hord--index-reverse)))
          (when uuid
            (puthash citekey uuid hord--citekeys)
            (puthash uuid citekey hord--citekeys-reverse)))))))

(defun hord--entity (uuid)
  "Build a `hord-entity' for UUID."
  (hord--ensure-loaded)
  (let ((path (gethash uuid hord--index)))
    (make-hord-entity
     :uuid uuid
     :title (or (gethash uuid hord--titles) "(untitled)")
     :type (or (gethash uuid hord--types) "unknown")
     :filepath (when path
                 (expand-file-name path (expand-file-name hord-root)))
     :quads (gethash uuid hord--quads))))

(defun hord--all-entities ()
  "Return a list of (uuid title type) for all entities."
  (hord--ensure-loaded)
  (let (result)
    (maphash (lambda (uuid path)
               (push (list uuid
                           (or (gethash uuid hord--titles) "(untitled)")
                           (or (gethash uuid hord--types) "unknown")
                           path)
                     result))
             hord--index)
    (sort result (lambda (a b) (string< (nth 1 a) (nth 1 b))))))

(defun hord--title-for-uuid (uuid)
  "Return the title for UUID, or UUID itself if unknown."
  (or (gethash uuid hord--titles) uuid))

(defun hord--truncate (str max)
  "Truncate STR to MAX chars, adding \u2026 if truncated."
  (if (> (length str) max)
      (concat (substring str 0 (1- max)) "\u2026")
    str))

(defun hord--type-label (type-id)
  "Return human label for TYPE-ID."
  (or (cdr (assoc type-id hord-type-labels)) type-id))

(defun hord--relation-label (predicate)
  "Return short label for PREDICATE."
  (or (cdr (assoc predicate hord-relation-labels)) predicate))

;; ── Card metadata from org file ───────────────────────────

(defun hord--read-org-metadata (filepath)
  "Read metadata from org FILEPATH.  Returns alist of property values."
  (when (and filepath (file-exists-p filepath))
    (with-temp-buffer
      (insert-file-contents filepath)
      (let (result)
        ;; #+TITLE from header
        (goto-char (point-min))
        (when (re-search-forward "^#\\+TITLE:\\s-+\\(.+\\)" nil t)
          (push (cons "TITLE" (string-trim (match-string 1))) result))
        ;; Main PROPERTIES drawer
        (goto-char (point-min))
        (when (re-search-forward ":PROPERTIES:" nil t)
          (let ((end (save-excursion
                       (re-search-forward ":END:" nil t))))
            (when end
              (while (re-search-forward
                      ":\\([A-Z_]+\\):\\s-+\\(.+\\)" end t)
                (push (cons (match-string 1)
                            (string-trim (match-string 2)))
                      result)))))
        ;; Bibliographic Data properties
        (goto-char (point-min))
        (when (re-search-forward "^\\*\\* Bibliographic Data" nil t)
          (when (re-search-forward ":PROPERTIES:" nil t)
            (let ((end (save-excursion
                         (re-search-forward ":END:" nil t))))
              (when end
                (let (bib-fields)
                  (while (re-search-forward
                          ":\\([A-Z_-]+\\):\\s-+\\(.+\\)" end t)
                    (push (cons (match-string 1)
                                (string-trim (match-string 2)))
                          bib-fields))
                  (push (cons "BIB-DATA" (nreverse bib-fields)) result))))))
        ;; Notes section body — try explicit ** Notes first,
        ;; then fall back to body text between :END: and first ** heading
        (goto-char (point-min))
        (let ((notes-found (re-search-forward "^\\*\\* Notes" nil t)))
          (if notes-found
              (progn
                (forward-line 1)
                (let ((body-start (point))
                      (body-end (or (save-excursion
                                      (when (re-search-forward "^\\*+ " nil t)
                                        (line-beginning-position)))
                                    (point-max))))
                  (let ((body (string-trim
                               (buffer-substring-no-properties
                                body-start body-end))))
                    (unless (string-empty-p body)
                      (push (cons "BODY" body) result)))))
            ;; Fallback: grab text between first :END: and first ** heading,
            ;; skipping relation lines (- XX ::) and org directives (#+)
            (goto-char (point-min))
            (when (re-search-forward "^\\s-*:END:" nil t)
              (forward-line 1)
              (let ((body-start (point))
                    (body-end (or (save-excursion
                                    (when (re-search-forward "^\\*\\* " nil t)
                                      (line-beginning-position)))
                                  (point-max))))
                (let ((raw (buffer-substring-no-properties body-start body-end)))
                  ;; Strip relation lines and org directives
                  (setq raw (replace-regexp-in-string
                             "^\\s-*- [A-Z]+ ::.*\n?" "" raw))
                  (setq raw (replace-regexp-in-string
                             "^#\\+.*\n?" "" raw))
                  (setq raw (string-trim raw))
                  (unless (string-empty-p raw)
                    (push (cons "BODY" raw) result)))))))
        ;; References section (** or * level)
        (goto-char (point-min))
        (when (re-search-forward "^\\*+ References" nil t)
          (forward-line 1)
          (let ((ref-start (point))
                (ref-end (or (save-excursion
                               (when (re-search-forward "^\\*\\* " nil t)
                                 (line-beginning-position)))
                             (point-max))))
            (let ((refs (string-trim
                         (buffer-substring-no-properties
                          ref-start ref-end))))
              ;; Strip bibliography: lines
              (setq refs (replace-regexp-in-string
                          "^[ \t]*bibliography:.*\n?" "" refs))
              (setq refs (string-trim refs))
              (unless (string-empty-p refs)
                (push (cons "REFS" refs) result)))))
        result))))

;; ── History ───────────────────────────────────────────────

(defvar-local hord--history nil "Navigation history for this buffer.")
(defvar-local hord--current-uuid nil "UUID of the currently displayed card.")

;; ── Citation lookup ──────────────────────────────────────

(defun hord--open-file (filepath)
  "Open FILEPATH using the appropriate viewer.
Files with extensions in `hord-external-viewers' are opened
externally; everything else opens in Emacs."
  (let* ((ext (downcase (or (file-name-extension filepath) "")))
         (viewer (cdr (assoc ext hord-external-viewers))))
    (if viewer
        (progn
          (start-process "hord-viewer" nil viewer filepath)
          (message "Opened %s with %s" (file-name-nondirectory filepath) viewer))
      (find-file-other-window filepath))))

(defun hord--blob-files-for-key (citekey)
  "Return list of files in lib/blob/ matching CITEKEY.
Matches both colon and space as the author:year separator,
since blob filenames use both conventions."
  (let ((blob-dir (expand-file-name "lib/blob/" hord-root)))
    (when (file-directory-p blob-dir)
      ;; Build pattern: replace colons with [: ] to match either separator
      (let ((pattern (concat "^"
                             (replace-regexp-in-string
                              ":" "[: ]"
                              (regexp-quote citekey))
                             "\\.")))
        (directory-files blob-dir t pattern)))))

(defun hord--bib-links-for-uuid (uuid)
  "Return an alist of link fields from the Bibliographic Data of UUID.
Possible keys: \"URL\", \"DOI\".  Values are strings."
  (let* ((entity (hord--entity uuid))
         (filepath (hord-entity-filepath entity))
         result)
    (when (and filepath (file-exists-p filepath))
      (with-temp-buffer
        (insert-file-contents filepath)
        (goto-char (point-min))
        (when (re-search-forward "^\\*\\* Bibliographic Data" nil t)
          (let ((end (or (save-excursion
                           (when (re-search-forward "^\\*\\* " nil t)
                             (line-beginning-position)))
                         (point-max))))
            (when (re-search-forward ":URL:\\s-+\\(.+\\)" end t)
              (push (cons "URL" (string-trim (match-string 1))) result))
            (goto-char (point-min))
            (re-search-forward "^\\*\\* Bibliographic Data" nil t)
            (when (re-search-forward ":DOI:\\s-+\\(.+\\)" end t)
              (push (cons "DOI" (string-trim (match-string 1))) result))))))
    result))

(defun hord--cite-dispatch (key)
  "Look up cite KEY and act: open card, DOI, URL, or blob file.
Gathers all available targets and presents a menu if more than one."
  (let* ((uuid (gethash key hord--citekeys))
         (blobs (hord--blob-files-for-key key))
         (links (when uuid (hord--bib-links-for-uuid uuid)))
         (url (cdr (assoc "URL" links)))
         (doi (cdr (assoc "DOI" links)))
         (choices nil))
    ;; Build choice list (pushed in reverse display order)
    (dolist (f blobs)
      (push (cons (format "File: %s" (file-name-nondirectory f))
                  (cons 'file f))
            choices))
    (when url
      (push (cons (format "URL:  %s" (hord--truncate url 50))
                  (cons 'url url))
            choices))
    (when doi
      (push (cons (format "DOI:  %s" doi)
                  (cons 'url (concat "https://doi.org/" doi)))
            choices))
    (when uuid
      (push (cons (format "Card: %s" (hord--title-for-uuid uuid))
                  (cons 'card uuid))
            choices))
    (cond
     ;; Nothing found
     ((null choices)
      (message "No card, URL, or files found for cite:%s" key))
     ;; Single option — act directly
     ((= (length choices) 1)
      (hord--cite-act (cdar choices)))
     ;; Multiple options — completing-read
     (t
      (let* ((choice (completing-read (format "cite:%s → " key)
                                      (mapcar #'car choices) nil t))
             (action (cdr (assoc choice choices))))
        (hord--cite-act action))))))

(defun hord--cite-act (action)
  "Execute a cite ACTION cons cell (type . value)."
  (pcase (car action)
    ('card (hord-open (cdr action)))
    ('url  (browse-url (cdr action)))
    ('file (hord--open-file (cdr action)))))

(defun hord--cite-button-action (btn)
  "Action for a cite:key button."
  (hord--cite-dispatch (button-get btn 'hord-citekey)))

(defun hord--insert-with-cite-links (text)
  "Insert TEXT, turning cite:key references into clickable buttons."
  (let ((start 0))
    (while (string-match "cite:\\([a-zA-Z0-9:_-]+\\)" text start)
      ;; Insert text before the match
      (insert (substring text start (match-beginning 0)))
      (let* ((key (match-string 1 text))
             (uuid (gethash key hord--citekeys))
             (blobs (hord--blob-files-for-key key))
             (resolved (or uuid blobs)))
        (insert-text-button
         (concat "cite:" key)
         'face (if resolved 'hord-cite-link 'hord-cite-link-unresolved)
         'hord-citekey key
         'action #'hord--cite-button-action
         'follow-link t
         'help-echo (cond
                     ((and uuid blobs)
                      (format "%s + %d file(s)" (hord--title-for-uuid uuid) (length blobs)))
                     (uuid (hord--title-for-uuid uuid))
                     (blobs (format "%d file(s) in blob/" (length blobs)))
                     (t (format "cite:%s (unresolved)" key)))))
      (setq start (match-end 0)))
    ;; Insert remaining text
    (insert (substring text start))))

;; ── Card view rendering ──────────────────────────────────

(defun hord--render-card (uuid)
  "Render a card view for UUID in the current buffer."
  (let* ((entity (hord--entity uuid))
         (meta (hord--read-org-metadata (hord-entity-filepath entity)))
         (quads (hord-entity-quads entity))
         (incoming (gethash uuid hord--incoming))
         (inhibit-read-only t))
    (erase-buffer)
    (setq hord--current-uuid uuid)

    ;; Title bar
    (insert (propertize (format " %s " (hord-entity-title entity))
                        'face 'hord-title)
            "\n")
    (insert (make-string 56 ?─) "\n")

    ;; Metadata
    (let ((full-title (cdr (assoc "TITLE" meta))))
      (when full-title
        (hord--insert-meta "Title" full-title)))
    (hord--insert-meta "Type" (hord--type-label (hord-entity-type entity)))
    (let ((author (gethash uuid hord--authors)))
      (when author (hord--insert-meta "Author" author)))
    (let ((created (cdr (assoc "CREATED" meta))))
      (when created (hord--insert-meta "Created" created)))
    (let ((source (cdr (assoc "SOURCE" meta))))
      (when source (hord--insert-meta "Source" source)))
    (let ((geo (cdr (assoc "GEO" meta))))
      (when geo (hord--insert-meta "Location" geo)))
    (insert "\n")

    ;; Relations (outgoing)
    (let ((rels (seq-filter
                 (lambda (q)
                   (and (not (string= (hord-quad-predicate q) "v:type"))
                        (not (string= (hord-quad-predicate q) "v:title"))
                        (not (string= (hord-quad-predicate q) "v:pt"))))
                 quads)))
      (when rels
        (insert (propertize "── Relations " 'face 'hord-section-header)
                (propertize (make-string 43 ?─) 'face 'hord-section-header)
                "\n")
        (dolist (q rels)
          (let* ((pred (hord-quad-predicate q))
                 (obj (hord-quad-object q))
                 (label (hord--relation-label pred))
                 (is-uuid (string-match-p "^[0-9a-f]\\{8\\}-" obj)))
            (insert "  "
                    (propertize (format "%-4s" label) 'face 'hord-relation-type)
                    " → ")
            (if is-uuid
                (hord--insert-link obj (hord--title-for-uuid obj))
              (insert obj))
            (insert "\n")))
        (insert "\n")))

    ;; Incoming links
    (when incoming
      (insert (propertize "── Incoming " 'face 'hord-section-header)
              (propertize (make-string 44 ?─) 'face 'hord-section-header)
              "\n")
      (dolist (inc incoming)
        (let ((pred (car inc))
              (source-uuid (cdr inc)))
          (insert "  ← ")
          (hord--insert-link source-uuid (hord--title-for-uuid source-uuid))
          (insert (propertize (format " (%s)" (hord--relation-label pred))
                              'face 'hord-incoming-source)
                  "\n")))
      (insert "\n"))

    ;; Bibliographic Data (for work cards)
    (let ((bib-data (cdr (assoc "BIB-DATA" meta))))
      (when bib-data
        (insert (propertize "── Bibliographic Data " 'face 'hord-section-header)
                (propertize (make-string 34 ?─) 'face 'hord-section-header)
                "\n")
        (dolist (field bib-data)
          (let ((key (car field))
                (val (cdr field)))
            (insert "  "
                    (propertize (format "%-12s" (concat key ":"))
                                'face 'hord-metadata-key)
                    " ")
            (cond
             ;; DOI — clickable link to doi.org
             ((string= key "DOI")
              (insert-text-button
               val
               'face 'hord-link
               'action (lambda (btn)
                         (browse-url (concat "https://doi.org/"
                                             (button-get btn 'hord-doi))))
               'hord-doi val
               'follow-link t
               'help-echo (format "https://doi.org/%s" val)))
             ;; URL — clickable link
             ((string= key "URL")
              (insert-text-button
               (hord--truncate val 55)
               'face 'hord-link
               'action (lambda (btn)
                         (browse-url (button-get btn 'hord-url)))
               'hord-url val
               'follow-link t
               'help-echo val))
             (t (insert val)))
            (insert "\n")))
        (insert "\n")))

    ;; Notes body
    (let ((body (cdr (assoc "BODY" meta))))
      (when (and body (not (string-empty-p body)))
        (insert (propertize "── Notes " 'face 'hord-section-header)
                (propertize (make-string 47 ?─) 'face 'hord-section-header)
                "\n")
        (hord--insert-with-cite-links body)
        (insert "\n\n")))

    ;; References
    (let ((refs (cdr (assoc "REFS" meta))))
      (when refs
        (insert (propertize "── References " 'face 'hord-section-header)
                (propertize (make-string 42 ?─) 'face 'hord-section-header)
                "\n")
        (hord--insert-with-cite-links refs)
        (insert "\n")))

    (goto-char (point-min))))

(defun hord--insert-meta (key value)
  "Insert a metadata KEY: VALUE line."
  (insert "  "
          (propertize (format "%-10s" (concat key ":")) 'face 'hord-metadata-key)
          " "
          (propertize value 'face 'hord-metadata-value)
          "\n"))

(defun hord--insert-link (uuid title)
  "Insert a clickable link to UUID with display TITLE."
  (insert-text-button
   title
   'face 'hord-link
   'hord-uuid uuid
   'action (lambda (btn)
             (hord-open (button-get btn 'hord-uuid)))
   'follow-link t
   'help-echo (format "Open %s (%s)" title uuid)))

;; ── Card view mode ────────────────────────────────────────

(defvar hord-card-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'hord-follow-link)
    (define-key map (kbd "b")   #'hord-back)
    (define-key map (kbd "e")   #'hord-edit)
    (define-key map (kbd "l")   #'hord-list)
    (define-key map (kbd "s")   #'hord-list-and-filter)
    (define-key map (kbd "t")   #'hord-list-type)
    (define-key map (kbd "g")   #'hord-refresh)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "?")   #'hord-help)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    map)
  "Keymap for `hord-card-mode'.")

(define-derived-mode hord-card-mode special-mode "Hord"
  "Major mode for viewing Hoard cards.
\\{hord-card-mode-map}"
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (hord-refresh))))

;; ── List view mode ────────────────────────────────────────

(defvar-local hord-list-filter ""
  "Current filter string for the hord list view.
Filter syntax (space-separated tokens):
  @type    — show only this type (e.g. @con, @per, @cap)
  @cite    — match terms against citekeys instead of titles
  #author  — match author (e.g. #alexander, #braudel)
  +dir     — match directory (e.g. +capture, +content)
  text     — match title or citekey (case-insensitive)
Multiple tokens are ANDed together.")

(defvar hord-list-filter-active nil
  "State of filter editing: nil, :live, or :non-interactive.")

(defvar hord-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'hord-list-open)
    (define-key map (kbd "s")   #'hord-list-live-filter)
    (define-key map (kbd "S")   #'hord-list-set-filter)
    (define-key map (kbd "c")   #'hord-list-clear-filter)
    (define-key map (kbd "t")   #'hord-list-type)
    (define-key map (kbd "g")   #'hord-list-refresh)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "?")   #'hord-help)
    map)
  "Keymap for `hord-list-mode'.")

(define-derived-mode hord-list-mode tabulated-list-mode "Hord-List"
  "Major mode for browsing Hoard entities.

Filter with `s' (live) or `S' (set). Clear with `c'.
Filter syntax: @type @cite #author +dir text (space-separated, ANDed).

Examples:
  @con              — show concepts only
  @per alexander    — persons matching 'alexander'
  +capture          — capture cards only
  braudel           — anything with 'braudel' in title
  @cite mann        — cards with citekey matching 'mann'

\\{hord-list-mode-map}"
  (setq tabulated-list-format
        [("Type" 12 t)
         ("Title" 55 t)
         ("Dir" 10 t)])
  (setq truncate-lines t)
  (setq tabulated-list-sort-key '("Title" . nil))
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun hord--parse-filter (filter-str)
  "Parse FILTER-STR into a plist of filter components.
Returns (:types (list) :dirs (list) :authors (list) :terms (list) :cite t/nil).
The special token @cite switches term matching to citekey mode."
  (let (types dirs authors terms cite)
    (dolist (token (split-string (string-trim filter-str)))
      (cond
       ((string= token "@cite")
        (setq cite t))
       ((string-prefix-p "@" token)
        (push (substring token 1) types))
       ((string-prefix-p "#" token)
        (push (downcase (substring token 1)) authors))
       ((string-prefix-p "+" token)
        (push (substring token 1) dirs))
       ((not (string-empty-p token))
        (push (downcase token) terms))))
    (list :types (nreverse types)
          :dirs (nreverse dirs)
          :authors (nreverse authors)
          :terms (nreverse terms)
          :cite cite)))

(defun hord--entity-matches-filter (entity filter)
  "Test if ENTITY (uuid title type path) matches parsed FILTER.
When :cite is set in FILTER, terms match against citekeys instead of titles."
  (let ((uuid (nth 0 entity))
        (title (downcase (nth 1 entity)))
        (type (nth 2 entity))
        (path (nth 3 entity))
        (types (plist-get filter :types))
        (dirs (plist-get filter :dirs))
        (authors (plist-get filter :authors))
        (terms (plist-get filter :terms))
        (cite (plist-get filter :cite)))
    (and
     ;; Type filter: match short name or full vocab id
     (or (null types)
         (seq-some (lambda (ty)
                     (or (string= type (concat "wh:" ty))
                         (string= type ty)))
                   types))
     ;; Directory filter
     (or (null dirs)
         (seq-some (lambda (d)
                     (string-match-p (regexp-quote d) path))
                   dirs))
     ;; Author filter
     (or (null authors)
         (let ((author (downcase (or (gethash uuid hord--authors) ""))))
           (seq-every-p (lambda (a)
                          (string-match-p (regexp-quote a) author))
                        authors)))
     ;; Term filter: match title or citekey depending on mode
     (or (null terms)
         (if cite
             ;; @cite mode: match terms against this entity's citekey
             (let ((citekey (downcase (or (gethash uuid hord--citekeys-reverse) ""))))
               (and (not (string-empty-p citekey))
                    (seq-every-p (lambda (term)
                                   (string-match-p (regexp-quote term) citekey))
                                 terms)))
           ;; Normal mode: match title
           (seq-every-p (lambda (term)
                          (string-match-p (regexp-quote term) title))
                        terms))))))

(defun hord--list-entries-filtered (filter-str)
  "Build tabulated-list entries matching FILTER-STR.
Uses in-memory data only — no per-file reads."
  (let* ((entities (hord--all-entities))
         (filter (hord--parse-filter filter-str))
         (filtered (if (string-empty-p (string-trim filter-str))
                       entities
                     (seq-filter
                      (lambda (e) (hord--entity-matches-filter e filter))
                      entities))))
    (mapcar
     (lambda (e)
       (let* ((uuid (nth 0 e))
              (title (nth 1 e))
              (type (nth 2 e))
              (path (nth 3 e))
              (dir (if (string-match "^\\([^/]+\\)/" path)
                       (match-string 1 path)
                     "")))
         (list uuid
               (vector (hord--type-label type)
                       (hord--truncate title 55)
                       dir))))
     filtered)))

;; ── Live filter (elfeed-style) ────────────────────────────

(defun hord-list-live-filter ()
  "Edit the hord list filter with live preview.
Updates the list in real-time as you type."
  (interactive)
  (hord--ensure-loaded)
  (setq hord-list-filter-active :live)
  (unwind-protect
      (let ((result (read-from-minibuffer
                     "Filter (@type #author +dir text): "
                     hord-list-filter)))
        (with-current-buffer "*hord-list*"
          (setq hord-list-filter result)
          (hord--list-update)))
    (setq hord-list-filter-active nil)))

(defun hord-list-set-filter ()
  "Set the hord list filter without live preview."
  (interactive)
  (setq hord-list-filter
        (read-from-minibuffer
         "Filter (@type #author +dir text): "
         hord-list-filter))
  (hord--list-update))

(defun hord-list-clear-filter ()
  "Clear the current filter and show all entities."
  (interactive)
  (setq hord-list-filter "")
  (hord--list-update))

(defun hord-list-refresh ()
  "Reload data and refresh the list."
  (interactive)
  (hord--load (expand-file-name hord-root))
  (hord--list-update))

(defun hord--list-update ()
  "Re-render the list with the current filter."
  (when (derived-mode-p 'hord-list-mode)
    (let ((pos (point)))
      (setq tabulated-list-entries
            (hord--list-entries-filtered hord-list-filter))
      (tabulated-list-print)
      (goto-char (min pos (point-max)))
      ;; Show count in header
      (setq header-line-format
            (if (string-empty-p (string-trim hord-list-filter))
                (format " %d entities" (length tabulated-list-entries))
              (format " %d matching: %s"
                      (length tabulated-list-entries)
                      hord-list-filter))))))

(defun hord--list-live-update ()
  "Update the list from the minibuffer contents (live filter)."
  (when (eq hord-list-filter-active :live)
    (let ((input (minibuffer-contents-no-properties)))
      (when (get-buffer "*hord-list*")
        (with-current-buffer "*hord-list*"
          (setq hord-list-filter input)
          (hord--list-update))))))

(defun hord--list-minibuffer-setup ()
  "Set up minibuffer for live filtering."
  (when (eq hord-list-filter-active :live)
    (add-hook 'post-command-hook #'hord--list-live-update nil :local)))

(add-hook 'minibuffer-setup-hook #'hord--list-minibuffer-setup)

;; ── Help ──────────────────────────────────────────────────

(defun hord-help ()
  "Show hord keybindings."
  (interactive)
  (if (derived-mode-p 'hord-list-mode)
      (message "RET open  s live-filter  S set-filter  c clear  t type  g refresh  q quit")
    (message "RET follow  TAB/S-TAB links  b back  e edit  g refresh  s filter  t type  l list  C-c W c cite  q quit")))

;; ── Interactive commands ──────────────────────────────────

;;;###autoload
(defun hord-find ()
  "Open a hord card by title using completing-read."
  (interactive)
  (hord--ensure-loaded)
  (let* ((entities (hord--all-entities))
         (candidates (mapcar
                      (lambda (e)
                        (cons (format "%-12s %s"
                                      (hord--type-label (nth 2 e))
                                      (nth 1 e))
                              (nth 0 e)))
                      entities))
         (choice (completing-read "Card: " candidates nil t))
         (uuid (cdr (assoc choice candidates))))
    (when uuid
      (hord-open uuid))))

;;;###autoload
(defun hord-open (uuid)
  "Open the card for UUID in hord-card-mode."
  (interactive "sUUID: ")
  (hord--ensure-loaded)
  (let ((buf (get-buffer-create "*hord*")))
    (with-current-buffer buf
      ;; Push current to history before navigating
      (when (and hord--current-uuid
                 (not (string= hord--current-uuid uuid)))
        (push hord--current-uuid hord--history))
      (unless (eq major-mode 'hord-card-mode)
        (hord-card-mode))
      (hord--render-card uuid))
    (pop-to-buffer-same-window buf)))

;;;###autoload
(defun hord-list (&optional initial-filter)
  "Show all hord entities in a filterable list.
Optional INITIAL-FILTER sets the starting filter string."
  (interactive)
  (hord--ensure-loaded)
  (let ((buf (get-buffer-create "*hord-list*")))
    (with-current-buffer buf
      (hord-list-mode)
      (setq hord-list-filter (or initial-filter ""))
      (hord--list-update))
    (pop-to-buffer-same-window buf)))

(defun hord-list-and-filter ()
  "Switch to the hord list and immediately start live filtering.
Useful from card view to search/filter without going back first."
  (interactive)
  (hord-list)
  (hord-list-live-filter))

(defun hord-list-type ()
  "Set filter to a specific type via completing-read."
  (interactive)
  (hord--ensure-loaded)
  (let* ((types (delete-dups
                 (mapcar (lambda (e) (nth 2 e)) (hord--all-entities))))
         (labels (mapcar (lambda (ty)
                           (cons (format "%s (%s)" (hord--type-label ty) ty)
                                 (replace-regexp-in-string "^wh:" "" ty)))
                         (sort types #'string<)))
         (choice (completing-read "Type: " labels nil t))
         (short (cdr (assoc choice labels))))
    (setq hord-list-filter (concat "@" short))
    (hord--list-update)))

(defun hord-list-open ()
  "Open the card at point in hord-list-mode."
  (interactive)
  (let ((uuid (tabulated-list-get-id)))
    (when uuid
      (hord-open uuid))))

(defun hord-follow-link ()
  "Follow the link at point."
  (interactive)
  (let ((btn (button-at (point))))
    (if btn
        (button-activate btn)
      (message "No link at point"))))

(defun hord-back ()
  "Go back to the previous card in history."
  (interactive)
  (if hord--history
      (let ((prev (pop hord--history)))
        (let ((inhibit-read-only t))
          (hord--render-card prev)))
    (message "No more history")))

(defun hord-edit ()
  "Open the underlying org file for the current card."
  (interactive)
  (when hord--current-uuid
    (let* ((entity (hord--entity hord--current-uuid))
           (filepath (hord-entity-filepath entity)))
      (if (and filepath (file-exists-p filepath))
          (find-file-other-window filepath)
        (message "No file found for %s" hord--current-uuid)))))

(defun hord-refresh ()
  "Refresh the current card view."
  (interactive)
  (when hord--current-uuid
    (hord--load (expand-file-name hord-root))
    (let ((inhibit-read-only t))
      (hord--render-card hord--current-uuid))))

(defun hord-reload ()
  "Force reload the hord data from disk."
  (interactive)
  (setq hord--loaded-root nil)
  (hord--ensure-loaded)
  (message "Hord reloaded"))

;; ── RT suggestion ─────────────────────────────────────────

(defun hord--current-card-uuid ()
  "Get the UUID of the card in the current org buffer.
Searches for :ID: in the first PROPERTIES drawer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward ":ID:\\s-+\\([0-9a-f-]+\\)" nil t)
      (match-string-no-properties 1))))

(defun hord--current-card-words ()
  "Extract searchable words from the current org buffer.
Uses the title, relations labels, and all body text."
  (save-excursion
    (let (words)
      ;; Title
      (goto-char (point-min))
      (when (re-search-forward "^#\\+TITLE:\\s-+\\(.+\\)" nil t)
        (push (match-string-no-properties 1) words))
      ;; Everything after the PROPERTIES :END: — body, relations, notes, refs
      (goto-char (point-min))
      (when (re-search-forward "^  :END:" nil t)
        (forward-line 1)
        (push (buffer-substring-no-properties (point) (point-max)) words))
      (downcase (string-join (nreverse words) " ")))))

(defvar hord--stopwords
  '("from" "with" "that" "this" "into" "have" "been" "were"
    "their" "about" "which" "would" "there" "when" "what"
    "some" "them" "than" "each" "make" "more" "also" "will"
    "only" "over" "such" "after" "other" "most" "very" "just"
    "where" "before" "between" "through" "could" "should"
    "being" "first" "under" "based" "does" "using" "used"
    "these" "those" "many" "well" "much" "like" "case"
    "part" "work" "type" "note" "term" "essay" "book"
    "volume" "edition" "press" "university" "review"
    "history" "journal" "building" "nature" "order"
    "wikipedia" "english")
  "Words to skip when scoring RT candidates.")

(defun hord--score-candidate (candidate-title card-words)
  "Score how well CANDIDATE-TITLE matches CARD-WORDS.
Returns weighted score: title words in card text."
  (let ((title-words (split-string (downcase candidate-title) "[^a-z0-9]+" t))
        (score 0)
        (significant-words 0))
    (dolist (w title-words)
      (when (and (> (length w) 3)
                 (not (member w hord--stopwords)))
        (setq significant-words (1+ significant-words))
        (when (string-match-p (regexp-quote w) card-words)
          (setq score (1+ score)))))
    ;; Require at least half the significant words to match
    (if (and (> significant-words 0)
             (>= (/ (* score 100) significant-words) 50))
        score
      0)))

(defun hord--existing-relations (uuid)
  "Return list of UUIDs already linked from UUID."
  (let ((quads (gethash uuid hord--quads)))
    (mapcar #'hord-quad-object
            (seq-filter (lambda (q)
                          (string-match-p "^[0-9a-f]\\{8\\}-"
                                          (hord-quad-object q)))
                        quads))))

(defun hord--suggest-rt-candidates (uuid &optional limit)
  "Return candidate (uuid . title) pairs for RT links from UUID.
Scores all entities by word overlap with the card's content.
Excludes self and already-linked entities.
Returns at most LIMIT candidates (default 30), sorted by score."
  (hord--ensure-loaded)
  (let* ((card-words (hord--current-card-words))
         (existing (hord--existing-relations uuid))
         (candidates nil))
    (maphash
     (lambda (cand-uuid cand-title)
       (unless (or (string= cand-uuid uuid)
                   (member cand-uuid existing))
         (let ((score (hord--score-candidate cand-title card-words)))
           (when (>= score 2)
             (push (list score cand-uuid cand-title) candidates)))))
     hord--titles)
    ;; Sort by score descending, take top N
    (let ((sorted (seq-take
                   (sort candidates (lambda (a b) (> (car a) (car b))))
                   (or limit 30))))
      (mapcar #'cdr sorted))))

(defun hord-suggest-rt ()
  "Suggest and insert RT links for the current org card.
Scans the card's title and body against all hord entities,
presents scored candidates via completing-read (multiple
selection), and inserts the chosen RT links into the
Relations section.

Run this while editing a card in org-mode."
  (interactive)
  (hord--ensure-loaded)
  (let ((uuid (hord--current-card-uuid)))
    (unless uuid
      (error "No :ID: found in this buffer — not a hord card?"))
    (let* ((candidates (hord--suggest-rt-candidates uuid))
           (labels (mapcar
                    (lambda (c)
                      (let* ((cand-uuid (nth 0 c))
                             (cand-title (nth 1 c))
                             (cand-type (or (gethash cand-uuid hord--types) "")))
                        (cons (format "%-12s %s"
                                      (hord--type-label cand-type)
                                      cand-title)
                              cand-uuid)))
                    candidates)))
      (if (null labels)
          (message "No RT candidates found for this card")
        ;; Multiple selection loop
        (let ((chosen nil)
              (remaining labels))
          (while (and remaining
                      (let* ((choice (completing-read
                                      (format "RT [%d selected, RET to finish]: "
                                              (length chosen))
                                      remaining nil nil))
                             (pair (assoc choice remaining)))
                        (if (and pair (not (string-empty-p choice)))
                            (progn
                              (push pair chosen)
                              (setq remaining (delete pair remaining))
                              t)
                          nil))))
          (when chosen
            ;; Insert RT links into Relations section
            (save-excursion
              (goto-char (point-min))
              (if (re-search-forward "^\\*\\* Relations" nil t)
                  (progn
                    (end-of-line)
                    (dolist (c (nreverse chosen))
                      (insert (format "\n   - RT :: [[id:%s][%s]]"
                                      (cdr c)
                                      ;; Extract title from the label
                                      (replace-regexp-in-string
                                       "^[^ ]+ +" "" (car c))))))
                ;; No Relations section — create one
                (goto-char (point-min))
                (when (re-search-forward "^\\*\\* Notes" nil t)
                  (beginning-of-line)
                  (insert "** Relations\n")
                  (dolist (c (nreverse chosen))
                    (insert (format "   - RT :: [[id:%s][%s]]\n"
                                    (cdr c)
                                    (replace-regexp-in-string
                                     "^[^ ]+ +" "" (car c)))))
                  (insert "\n"))))
            (save-buffer)
            (message "Added %d RT links" (length chosen))))))))

;; ── Citation lookup from org-mode ─────────────────────────

(defun hord--cite-at-point ()
  "Extract a cite:key reference at or near point.
Returns the citekey string (without the cite: prefix), or nil."
  (save-excursion
    (let ((case-fold-search nil))
      ;; If point is on or right after "cite:", back up into it
      (when (looking-back "cite:" (- (point) 5))
        (goto-char (match-beginning 0)))
      ;; If inside a cite:key, move to start
      (skip-chars-backward "a-zA-Z0-9:_-")
      (when (looking-back "cite:" (- (point) 5))
        (goto-char (match-beginning 0)))
      (when (looking-at "cite:\\([a-zA-Z0-9:_-]+\\)")
        (match-string-no-properties 1)))))

(defun hord-lookup-cite-at-point ()
  "Look up the cite:key at point.
Opens card, URL, or blob files — with a menu when multiple exist.
Works from any buffer (org-mode, hord reader, etc.)."
  (interactive)
  (hord--ensure-loaded)
  (let ((key (hord--cite-at-point)))
    (if key
        (hord--cite-dispatch key)
      (message "No cite:key at point"))))

;; ── Scratch pad ──────────────────────────────────────────

(defcustom hord-scratch-directory "~/proj/ybr/bench/scratch/"
  "Directory where daily scratch files are kept."
  :type 'directory
  :group 'hord)

(defcustom hord-scratch-inbox-file "~/proj/org/gtd/inbox.org"
  "Orgzly inbox file synced via Syncthing."
  :type 'file
  :group 'hord)

(defun hord-scratch--file-for-date (date)
  "Return the scratch file path for DATE (a time value)."
  (expand-file-name (format-time-string "%Y-%m-%d.org" date)
                    hord-scratch-directory))

(defun hord-scratch--ensure-dir ()
  "Create the scratch directory if it doesn't exist."
  (let ((dir (expand-file-name hord-scratch-directory)))
    (unless (file-directory-p dir)
      (make-directory dir t))))

(defun hord-scratch--init-buffer (file date)
  "Insert the header template into FILE for DATE."
  (insert (format-time-string
           "#+TITLE: Scratch — %A %e %B %Y\n\n** " date))
  (save-buffer))

(defun hord-scratch--import-inbox ()
  "Import pending items from Orgzly inbox into current scratch buffer.
Moves non-DONE top-level headings from `hord-scratch-inbox-file'
into the scratch buffer under a Mobile Inbox heading, then removes
them from the inbox file.  DONE items are left in place."
  (let* ((inbox (expand-file-name hord-scratch-inbox-file))
         items)
    (when (and (file-exists-p inbox)
               (> (file-attribute-size (file-attributes inbox)) 0))
      ;; Collect non-DONE headings from inbox
      (with-current-buffer (find-file-noselect inbox)
        (org-with-wide-buffer
         (goto-char (point-min))
         (while (re-search-forward "^\\* " nil t)
           (let ((element (org-element-at-point)))
             (when (not (org-element-property :todo-keyword element))
               (let ((beg (org-element-property :begin element))
                     (end (org-element-property :end element)))
                 (push (buffer-substring-no-properties beg end) items)))))
         ;; Remove collected items (reverse so positions stay valid)
         (dolist (item (reverse items))
           (goto-char (point-min))
           (when (search-forward item nil t)
             (delete-region (match-beginning 0) (match-end 0))))
         (when items (save-buffer))))
      ;; Append to scratch
      (when items
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert "\n** Mobile inbox [" (format-time-string "%Y-%m-%d %a %H:%M") "]\n\n")
        (dolist (item (nreverse items))
          ;; Demote: top-level * becomes ** so they nest under Mobile inbox
          (insert (replace-regexp-in-string "^\\* " "*** " item)))
        (save-buffer)
        (message "Imported %d item(s) from inbox" (length items))))))

;;;###autoload
(defun hord-scratch ()
  "Open today's scratch pad.
Creates the file and directory if needed.  Automatically imports
any pending items from the Orgzly inbox."
  (interactive)
  (hord-scratch--ensure-dir)
  (let* ((today (current-time))
         (file  (hord-scratch--file-for-date today)))
    (find-file file)
    (when (= (buffer-size) 0)
      (hord-scratch--init-buffer file today))
    (hord-scratch--import-inbox)))

;;;###autoload
(defun hord-scratch-tomorrow ()
  "Move region (or current subtree) to tomorrow's scratch file."
  (interactive)
  (hord-scratch--ensure-dir)
  (let* ((tomorrow (time-add (current-time) (* 24 60 60)))
         (file     (hord-scratch--file-for-date tomorrow))
         (text     (if (use-region-p)
                       (prog1 (buffer-substring (region-beginning) (region-end))
                         (delete-region (region-beginning) (region-end)))
                     (org-back-to-heading t)
                     (let ((beg (point))
                           (end (org-end-of-subtree t t)))
                       (prog1 (buffer-substring beg end)
                         (delete-region beg end))))))
    ;; Ensure target file exists with header
    (unless (file-exists-p file)
      (with-temp-file file
        (insert (format-time-string
                 "#+TITLE: Scratch — %A %e %B %Y\n\n" tomorrow))))
    ;; Append the text
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert text)
      (unless (bolp) (insert "\n"))
      (save-buffer))
    (save-buffer)
    (message "Moved to %s" (file-name-nondirectory file))))

;;;###autoload
(defun hord-scratch-list ()
  "List unsorted scratch files in the minibuffer and open one."
  (interactive)
  (hord-scratch--ensure-dir)
  (let* ((dir   (expand-file-name hord-scratch-directory))
         (files (directory-files dir nil "\\.org\\'")))
    (if (null files)
        (message "No scratch files.")
      (find-file (expand-file-name
                  (completing-read "Scratch file: " files nil t)
                  dir)))))

;; ── Keybinding ────────────────────────────────────────────

;;;###autoload
(global-set-key (kbd "C-c W f") #'hord-find)

;;;###autoload
(global-set-key (kbd "C-c W l") #'hord-list)

;;;###autoload
(global-set-key (kbd "C-c W r") #'hord-suggest-rt)

;;;###autoload
(global-set-key (kbd "C-c W c") #'hord-lookup-cite-at-point)

;;;###autoload
(global-set-key (kbd "C-c W s") #'hord-scratch)

;;;###autoload
(global-set-key (kbd "C-c W S") #'hord-scratch-list)

(provide 'hord)
;;; hord.el ends here
