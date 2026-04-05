;;; nanoclj-mode.el --- Major mode and REPL for nanoclj-zig -*- lexical-binding: t; -*-

;; Author: Plurigrid
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: languages, clojure, lisp

;;; Commentary:
;; Emacs major mode, comint REPL, nREPL client, and substrate traversal
;; UI for nanoclj-zig.  Self-contained: only requires built-in comint
;; and cl-lib.  Uses clojure-mode as parent when available.

;;; Code:

(require 'comint)
(require 'cl-lib)

;; ──────────────────────────────────────────────────────────────────
;; Customization
;; ──────────────────────────────────────────────────────────────────

(defgroup nanoclj nil
  "Nanoclj-zig Clojure interpreter."
  :group 'languages
  :prefix "nanoclj-")

(defcustom nanoclj-binary "/Users/bob/i/nanoclj-zig/zig-out/bin/nanoclj"
  "Path to the nanoclj-zig binary."
  :type 'string :group 'nanoclj)

(defcustom nanoclj-repl-buffer-name "*nanoclj*"
  "Name of the nanoclj REPL buffer."
  :type 'string :group 'nanoclj)

(defcustom nanoclj-nrepl-host "127.0.0.1"
  "Default nREPL host."
  :type 'string :group 'nanoclj)

(defcustom nanoclj-nrepl-port 7888
  "Default nREPL port."
  :type 'integer :group 'nanoclj)

(defcustom nanoclj-bci-refresh-interval 1.0
  "BCI dashboard refresh interval in seconds."
  :type 'number :group 'nanoclj)

(defcustom nanoclj-gay-seed 1069
  "Seed for Gay color generation."
  :type 'integer :group 'nanoclj)

;; ──────────────────────────────────────────────────────────────────
;; Gay colors (SplitMix64 from seed 1069, first 7 hues)
;; ──────────────────────────────────────────────────────────────────

(defvar nanoclj--gay-colors
  '("#FF0000" "#FF8800" "#FFFF00" "#00CC00" "#0000FF" "#8800CC" "#FF00FF")
  "Rainbow colors derived from Gay seed 1069 for delimiter colorization.")

;; ──────────────────────────────────────────────────────────────────
;; Builtins
;; ──────────────────────────────────────────────────────────────────

(defvar nanoclj--builtins
  '("color-at" "colors" "mix64" "gf3-add" "gf3-mul" "gf3-conserved?"
    "trit-balance" "bci-read" "bci-channels" "bci-trit" "bci-entropy"
    "substrate" "traverse" "nrepl-start" "xor-fingerprint"
    "hue-to-trit" "color-seed")
  "Nanoclj-zig builtin function names.")

;; ──────────────────────────────────────────────────────────────────
;; Syntax highlighting
;; ──────────────────────────────────────────────────────────────────

(defvar nanoclj-font-lock-keywords
  `((,(regexp-opt nanoclj--builtins 'symbols) . font-lock-builtin-face)
    (,(rx "(" (group (or "def" "defn" "defmacro" "fn" "let" "loop"
                         "if" "when" "cond" "do" "quote"
                         "recur" "try" "catch" "throw")))
     (1 font-lock-keyword-face))
    (,(rx ":" (+ (or word (syntax symbol)))) . font-lock-constant-face)
    (,(rx "#\"" (* (or (not (any "\"" "\\")) (seq "\\" anything))) "\"")
     . font-lock-string-face))
  "Font-lock keywords for `nanoclj-mode'.")

;; ──────────────────────────────────────────────────────────────────
;; Rainbow delimiters via overlays
;; ──────────────────────────────────────────────────────────────────

(defun nanoclj--rainbow-delimiters ()
  "Colorize parentheses with Gay colors from seed 1069."
  (nanoclj--rainbow-clear)
  (save-excursion
    (goto-char (point-min))
    (let ((depth 0))
      (while (re-search-forward "[()]" nil t)
        (let ((ch (char-before)))
          (when (eq ch ?\()
            (let* ((idx (mod depth (length nanoclj--gay-colors)))
                   (color (nth idx nanoclj--gay-colors))
                   (ov (make-overlay (1- (point)) (point))))
              (overlay-put ov 'nanoclj-rainbow t)
              (overlay-put ov 'face `(:foreground ,color :weight bold)))
            (cl-incf depth)))
          (when (eq ch ?\))
            (cl-decf depth)
            (let* ((idx (mod (max 0 depth) (length nanoclj--gay-colors)))
                   (color (nth idx nanoclj--gay-colors))
                   (ov (make-overlay (1- (point)) (point))))
              (overlay-put ov 'nanoclj-rainbow t)
              (overlay-put ov 'face `(:foreground ,color :weight bold))))))))

(defun nanoclj--rainbow-clear ()
  "Remove rainbow delimiter overlays."
  (remove-overlays (point-min) (point-max) 'nanoclj-rainbow t))

;; ──────────────────────────────────────────────────────────────────
;; Major mode
;; ──────────────────────────────────────────────────────────────────

(defvar nanoclj-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?\; "<" st)
    (modify-syntax-entry ?\n ">" st)
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?\{ "(}" st)
    (modify-syntax-entry ?\} "){" st)
    (modify-syntax-entry ?- "w" st)
    (modify-syntax-entry ?? "w" st)
    (modify-syntax-entry ?! "w" st)
    (modify-syntax-entry ?* "w" st)
    (modify-syntax-entry ?+ "w" st)
    (modify-syntax-entry ?= "w" st)
    (modify-syntax-entry ?< "w" st)
    (modify-syntax-entry ?> "w" st)
    (modify-syntax-entry ?' "'" st)
    (modify-syntax-entry ?` "'" st)
    (modify-syntax-entry ?~ "'" st)
    (modify-syntax-entry ?@ "'" st)
    st)
  "Syntax table for `nanoclj-mode'.")

(defvar nanoclj-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-s") #'nanoclj-start-repl)
    (define-key map (kbd "C-c C-r") #'nanoclj-send-region)
    (define-key map (kbd "C-c C-c") #'nanoclj-send-defun)
    (define-key map (kbd "C-x C-e") #'nanoclj-send-last-sexp)
    (define-key map (kbd "C-c C-n") #'nanoclj-nrepl-connect)
    (define-key map (kbd "C-c C-b") #'nanoclj-bci-dashboard)
    (define-key map (kbd "C-c C-t") #'nanoclj-substrate-status)
    (define-key map (kbd "C-c g")   #'nanoclj-color-at)
    map)
  "Keymap for `nanoclj-mode'.")

(defvar nanoclj--parent-mode
  (if (fboundp 'clojure-mode) 'clojure-mode 'prog-mode)
  "Parent mode: clojure-mode if available, else prog-mode.")

;;;###autoload
(define-derived-mode nanoclj-mode
  ;; dynamic parent -- evaluated at define time
  prog-mode  ; placeholder, overridden below
  "Nanoclj"
  "Major mode for editing nanoclj-zig Clojure files."
  :syntax-table nanoclj-mode-syntax-table
  (setq font-lock-defaults '(nanoclj-font-lock-keywords))
  (setq-local comment-start ";")
  (setq-local comment-end "")
  (setq-local indent-tabs-mode nil)
  (add-hook 'after-change-functions
            (lambda (_beg _end _len)
              (ignore-errors (nanoclj--rainbow-delimiters)))
            nil t)
  (ignore-errors (nanoclj--rainbow-delimiters)))

;; Override parent if clojure-mode is available
(when (fboundp 'clojure-mode)
  (put 'nanoclj-mode 'derived-mode-parent 'clojure-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.nclj\\'" . nanoclj-mode))

;; ──────────────────────────────────────────────────────────────────
;; Comint REPL
;; ──────────────────────────────────────────────────────────────────

(defvar nanoclj-prompt-regexp "^user=> "
  "Regexp matching the nanoclj REPL prompt.")

;;;###autoload
(defun nanoclj-start-repl ()
  "Start a nanoclj-zig inferior process in a comint buffer."
  (interactive)
  (unless (comint-check-proc nanoclj-repl-buffer-name)
    (let ((buf (apply #'make-comint-in-buffer
                      "nanoclj" nanoclj-repl-buffer-name
                      nanoclj-binary nil nil)))
      (with-current-buffer buf
        (setq-local comint-prompt-regexp nanoclj-prompt-regexp)
        (setq-local comint-prompt-read-only t)
        (add-hook 'comint-output-filter-functions
                  #'nanoclj--colorize-output-filter nil t))))
  (pop-to-buffer nanoclj-repl-buffer-name))

(defun nanoclj--repl-send (str)
  "Send STR to the nanoclj REPL process."
  (let ((proc (get-buffer-process nanoclj-repl-buffer-name)))
    (unless proc (error "No nanoclj REPL running; use C-c C-s to start one"))
    (comint-send-string proc (concat str "\n"))))

;;;###autoload
(defun nanoclj-send-region (start end)
  "Send the region between START and END to the nanoclj REPL."
  (interactive "r")
  (nanoclj--repl-send (buffer-substring-no-properties start end)))

;;;###autoload
(defun nanoclj-send-defun ()
  "Send the current top-level form to the nanoclj REPL."
  (interactive)
  (save-excursion
    (end-of-defun)
    (let ((end (point)))
      (beginning-of-defun)
      (nanoclj--repl-send (buffer-substring-no-properties (point) end)))))

;;;###autoload
(defun nanoclj-send-last-sexp ()
  "Send the sexp before point to the nanoclj REPL."
  (interactive)
  (let ((end (point)))
    (save-excursion
      (backward-sexp)
      (nanoclj--repl-send (buffer-substring-no-properties (point) end)))))

;; ──────────────────────────────────────────────────────────────────
;; nREPL client (TCP)
;; ──────────────────────────────────────────────────────────────────

(defvar nanoclj--nrepl-proc nil "nREPL network process.")
(defvar nanoclj--nrepl-response "" "Accumulator for nREPL response.")
(defvar nanoclj--nrepl-callback nil "Callback for nREPL response.")

(defun nanoclj--nrepl-filter (_proc output)
  "Filter for nREPL process, accumulating OUTPUT."
  (setq nanoclj--nrepl-response (concat nanoclj--nrepl-response output))
  ;; Simple heuristic: response ends with newline
  (when (string-suffix-p "\n" nanoclj--nrepl-response)
    (let ((resp (string-trim nanoclj--nrepl-response)))
      (setq nanoclj--nrepl-response "")
      (when nanoclj--nrepl-callback
        (funcall nanoclj--nrepl-callback resp)))))

;;;###autoload
(defun nanoclj-nrepl-connect (&optional host port)
  "Connect to nanoclj nREPL at HOST:PORT."
  (interactive
   (list (read-string "Host: " nanoclj-nrepl-host)
         (read-number "Port: " nanoclj-nrepl-port)))
  (let ((host (or host nanoclj-nrepl-host))
        (port (or port nanoclj-nrepl-port)))
    (when (and nanoclj--nrepl-proc (process-live-p nanoclj--nrepl-proc))
      (delete-process nanoclj--nrepl-proc))
    (setq nanoclj--nrepl-proc
          (open-network-stream "nanoclj-nrepl" nil host port))
    (set-process-filter nanoclj--nrepl-proc #'nanoclj--nrepl-filter)
    (setq nanoclj--nrepl-response "")
    (message "Connected to nanoclj nREPL at %s:%d" host port)))

(defun nanoclj-nrepl-eval (code &optional callback)
  "Send CODE to nREPL for evaluation.  Call CALLBACK with result string."
  (unless (and nanoclj--nrepl-proc (process-live-p nanoclj--nrepl-proc))
    (error "Not connected to nREPL; use C-c C-n first"))
  (setq nanoclj--nrepl-callback (or callback #'message))
  (setq nanoclj--nrepl-response "")
  (process-send-string nanoclj--nrepl-proc (concat code "\n")))

;;;###autoload
(defun nanoclj-nrepl-eval-buffer ()
  "Evaluate the current buffer via nREPL."
  (interactive)
  (nanoclj-nrepl-eval (buffer-substring-no-properties (point-min) (point-max))))

;; ──────────────────────────────────────────────────────────────────
;; Substrate traversal UI
;; ──────────────────────────────────────────────────────────────────

;;;###autoload
(defun nanoclj-substrate-status ()
  "Show current substrate info in the echo area."
  (interactive)
  (nanoclj--repl-send "(substrate)")
  (message "Sent (substrate) to REPL -- check *nanoclj* for output."))

;;;###autoload
(defun nanoclj-traverse (target)
  "Call (traverse TARGET) in the REPL."
  (interactive "sTraverse target: ")
  (nanoclj--repl-send (format "(traverse \"%s\")" target)))

;;;###autoload
(defun nanoclj-color-at (index)
  "Eval (color-at SEED INDEX) and display the result colorized."
  (interactive "nColor index: ")
  (let ((code (format "(color-at %d %d)" nanoclj-gay-seed index)))
    (if (and nanoclj--nrepl-proc (process-live-p nanoclj--nrepl-proc))
        (nanoclj-nrepl-eval
         code
         (lambda (result)
           (let ((color (string-trim result)))
             (message (propertize (format "%s => %s" code color)
                                  'face `(:background ,color
                                          :foreground ,(if (> (nanoclj--color-luminance color) 0.5)
                                                           "black" "white")))))))
      ;; Fallback: send to comint REPL
      (nanoclj--repl-send code)
      (message "Sent %s to REPL" code))))

(defun nanoclj--color-luminance (hex)
  "Return relative luminance of HEX color string like \"#RRGGBB\"."
  (if (and (stringp hex) (= (length hex) 7) (eq (aref hex 0) ?#))
      (let ((r (/ (string-to-number (substring hex 1 3) 16) 255.0))
            (g (/ (string-to-number (substring hex 3 5) 16) 255.0))
            (b (/ (string-to-number (substring hex 5 7) 16) 255.0)))
        (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b)))
    0.5))

;; ──────────────────────────────────────────────────────────────────
;; BCI Dashboard
;; ──────────────────────────────────────────────────────────────────

(defvar nanoclj--bci-timer nil "Timer for BCI dashboard refresh.")

;;;###autoload
(defun nanoclj-bci-dashboard ()
  "Open a buffer showing BCI channel data, auto-refreshing."
  (interactive)
  (let ((buf (get-buffer-create "*nanoclj-bci*")))
    (with-current-buffer buf
      (special-mode)
      (setq-local revert-buffer-function #'nanoclj--bci-refresh))
    (nanoclj--bci-refresh)
    (pop-to-buffer buf)
    (when nanoclj--bci-timer (cancel-timer nanoclj--bci-timer))
    (setq nanoclj--bci-timer
          (run-with-timer 0 nanoclj-bci-refresh-interval
                          #'nanoclj--bci-refresh))))

(defun nanoclj--bci-refresh (&rest _)
  "Refresh the BCI dashboard buffer via nREPL or REPL."
  (let ((code "(let [chs (bci-channels)] (mapv (fn [i] {:ch i :trit (bci-trit i) :entropy (bci-entropy i)}) (range chs)))"))
    (if (and nanoclj--nrepl-proc (process-live-p nanoclj--nrepl-proc))
        (nanoclj-nrepl-eval
         code
         (lambda (result)
           (let ((buf (get-buffer "*nanoclj-bci*")))
             (when buf
               (with-current-buffer buf
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (insert (propertize "=== nanoclj BCI Dashboard ===\n\n"
                                       'face '(:weight bold :height 1.3)))
                   (insert (format "Updated: %s\n\n" (current-time-string)))
                   (insert result)
                   (insert "\n")))))))
      ;; No nREPL: send to comint
      (nanoclj--repl-send code)
      (let ((buf (get-buffer "*nanoclj-bci*")))
        (when buf
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert "BCI Dashboard -- see *nanoclj* REPL for output\n")
              (insert (format "Updated: %s\n" (current-time-string))))))))))

;; ──────────────────────────────────────────────────────────────────
;; Gay color integration
;; ──────────────────────────────────────────────────────────────────

;;;###autoload
(defun nanoclj-gay-theme-sync ()
  "Load /tmp/gay-theme.el if it exists and apply to nanoclj buffers."
  (interactive)
  (let ((theme-file "/tmp/gay-theme.el"))
    (if (file-exists-p theme-file)
        (progn
          (load theme-file t t)
          (message "Loaded gay theme from %s" theme-file))
      (message "No gay theme file at %s" theme-file))))

(defun nanoclj--colorize-output-filter (output)
  "Post-process REPL OUTPUT, colorizing hex color strings in-place."
  (save-excursion
    (goto-char comint-last-output-start)
    (while (re-search-forward "#[0-9A-Fa-f]\\{6\\}" nil t)
      (let* ((hex (match-string 0))
             (ov (make-overlay (match-beginning 0) (match-end 0))))
        (overlay-put ov 'face `(:background ,hex
                                :foreground ,(if (> (nanoclj--color-luminance hex) 0.5)
                                                 "black" "white")))))))

;;;###autoload
(defun nanoclj-colorize-output ()
  "Manually colorize hex color strings in the current buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "#[0-9A-Fa-f]\\{6\\}" nil t)
      (let* ((hex (match-string 0))
             (ov (make-overlay (match-beginning 0) (match-end 0))))
        (overlay-put ov 'face `(:background ,hex
                                :foreground ,(if (> (nanoclj--color-luminance hex) 0.5)
                                                 "black" "white")))))))

;; ──────────────────────────────────────────────────────────────────
;; Cleanup
;; ──────────────────────────────────────────────────────────────────

(defun nanoclj-stop-bci-dashboard ()
  "Stop the BCI dashboard auto-refresh timer."
  (interactive)
  (when nanoclj--bci-timer
    (cancel-timer nanoclj--bci-timer)
    (setq nanoclj--bci-timer nil)
    (message "BCI dashboard timer stopped.")))

;; ──────────────────────────────────────────────────────────────────
;; Inline eval overlays (CIDER-style)
;; ──────────────────────────────────────────────────────────────────

(defvar nanoclj--eval-overlays nil "Active inline eval result overlays.")

(defun nanoclj--clear-eval-overlays ()
  "Remove all inline eval overlays."
  (mapc #'delete-overlay nanoclj--eval-overlays)
  (setq nanoclj--eval-overlays nil))

(defun nanoclj--show-eval-overlay (result pos)
  "Show RESULT as inline overlay at POS (end of evaluated sexp)."
  (nanoclj--clear-eval-overlays)
  (let* ((trimmed (string-trim result))
         ;; Strip prompt from result
         (clean (if (string-match "^.*=> \\(.*\\)$" trimmed)
                    (match-string 1 trimmed)
                  trimmed))
         (ov (make-overlay pos pos nil t t))
         (display-str (propertize (format " => %s" clean)
                                  'face '(:foreground "#19EBA5"
                                          :slant italic))))
    (overlay-put ov 'after-string display-str)
    (overlay-put ov 'nanoclj-eval t)
    (push ov nanoclj--eval-overlays)
    ;; Auto-clear after 10 seconds or next command
    (run-with-timer 10 nil #'nanoclj--clear-eval-overlays)
    (add-hook 'pre-command-hook #'nanoclj--clear-eval-overlays nil t)))

(defun nanoclj--eval-sync (code)
  "Evaluate CODE synchronously via comint, return the result string.
Sends code, waits for prompt, extracts last result line."
  (let* ((proc (get-buffer-process nanoclj-repl-buffer-name))
         (buf (and proc (process-buffer proc)))
         marker result)
    (unless proc (error "No nanoclj REPL running"))
    (with-current-buffer buf
      (setq marker (point-max)))
    (comint-send-string proc (concat code "\n"))
    ;; Wait for new prompt after our output (up to 3 seconds)
    (let ((deadline (+ (float-time) 3.0))
          found)
      (while (and (not found) (< (float-time) deadline))
        (accept-process-output proc 0.05)
        (with-current-buffer buf
          (goto-char marker)
          ;; Look for: result\nuser=> (prompt after our result)
          (when (re-search-forward "\\(.*\\)\n[^ \n]*=> " nil t)
            (setq found t)
            (setq result (match-string 1))))))
    (or result "")))

;;;###autoload
(defun nanoclj-eval-last-sexp-overlay ()
  "Evaluate sexp before point and show result inline."
  (interactive)
  (let ((end (point))
        (code nil))
    (save-excursion
      (backward-sexp)
      (setq code (buffer-substring-no-properties (point) end)))
    (let ((result (nanoclj--eval-sync code)))
      (nanoclj--show-eval-overlay result end))))

;;;###autoload
(defun nanoclj-eval-defun-overlay ()
  "Evaluate top-level form and show result inline."
  (interactive)
  (save-excursion
    (end-of-defun)
    (let ((end (point))
          (code nil))
      (beginning-of-defun)
      (setq code (buffer-substring-no-properties (point) end))
      (let ((result (nanoclj--eval-sync code)))
        (nanoclj--show-eval-overlay result end)))))

;;;###autoload
(defun nanoclj-eval-replace ()
  "Evaluate sexp before point and replace it with the result."
  (interactive)
  (let ((end (point)))
    (save-excursion
      (backward-sexp)
      (let* ((start (point))
             (code (buffer-substring-no-properties start end))
             (result (nanoclj--eval-sync code)))
        (delete-region start end)
        (insert result)))))

;; ──────────────────────────────────────────────────────────────────
;; Load file (CIDER C-c C-k)
;; ──────────────────────────────────────────────────────────────────

;;;###autoload
(defun nanoclj-load-file (&optional filename)
  "Load FILENAME (or current buffer's file) into the REPL."
  (interactive)
  (let ((file (or filename (buffer-file-name))))
    (unless file (error "Buffer is not visiting a file"))
    (when (buffer-modified-p) (save-buffer))
    (nanoclj--repl-send (format "(load-file \"%s\")" file))
    (message "Loaded %s" (file-name-nondirectory file))))

;; ──────────────────────────────────────────────────────────────────
;; inet-eval: partial evaluation through interaction nets
;; ──────────────────────────────────────────────────────────────────

;;;###autoload
(defun nanoclj-inet-eval-last-sexp ()
  "Evaluate sexp before point through inet (Levy-optimal reduction)."
  (interactive)
  (let ((end (point))
        (code nil))
    (save-excursion
      (backward-sexp)
      (setq code (buffer-substring-no-properties (point) end)))
    (let ((result (nanoclj--eval-sync (format "(inet-eval '%s)" code))))
      (nanoclj--show-eval-overlay
       (propertize (format "[inet] %s" result)
                   'face '(:foreground "#E698DF"))
       end))))

;;;###autoload
(defun nanoclj-peval-last-sexp ()
  "Partially evaluate sexp before point (first Futamura projection)."
  (interactive)
  (let ((end (point))
        (code nil))
    (save-excursion
      (backward-sexp)
      (setq code (buffer-substring-no-properties (point) end)))
    (let ((result (nanoclj--eval-sync (format "(peval %s)" code))))
      (nanoclj--show-eval-overlay result end))))

;; ──────────────────────────────────────────────────────────────────
;; Completion (TAB)
;; ──────────────────────────────────────────────────────────────────

(defvar nanoclj--completion-cache nil "Cached completion candidates.")
(defvar nanoclj--completion-tick 0 "Tick counter for cache invalidation.")

(defun nanoclj--refresh-completions ()
  "Fetch current env symbols from REPL for completion."
  (let ((result (ignore-errors (nanoclj--eval-sync "(env-keys)"))))
    (when (and result (not (string-empty-p result)))
      (setq nanoclj--completion-cache
            (append nanoclj--builtins
                    (split-string (replace-regexp-in-string "[\\[\\](){}\"']" "" result)
                                  "[ ,\n]+" t))))))

(defun nanoclj-completion-at-point ()
  "Completion-at-point function for nanoclj-mode."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (when bounds
      (list (car bounds) (cdr bounds)
            (or nanoclj--completion-cache nanoclj--builtins)
            :exclusive 'no))))

;; ──────────────────────────────────────────────────────────────────
;; Eldoc: show arglists in echo area
;; ──────────────────────────────────────────────────────────────────

(defvar nanoclj--eldoc-arglists
  '(("color-at" . "(color-at seed index)")
    ("colors" . "(colors n)")
    ("mix64" . "(mix64 x)")
    ("gf3-add" . "(gf3-add a b)")
    ("gf3-mul" . "(gf3-mul a b)")
    ("gf3-conserved?" . "(gf3-conserved? a b c)")
    ("trit-balance" . "(trit-balance coll)")
    ("bci-read" . "(bci-read)")
    ("bci-channels" . "(bci-channels)")
    ("bci-trit" . "(bci-trit channel)")
    ("bci-entropy" . "(bci-entropy)")
    ("substrate" . "(substrate)")
    ("traverse" . "(traverse target)")
    ("nrepl-start" . "(nrepl-start port)")
    ("xor-fingerprint" . "(xor-fingerprint & vals)")
    ("hue-to-trit" . "(hue-to-trit hue)")
    ("color-seed" . "(color-seed hex)")
    ("http-fetch" . "(http-fetch url [method] [body])")
    ("map" . "(map f coll)")
    ("filter" . "(filter pred coll)")
    ("reduce" . "(reduce f init coll)")
    ("def" . "(def name value)")
    ("defn" . "(defn name [args] body)")
    ("fn" . "(fn [args] body)")
    ("let" . "(let [bindings] body)")
    ("if" . "(if test then else)")
    ("do" . "(do & exprs)")
    ("quote" . "(quote form)")
    ("nth" . "(nth coll index)")
    ("count" . "(count coll)")
    ("conj" . "(conj coll & items)")
    ("assoc" . "(assoc map key val)")
    ("get" . "(get map key)")
    ("first" . "(first coll)")
    ("rest" . "(rest coll)")
    ("cons" . "(cons x coll)")
    ("str" . "(str & args)")
    ("println" . "(println & args)")
    ("subs" . "(subs s start [end])")
    ("peval" . "(peval expr) -- partial eval via first Futamura projection")
    ("inet-eval" . "(inet-eval 'expr) -- Levy-optimal reduction via interaction nets")
    ("inet-cell" . "(inet-cell net-id kind arity)")
    ("inet-wire" . "(inet-wire net-id cell-a port-a cell-b port-b)")
    ("inet-reduce" . "(inet-reduce net-id)")
    ("inet-readback" . "(inet-readback net-id cell-idx)")
    ("inet-new" . "(inet-new) -- allocate fresh interaction net")
    ("inet-compile" . "(inet-compile net-id expr) -- compile expr to inet"))
  "Alist mapping function names to arglist strings.")

(defun nanoclj-eldoc-function ()
  "Return eldoc string for the function at or around point."
  (save-excursion
    (let ((ppss (syntax-ppss)))
      ;; If inside a list, find the function name
      (when (> (nth 0 ppss) 0)
        (goto-char (nth 1 ppss))
        (forward-char 1)
        (let ((sym (thing-at-point 'symbol t)))
          (when sym
            (let ((entry (assoc sym nanoclj--eldoc-arglists)))
              (when entry
                (propertize (cdr entry)
                            'face 'font-lock-doc-face)))))))))

;; ──────────────────────────────────────────────────────────────────
;; GF(3) trit modeline indicator
;; ──────────────────────────────────────────────────────────────────

(defvar-local nanoclj--modeline-trit nil "Current GF(3) trit for modeline.")

(defun nanoclj--trit-indicator ()
  "Return modeline string showing GF(3) trit state."
  (if nanoclj--modeline-trit
      (let* ((trit nanoclj--modeline-trit)
             (face (cond ((= trit 1)  '(:foreground "#FF0000" :weight bold))  ; +1 red
                         ((= trit -1) '(:foreground "#0000FF" :weight bold))  ; -1 blue
                         (t           '(:foreground "#00CC00" :weight bold)))) ; 0 green
             (sym (cond ((= trit 1)  "+")
                        ((= trit -1) "-")
                        (t           "0"))))
        (propertize (format " GF3[%s]" sym) 'face face))
    ""))

(defun nanoclj--update-trit-from-output (output)
  "Extract trit from REPL OUTPUT and update modeline."
  (when (string-match "trit_sum=\\([0-9-]+\\)" output)
    (let ((sum (string-to-number (match-string 1 output))))
      (setq nanoclj--modeline-trit (mod sum 3))
      (when (= nanoclj--modeline-trit 2) (setq nanoclj--modeline-trit -1))
      (force-mode-line-update t))))

;; ──────────────────────────────────────────────────────────────────
;; Macroexpand
;; ──────────────────────────────────────────────────────────────────

;;;###autoload
(defun nanoclj-macroexpand ()
  "Macroexpand sexp before point and show in overlay."
  (interactive)
  (let ((end (point))
        (code nil))
    (save-excursion
      (backward-sexp)
      (setq code (buffer-substring-no-properties (point) end)))
    (let ((result (nanoclj--eval-sync (format "(macroexpand '%s)" code))))
      (nanoclj--show-eval-overlay result end))))

;; ──────────────────────────────────────────────────────────────────
;; Pretty-print last result
;; ──────────────────────────────────────────────────────────────────

;;;###autoload
(defun nanoclj-pprint-last ()
  "Pretty-print last eval result in a separate buffer."
  (interactive)
  (let ((result (nanoclj--eval-sync "*1")))
    (with-current-buffer (get-buffer-create "*nanoclj-pprint*")
      (erase-buffer)
      (insert result)
      (nanoclj-mode)
      (goto-char (point-min)))
    (pop-to-buffer "*nanoclj-pprint*")))

;; ──────────────────────────────────────────────────────────────────
;; Enhanced keymap (add new bindings)
;; ──────────────────────────────────────────────────────────────────

(define-key nanoclj-mode-map (kbd "C-x C-e") #'nanoclj-eval-last-sexp-overlay)
(define-key nanoclj-mode-map (kbd "C-M-x")   #'nanoclj-eval-defun-overlay)
(define-key nanoclj-mode-map (kbd "C-c C-k") #'nanoclj-load-file)
(define-key nanoclj-mode-map (kbd "C-c C-e") #'nanoclj-eval-replace)
(define-key nanoclj-mode-map (kbd "C-c C-i") #'nanoclj-inet-eval-last-sexp)
(define-key nanoclj-mode-map (kbd "C-c C-p") #'nanoclj-peval-last-sexp)
(define-key nanoclj-mode-map (kbd "C-c C-m") #'nanoclj-macroexpand)
(define-key nanoclj-mode-map (kbd "C-c C-f") #'nanoclj-pprint-last)

;; ──────────────────────────────────────────────────────────────────
;; Mode setup: wire eldoc, completion, trit modeline
;; ──────────────────────────────────────────────────────────────────

(defun nanoclj--mode-setup ()
  "Additional setup run after nanoclj-mode is activated."
  ;; Eldoc
  (setq-local eldoc-documentation-function #'nanoclj-eldoc-function)
  (eldoc-mode 1)
  ;; Completion
  (add-hook 'completion-at-point-functions #'nanoclj-completion-at-point nil t)
  ;; GF(3) trit in modeline
  (unless (memq 'nanoclj--trit-indicator mode-line-misc-info)
    (push '(:eval (nanoclj--trit-indicator)) mode-line-misc-info)))

(add-hook 'nanoclj-mode-hook #'nanoclj--mode-setup)

;; Wire trit tracking into REPL buffer
(defun nanoclj--repl-setup ()
  "Set up the nanoclj REPL buffer with trit tracking."
  (add-hook 'comint-output-filter-functions
            #'nanoclj--update-trit-from-output nil t))

(with-eval-after-load 'comint
  (add-hook 'comint-mode-hook
            (lambda ()
              (when (string= (buffer-name) nanoclj-repl-buffer-name)
                (nanoclj--repl-setup)))))

(provide 'nanoclj-mode)
;;; nanoclj-mode.el ends here
