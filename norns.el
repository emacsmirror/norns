;;; norns.el --- Control your norns from whithin Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2022 Jordan Besly
;;
;; Version: 0.0.1
;; Keywords: processes, terminals
;; URL: https://github.com/p3r7/norns.el
;; Package-Requires: ((emacs "27.2")(dash "2.17.0")(s "1.12.0")(f "20210624.1103")(websocket "20210110.17"))
;;
;; SPDX-License-Identifier: MIT

;;; Commentary:
;;
;;
;; For detailed instructions, please look at the README.md at https://github.com/p3r7/emacs.el/blob/master/README.md

;;; Code:



;; DEPS

(require 'dash)

(require 's)
(require 'rx)

(require 'f)
(require 'websocket)



;; VARS

(defvar norns-access-policy :current-fallback-default)

(defvar norns-user "we")
(defvar norns-host "norns")
(defvar norns-mdns-domain "local")
(defvar norns-maiden-ws-port 5555)
(defvar norns-sc-ws-port 5556)
(defvar norns-maiden-ws-socket-alist nil)

(defvar norns-maiden-buffer-prefix "maiden")
(defvar norns-maiden-buff-alist nil)
(defvar norns-maiden-switch-on-cmd t)
(defvar norns-maiden-switch-fn #'switch-to-buffer-other-window)
(defvar norns-maiden-switch-no-focus t)

(defvar norns-lua-mode-lighter " norns")

(defvar norns-maiden-repl-prompt "maiden>> ")
(defvar norns-maiden-repl-prompt-internal "maiden>> ")



;; CONST

(defconst norns-script-path-prefix "/home/we/dust/code/")

(defconst norns-script-rx
  (rx bol
      (eval norns-script-path-prefix)
      (group (one-or-more (any "a-z" "A-Z" "0-9" "-" "_")))
      "/"
      (group (one-or-more (any "a-z" "A-Z" "0-9" "-" "_"))) ".lua"
      eol))

(defconst norns-in-script-dir-rx
  (rx bol
      (eval norns-script-path-prefix)
      (group (one-or-more (any "a-z" "A-Z" "0-9" "-" "_")))
      "/"))



;; CORE - PATH

(defun norns--core-curr-fq-path ()
  "Get path (i.e. file-name in Emacs lingo) of current buffer.
it is fully qualified, i.e. w/ a TRAMP prefix if the connexion is remote."
  (if (member major-mode '(dired-mode shell-mode))
      default-directory
    (buffer-file-name)))

(defun norns--core-tramp-extract-path (tramp-path)
  "Remove tramp prefix out of TRAMP-PATH, keeping only the filesystem path."
  (let (vec localname)
    (setq vec (ignore-errors (tramp-dissect-file-name tramp-path)))
    (if vec
        (tramp-file-name-localname vec)
      (user-error "Couldn't parse tramp path %s" tramp-path))))

(defun norns--core-untrampify-path-maybe (fp)
  "If FP is a TRAMP path, keep only the filesystem path (remove prefix)."
  (if (file-remote-p fp)
      (norns--core-tramp-extract-path fp)
    fp))

(defun norns--core-trampify-path-maybe (fp)
  "If `default-directory' is remote, add TRAMP prefix to FP."
  (if (file-remote-p default-directory)
      ;; REVIEW: there's certainly a TRAMP fn to do this...
      (let ((tramp-prefix (s-chop-suffix (norns--core-untrampify-path-maybe default-directory)
                                         default-directory)))
        (concat tramp-prefix fp))
    fp))

(defun norns--core-curr-path ()
  "Get current buffer filesystem path."
  (norns--core-untrampify-path-maybe (norns--core-curr-fq-path)))

(defun norns--core-curr-host ()
  "Get current hostame.
Defaults to \"localhost\" if not a TRAMP path."
  (let ((remote-host (file-remote-p default-directory 'host)))
    (or remote-host "localhost")))




;; NORNS - PATH

(defun norns--current-host-norns-p ()
  "Returns t if host of `default-directory' is a norns."
  (f-directory? (norns--core-trampify-path-maybe "/home/we/dust")))

(defun norns--make-default-norns-tramp-prefix ()
  (concat "/" tramp-default-method ":"
          norns-user "@" norns-host (when norns-mdns-domain (concat "." norns-mdns-domain)) ":"))

(defun norns--location-from-access-policy ()
  (cond
   ((eq norns-access-policy :current-fallback-default)
    (or (and (norns--current-host-norns-p) default-directory)
        (norns--make-default-norns-tramp-prefix)))

   ((eq norns-access-policy :current)
    (unless (norns--current-host-norns-p)
      (user-error "Not visiting a norns!"))
    default-directory)

   (:default
    (norns--make-default-norns-tramp-prefix))))



;; NORNS - PATH - SCRIPTS

(defun norns--script-path-p (fp)
  "Returns t if FP is a script path."
  (s-matches-p norns-script-rx fp))

(defun norns--script-from-path (fp)
  "Extract script name from FP."
  (cdr (s-match norns-script-rx fp)))

(defun norns--in-script-dir-path-p (fp)
  "Returns t if FP is visiting somewhere under a script dir."
  (s-matches-p norns-in-script-dir-rx fp))

(defun norns--script-dir-from-path (fp)
  "Extract script dir name from FP."
  (nth 1 (s-match norns-in-script-dir-rx fp)))

(defun norns-all-scripts ()
  "Get list of scripts on visited norns."
  (let ((default-directory (norns--location-from-access-policy)))
    (--> (f-glob (norns--core-trampify-path-maybe
                  (concat norns-script-path-prefix "*/*.lua")))
         (-map #'norns--core-untrampify-path-maybe it)
         (-map #'norns--script-from-path it))))

(defun norns-current-scripts ()
  "Get list of scripts corresponding to visited buffer."
  (unless (norns--current-host-norns-p)
    (user-error "Not visiting a norns!"))

  (let* ((fp (norns--core-curr-path)))
    (unless (s-starts-with? norns-script-path-prefix fp)
      (user-error "Not visiting a script source!"))

    (cond
     ((norns--script-path-p fp)
      (list (norns--script-from-path fp)))

     ((norns--in-script-dir-path-p fp)
      (let ((script-dir (norns--script-dir-from-path fp)))
        (--> (f-glob (norns--core-trampify-path-maybe
                      (concat norns-script-path-prefix script-dir "/*.lua")))
             (-map #'norns--core-untrampify-path-maybe it)
             (-map #'norns--script-from-path it))))

     (:default (error "Unexpected error")))))



;; NORNS - WS (MAIDEN)

(defun norns--maiden-output (host txt)
  "Write TXT to maiden buffer for HOST (stored in `norns-maiden-buff-alist')."
  (let* ((maiden-buff (cdr (assoc host norns-maiden-buff-alist)))
         ;; (visiting-windows (get-buffer-window-list maiden-buff 't))
         ;; (eof-visiting-windows (--filter (with-selected-window it
         ;;                                   (eq (point) (point-max)))
         ;;                                 visiting-windows))
         (txt (concat txt "\n" norns-maiden-repl-prompt-internal)))

    (with-current-buffer maiden-buff
      ;; (let ((buffer-read-only nil))
      ;;   (save-excursion
      ;;     (end-of-buffer)
      ;;     (insert txt)))

      ;; (comint-output-filter (norns--maiden-process) output)
      (comint-output-filter (norns--maiden-process) (concat "\n" norns-maiden-repl-prompt-internal))

      ;; make visiting windows "follow" (akin to `eshell-scroll-to-bottom-on-output')
      ;; (when visiting-windows
      ;;   (message "moving: %s" eof-visiting-windows)
      ;;   (--map (set-window-point it (point-max)) eof-visiting-windows))
      )))

(defun norns--register-maiden-buffer (host)
  (let ((maiden-buff (get-buffer-create (concat "*" norns-maiden-buffer-prefix "/" host "*"))))
    (with-current-buffer maiden-buff
      ;; (setq buffer-read-only t)
      (norns-maiden-repl-mode))
    (add-to-list 'norns-maiden-buff-alist
                 (cons host maiden-buff))
    maiden-buff))

(defun norns--ensure-host-maiden-buffer-exists (host)
  (let ((buff (cdr (assoc host norns-maiden-buff-alist))))
    (unless (buffer-live-p buff)
      (norns--register-maiden-buffer host))))

(defun norns--ensure-host-ws-open (host)
  "Ensure socket for currently visited host (stored in `norns-maiden-ws-socket-alist') is open.
Also ensures the existence of maiden output buffer (stored in `norns-maiden-buff-alist')."
  (unless (websocket-openp (cdr (assoc host norns-maiden-ws-socket-alist)))
    (add-to-list 'norns-maiden-ws-socket-alist
                 (cons
                  host
                  (websocket-open (format "ws://%s:%d" norns-host norns-maiden-ws-port)
                                  :custom-header-alist '((Sec-WebSocket-Protocol . "bus.sp.nanomsg.org"))
                                  :on-open (lambda (_ws)
                                             (norns--ensure-host-maiden-buffer-exists host))
                                  :on-message (lambda (_ws frame)
                                                (norns--ensure-host-maiden-buffer-exists host)
                                                (norns--maiden-output host (websocket-frame-text frame)))
                                  :on-close (lambda (_ws)
                                              (norns--ensure-host-maiden-buffer-exists host)
                                              (norns--maiden-output host "\nwebsocket closed\n")))))))



;; COMMANDS - WS (MAIDEN)

(defun norns-send-command (cmd)
  "Send CMD to norns via maiden."
  (interactive "s> ")
  (let* ((default-directory (norns--location-from-access-policy))
         (host (norns--core-curr-host)))
    (norns--ensure-host-ws-open host)
    (norns--ensure-host-maiden-buffer-exists host)
    (let* ((frame (selected-frame))
           (win (selected-window))
           (maiden-buff (cdr (assoc host norns-maiden-buff-alist)))
           (visiting-windows (get-buffer-window-list maiden-buff)))
      (websocket-send-text (cdr (assoc host norns-maiden-ws-socket-alist)) (concat cmd "\n"))
      (when (and norns-maiden-switch-on-cmd
                 (null visiting-windows))
        (apply norns-maiden-switch-fn (list maiden-buff))
        (end-of-buffer)
        (when norns-maiden-switch-no-focus
          (set-frame-selected-window frame win))))))



;; COMMANDS - SCRIPT LOAD

(defun norns-load-script-raw (script-name)
  "Ask norns to load SCRIPT-NAME."
  (interactive "sName: ")
  (unless (s-contains? "/" script-name)
    (setq script-name (concat script-name "/" script-name)))
  (norns-send-command (concat "norns.script.load(\"code/" script-name ".lua\")")))

(defun norns--load-script-helper (scripts)
  "Prompt user to select one of the SCRIPTS and then ask for norns to launch it."
  (message "SCRIPTS: %s" scripts)
  (let ((scripts-prompt (--map
                         (if (string= (car it) (nth 1 it))
                             it
                           (cons (s-join "/" it) it))
                         ;; (cons (s-join "/" it) it)
                         scripts))
        script)
    (if (eq (length scripts) 1)
        (setq script (car scripts))
      (setq script (--> (completing-read "Choose: " scripts-prompt)
                        (cdr (assoc it scripts-prompt)))))
    (if script
        (norns-load-script-raw (s-join "/" script))
      (message "canceled"))))

(defun norns-load-script ()
  "Prompt user to select any of the existing scripts and then ask for norns to launch it.
Tries first on `default-directory' (assuming we're visiting a norns), then fallback to remote `norns-host'."
  (interactive)
  (norns--load-script-helper (norns-all-scripts)))

(defun norns-load-current-script ()
  "Load currently visited script.
If visiting a script folder, and more than 1 script is found in it, prompt user to select one."
  (interactive)
  (let ((norns-access-policy :default))
    (norns--load-script-helper (norns-current-scripts))))



;; COMMANDS - LUA EVAL

(defun norns-send-selection ()
  "Send selected buffer region to maiden."
  (interactive)
  (cond
   ((use-region-p)
    (norns-send-command (buffer-substring (region-beginning) (region-end))))

   (:default (message "no selection"))))



;; MAIDEN MAJOR MODE

(defun norns--maiden-input-sender (_proc input)
  (norns-send-command input))

(defun norns--maiden-process ()
  (get-buffer-process (current-buffer)))

(defun norns--maiden-set-pm (pos)
  (set-marker (process-mark (get-buffer-process (current-buffer))) pos))

(defun norns--maiden-pm nil
  (process-mark (get-buffer-process (current-buffer))))

(define-derived-mode norns-maiden-repl-mode comint-mode "maiden"
  "Major mode for interracting w/ a monome norns' maiden repl."
  :keymap (let ((mmap (make-sparse-keymap)))
            (define-key mmap "\r" #'norns-send-selection)
            (define-key mmap (kbd "C-c e R") #'norns-load-current-script)
            (define-key mmap (kbd "C-c e c") #'norns-send-command)
            mmap)

  (setq comint-prompt-regexp (concat "^" (regexp-quote norns-maiden-repl-prompt)))
  (setq comint-input-sender #'norns--maiden-input-sender)
  (setq comint-process-echoes nil)

  ;; A dummy process to keep comint happy. It will never get any input
  (unless (comint-check-proc (current-buffer))
    ;; Was cat, but on non-Unix platforms that might not exist, so
    ;; use hexl instead, which is part of the Emacs distribution.
    (condition-case nil
        (start-process "maiden" (current-buffer) "hexl")
      (file-error (start-process "maiden" (current-buffer) "cat")))
    (set-process-query-on-exit-flag (norns--maiden-process) nil)
    (goto-char (point-max))

    ;; output can include raw characters that confuse comint's
    ;; carriage control code.
    ;; (set (make-local-variable 'comint-inhibit-carriage-motion) t)

    ;; Add a silly header
    (norns--maiden-set-pm (point-max))
    (unless comint-use-prompt-regexp
      (let ((inhibit-read-only t))
        (add-text-properties
         (point-min) (point-max)
         '(rear-nonsticky t field output inhibit-line-move-field-capture t))))
    (comint-output-filter (norns--maiden-process) norns-maiden-repl-prompt-internal)
    (set-marker comint-last-input-start (norns--maiden-pm))
    (set-process-filter (get-buffer-process (current-buffer)) #'comint-output-filter)))

(defun norns-maiden-repl ()
  (interactive)
  (let* ((default-directory (norns--location-from-access-policy))
         (host (norns--core-curr-host)))
    (switch-to-buffer (norns--register-maiden-buffer host))))



;; LUA MINOR MODE

(define-minor-mode norns-lua-mode
  "Additional shortcuts for norns lua sources."
  :lighter norns-lua-mode-lighter
  :keymap (let ((mmap (make-sparse-keymap)))
            (define-key mmap (kbd "C-c e r") #'norns-send-selection)
            (define-key mmap (kbd "C-c e R") #'norns-load-current-script)
            (define-key mmap (kbd "C-c e c") #'norns-send-command)
            mmap))

(defun norns-lua-mode-hook ()
  (when (norns--current-host-norns-p)
    (norns-lua-mode 1)))




(provide 'norns)
