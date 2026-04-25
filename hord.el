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
(defvar hord--incoming nil "Hash table: UUID → list of (predicate . source-uuid).")
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
    (setq hord--loaded-root root)
    (message "Loaded hord: %d entities" (hash-table-count hord--index))))

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
               ((string= p "v:title") (puthash s o hord--titles))
               ((string= p "v:type") (puthash s o hord--types)))
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
      (insert-file-contents filepath nil 0 2000) ; first 2k is enough
      (let (result)
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
        ;; Also grab body text (after Relations and Notes sections)
        (goto-char (point-min))
        (when (re-search-forward "^\\*\\* Notes" nil t)
          (forward-line 1)
          (let ((body-start (point)))
            (push (cons "BODY" (string-trim
                                (buffer-substring-no-properties
                                 body-start (point-max))))
                  result)))
        result))))

;; ── History ───────────────────────────────────────────────

(defvar-local hord--history nil "Navigation history for this buffer.")
(defvar-local hord--current-uuid nil "UUID of the currently displayed card.")

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
    (hord--insert-meta "Type" (hord--type-label (hord-entity-type entity)))
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

    ;; Notes body
    (let ((body (cdr (assoc "BODY" meta))))
      (when (and body (not (string-empty-p body)))
        (insert (propertize "── Notes " 'face 'hord-section-header)
                (propertize (make-string 47 ?─) 'face 'hord-section-header)
                "\n")
        (insert body "\n")))

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
    (define-key map (kbd "s")   #'hord-find)
    (define-key map (kbd "t")   #'hord-list-type)
    (define-key map (kbd "g")   #'hord-refresh)
    (define-key map (kbd "q")   #'quit-window)
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

(defvar hord-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'hord-list-open)
    (define-key map (kbd "s")   #'hord-find)
    (define-key map (kbd "t")   #'hord-list-type)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `hord-list-mode'.")

(define-derived-mode hord-list-mode tabulated-list-mode "Hord-List"
  "Major mode for browsing Hoard entities.
\\{hord-list-mode-map}"
  (setq tabulated-list-format
        [("Type" 12 t)
         ("Title" 45 t)
         ("Created" 20 t)])
  (setq tabulated-list-sort-key '("Title" . nil))
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun hord--list-entries (&optional type-filter)
  "Build tabulated-list entries, optionally filtered by TYPE-FILTER."
  (let ((entities (hord--all-entities)))
    (when type-filter
      (setq entities (seq-filter
                      (lambda (e) (string= (nth 2 e) type-filter))
                      entities)))
    (mapcar
     (lambda (e)
       (let* ((uuid (nth 0 e))
              (title (nth 1 e))
              (type (nth 2 e))
              (path (nth 3 e))
              (meta (hord--read-org-metadata
                     (expand-file-name path (expand-file-name hord-root))))
              (created (or (cdr (assoc "CREATED" meta)) "")))
         (list uuid
               (vector (hord--type-label type)
                       title
                       (if (> (length created) 16)
                           (substring created 0 16)
                         created)))))
     entities)))

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
(defun hord-list (&optional type-filter)
  "Show all hord entities in a tabulated list.
Optional TYPE-FILTER limits to a specific type."
  (interactive)
  (hord--ensure-loaded)
  (let ((buf (get-buffer-create "*hord-list*")))
    (with-current-buffer buf
      (hord-list-mode)
      (setq tabulated-list-entries (hord--list-entries type-filter))
      (tabulated-list-print))
    (pop-to-buffer-same-window buf)))

(defun hord-list-type ()
  "List cards filtered by type."
  (interactive)
  (hord--ensure-loaded)
  (let* ((types (delete-dups
                 (mapcar (lambda (e) (nth 2 e)) (hord--all-entities))))
         (labels (mapcar (lambda (t)
                           (cons (format "%s (%s)" (hord--type-label t) t) t))
                         (sort types #'string<)))
         (choice (completing-read "Type: " labels nil t))
         (type-id (cdr (assoc choice labels))))
    (hord-list type-id)))

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

;; ── Keybinding ────────────────────────────────────────────

;;;###autoload
(global-set-key (kbd "C-c W f") #'hord-find)

;;;###autoload
(global-set-key (kbd "C-c W l") #'hord-list)

(provide 'hord)
;;; hord.el ends here
