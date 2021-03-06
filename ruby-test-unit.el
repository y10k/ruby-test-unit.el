;;; ruby-test-unit.el --- run Ruby Test::Unit test case in Emacs compilation-mode  -*- lexical-binding: t -*-

;; Copyright (C) 2019 by Yoshinori Toki

;; Author: Yoshinori Toki <toki@freedom.ne.jp>
;; Version: 0.2
;; Package-Requires: ((compile) (ruby-mode) (seq))
;; Keywords: ruby, test
;; URL: https://github.com/y10k/ruby-test-unit.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Usage:
;;
;; modity .emacs to set ruby-test-unit key definition in ruby-mode.
;;
;;   (require 'ruby-test-unit)
;;   (add-hook 'ruby-mode-hook #'ruby-test-unit-keys)
;;
;; Key bindings in ruby-mode:
;;
;;   C-c ,  ruby-test-unit-run-test-location    run ruby test at cursor point
;;   C-c .  ruby-test-unit-run-test-method      run ruby test method at cursor point
;;   C-c @  ruby-test-unit-run-test-class       run ruby test-case class at cursor point
;;   C-c f  ruby-test-unit-run-test-file        run ruby test file of current buffer
;;   C-c r  ruby-test-unit-run-rake-test        run rake test
;;   C-c c  compile                             use to run the last test again
;;

;;; Code:

(require 'compile)
(require 'ruby-mode)
(require 'seq)

(defvar ruby-test-unit-ruby-command "bundle exec ruby"
  "Ruby command to run test of ruby Test::Unit at `compilation-mode'.")

(defvar ruby-test-unit-rake-test-command "bundle exec rake test"
  "Rake command to run test task at `compilation-mode'.")

(defvar ruby-test-unit-runner-options nil
  "Command options of ruby Test::Unit.")

(defvar ruby-test-unit-runner-options-at-test-method "-v"
  "Command options of ruby Test::Unit when executing test method.")

(defvar ruby-test-unit-imenu-create-index-function 'ruby-imenu-create-index
  "Set `ruby-imenu-create-index' function defined at `ruby-mode'.")

(defconst ruby-test-unit-test-method-regexp
  '((pattern . "\\(.+\\)#\\(test_.+\\)") ; ex. TestClass#test_method
    (class-pos . 1)
    (method-pos . 2)))

(defconst ruby-test-unit-test-case-regexp
  "^\\s *class\\s .*<\\s *Test::Unit::TestCase\\s *\\($\\|;\\)") ; ex. class ... < Test::Unit::TestCase

(defconst ruby-test-unit-test-code-regexp-list
  (list "^\\s *def\\s +test_"                                                                     ; ex. def test_...
        "^\\s *test\\(\\s *(\\)?\\s *\\s\".+\\s\"\\s *\\()\\s *\\)?\\(do\\s *\\($\\|;\\)\\|{\\)"  ; ex. test "..." do, test('...') {
        ruby-test-unit-test-case-regexp
        "^\\s *require.*\\s\"test/unit\\s\""))                                                    ; ex. require 'test/unit'

(defconst ruby-test-unit-tramp-file-name-prefix-regexp "\\`/.+:.*:")

(defun ruby-test-unit-test-method-index (ruby-imenu-index-alist)
  "Get test method index assoc-list from RUBY-IMENU-INDEX-ALIST."
  (seq-filter (lambda (index-pair)
                (string-match-p (alist-get 'pattern ruby-test-unit-test-method-regexp)
                                (car index-pair)))
              ruby-imenu-index-alist))

(defun ruby-test-unit-test-class-index (ruby-imenu-index-alist)
  "Get test class index assoc-list from RUBY-IMENU-INDEX-ALIST."
  (let ((test-class-name-list
         (seq-uniq (mapcar (lambda (test-method-index-pair)
                             (if (string-match (alist-get 'pattern ruby-test-unit-test-method-regexp)
                                               (car test-method-index-pair))
                                 (match-string (alist-get 'class-pos ruby-test-unit-test-method-regexp)
                                               (car test-method-index-pair))))
                           (ruby-test-unit-test-method-index ruby-imenu-index-alist)))))
    (seq-filter (lambda (index-pair)
                  (or (seq-contains test-class-name-list (car index-pair))
                      (let ((case-fold-search nil))
                        (if (not (string-match-p "[#.]" (car index-pair)))
                            (progn
                              (goto-char (cdr index-pair))
                              (string-match-p ruby-test-unit-test-case-regexp
                                              (buffer-substring (line-beginning-position) (line-end-position))))))))
                ruby-imenu-index-alist)))

(defun ruby-test-unit-find-nearest-target (pos index-alist)
  "Get the nearest target.
find the nearest target before POS.
INDEX-ALIST is searched."
  (car (last (seq-filter (lambda (index-pair)
                           (<= (cdr index-pair) pos))
                         index-alist))))

(defun ruby-test-unit-find-nearest-test-method (pos ruby-imenu-index-alist)
  "Get the nearest test method.
find the nearest target before POS.
RUBY-IMENU-INDEX-ALIST is searched."
  (car (ruby-test-unit-find-nearest-target
        pos (ruby-test-unit-test-method-index ruby-imenu-index-alist))))

(defun ruby-test-unit-find-nearest-test-class (pos ruby-imenu-index-alist)
  "Get the nearest test class.
find the nearest target before POS.
RUBY-IMENU-INDEX-ALIST is searched."
  (car (ruby-test-unit-find-nearest-target
        pos (ruby-test-unit-test-class-index ruby-imenu-index-alist))))

(defun ruby-test-unit-split-test-method (test-method-full-name)
  "Get class name and method name form TEST-METHOD-FULL-NAME."
  (if (string-match (alist-get 'pattern ruby-test-unit-test-method-regexp)
                    test-method-full-name)
      (list (match-string (alist-get 'class-pos ruby-test-unit-test-method-regexp)
                          test-method-full-name)
            (match-string (alist-get 'method-pos ruby-test-unit-test-method-regexp)
                          test-method-full-name))))

(defun ruby-test-unit-search-test-code ()
  "Search ruby Test::Unit's code in current buffer."
  (seq-find (lambda (test-code-regexp)
              (goto-char (point-min))
              (let ((case-fold-search nil))
                (re-search-forward test-code-regexp nil t)))
            ruby-test-unit-test-code-regexp-list))

(defun ruby-test-unit-get-test-file-name ()
  "Return the name of the test file opened in the current buffer."
  (let ((file-name (buffer-file-name))
        (case-fold-search t))
    (if file-name
        (progn
          (if (string-match ruby-test-unit-tramp-file-name-prefix-regexp file-name)
              (setq file-name (substring file-name (match-end 0) nil)))
          (if (string-match-p "\\`.+\\.rb\\'" file-name)
              file-name)))))

(defun ruby-test-unit-get-test-file-command-string (test-file-name &optional test-options ruby-options)
  "Return the command string to execute the test file.
TEST-FILE-NAME is target test file.
TEST-OPTIONS is Test::Unit's options.
RUBY-OPTIONS is ruby intepreter's options."
  (concat ruby-test-unit-ruby-command
          (if ruby-options (concat " " ruby-options) "")
          " " (shell-quote-argument test-file-name)
          (if test-options (concat " " test-options) "")))

(defun ruby-test-unit-get-test-class-command-string (test-file-name test-class-name &optional test-options ruby-options)
  "Return the command string to execute the test class.
TEST-FILE-NAME is target test file.
TEST-CLASS-NAME is target test class.
TEST-OPTIONS is Test::Unit's options.
RUBY-OPTIONS is ruby intepreter's options."
  (concat (ruby-test-unit-get-test-file-command-string test-file-name
                                                       test-options
                                                       ruby-options)
          " " (shell-quote-argument (concat "-t" test-class-name))))

(defun ruby-test-unit-get-test-method-command-string (test-file-name test-class-name test-method-name &optional test-options test-options-at-method ruby-options)
  "Return the command string to execute the test method.
TEST-FILE-NAME is target test file.
TEST-CLASS-NAME is target test class.
TEST-METHOD-NAME is target test method.
TEST-OPTIONS is Test::Unit's options.
TEST-OPTIONS-AT-METHOD is Test::Unit's options additional.
RUBY-OPTIONS is ruby intepreter's options."
  (concat (ruby-test-unit-get-test-class-command-string test-file-name
                                                        test-class-name
                                                        test-options
                                                        ruby-options)
          (if test-options-at-method (concat " " test-options-at-method) "")
          " " (shell-quote-argument (concat "-n" test-method-name))))

(defun ruby-test-unit-get-test-location-command-string (test-file-name test-location &optional test-options test-options-at-method ruby-options)
  "Return the command string to execute the test at location.
TEST-FILE-NAME is target test file.
TEST-LOCATION is target location.
TEST-OPTIONS is Test::Unit's options.
TEST-OPTIONS-AT-METHOD is Test::Unit's options additional.
RUBY-OPTIONS is ruby intepreter's options."
  (concat (ruby-test-unit-get-test-file-command-string test-file-name
                                                       test-options
                                                       ruby-options)
          (if test-options-at-method (concat " " test-options-at-method) "")
          " " (shell-quote-argument (concat "--location=" test-location))))

(defun ruby-test-unit-run-compile (command-string-function)
  "Run `compile' with the command returned by COMMAND-STRING-FUNCTION."
  (let ((command-string (save-excursion
                          (funcall command-string-function))))
    (if command-string
        (compile command-string))))

;;;#autoload
(defun ruby-test-unit-run-test-location (ruby-debug-option-p)
  "Run current location test of ruby Test::Unit at `compilation-mode'.
If RUBY-DEBUG-OPTION-P is true, execute the test with the debug option (-d)."
  (interactive "P")
  (ruby-test-unit-run-compile
   (lambda ()
     (let ((command-string nil)
           (test-location (number-to-string (line-number-at-pos)))
           (test-file-name (if (ruby-test-unit-search-test-code)
                               (ruby-test-unit-get-test-file-name))))
       (if test-file-name
           (setq command-string
                 (ruby-test-unit-get-test-location-command-string test-file-name
                                                                  test-location
                                                                  ruby-test-unit-runner-options
                                                                  ruby-test-unit-runner-options-at-test-method
                                                                  (if ruby-debug-option-p "-d")))
         (message "Not a ruby test file."))
       command-string))))

;;;#autoload
(defun ruby-test-unit-run-test-method (ruby-debug-option-p)
  "Run test method of ruby Test::Unit at `compilation-mode'.
If RUBY-DEBUG-OPTION-P is true, execute the test with the debug option (-d)."
  (interactive "P")
  (ruby-test-unit-run-compile
   (lambda ()
     (let ((command-string nil)
           (pos (point))
           (test-file-name (if (ruby-test-unit-search-test-code)
                               (ruby-test-unit-get-test-file-name))))
       (if test-file-name
           (let ((test-method-full-name (ruby-test-unit-find-nearest-test-method
                                         pos (funcall ruby-test-unit-imenu-create-index-function))))
             (if test-method-full-name
                 (seq-let (test-class-name test-method-name) (ruby-test-unit-split-test-method test-method-full-name)
                   (setq command-string
                         (ruby-test-unit-get-test-method-command-string test-file-name
                                                                        test-class-name
                                                                        test-method-name
                                                                        ruby-test-unit-runner-options
                                                                        ruby-test-unit-runner-options-at-test-method
                                                                        (if ruby-debug-option-p "-d"))))
               (message "Not found a ruby Test::Unit method.")))
         (message "Not a ruby test file."))
       command-string))))

;;;#autoload
(defun ruby-test-unit-run-test-class (ruby-debug-option-p)
  "Run test class of ruby Test::Unit at `compilation-mode'.
If RUBY-DEBUG-OPTION-P is true, execute the test with the debug option (-d)."
  (interactive "P")
  (ruby-test-unit-run-compile
   (lambda ()
     (let ((command-string nil)
           (pos (point))
           (test-file-name (if (ruby-test-unit-search-test-code)
                               (ruby-test-unit-get-test-file-name))))
       (if test-file-name
           (let ((test-class-name (ruby-test-unit-find-nearest-test-class
                                   pos (funcall ruby-test-unit-imenu-create-index-function))))
             (if test-class-name
                 (setq command-string
                       (ruby-test-unit-get-test-class-command-string test-file-name
                                                                     test-class-name
                                                                     ruby-test-unit-runner-options
                                                                     (if ruby-debug-option-p "-d")))
               (message "Not found a ruby Test::Unit test-case class.")))
         (message "Not a ruby test file."))
       command-string))))

;;;#autoload
(defun ruby-test-unit-run-test-file (ruby-debug-option-p)
  "Run test file of ruby Test::Unit at `compilation-mode'.
If RUBY-DEBUG-OPTION-P is true, execute the test with the debug option (-d)."
  (interactive "P")
  (ruby-test-unit-run-compile
   (lambda ()
     (let ((command-string nil)
           (test-file-name (if (ruby-test-unit-search-test-code)
                               (ruby-test-unit-get-test-file-name))))
       (if test-file-name
           (setq command-string
                 (ruby-test-unit-get-test-file-command-string test-file-name
                                                              ruby-test-unit-runner-options
                                                              (if ruby-debug-option-p "-d")))
         (message "Not a ruby test file."))
       command-string))))

;;;#autoload
(defun ruby-test-unit-run-rake-test ()
  "Run test task of rake at `compilation-mode'."
  (interactive)
  (compile (concat ruby-test-unit-rake-test-command
                   (if ruby-test-unit-runner-options
                       (concat " " (shell-quote-argument (concat "TESTOPTS=" ruby-test-unit-runner-options)))
                     ""))))

;;;#autoload
(defun ruby-test-unit-keys ()
  "Set local key defs for ruby-test-unit in `ruby-mode'."
  (define-key ruby-mode-map (kbd "C-c ,") 'ruby-test-unit-run-test-location)
  (define-key ruby-mode-map (kbd "C-c .") 'ruby-test-unit-run-test-method)
  (define-key ruby-mode-map (kbd "C-c @") 'ruby-test-unit-run-test-class)
  (define-key ruby-mode-map (kbd "C-c f") 'ruby-test-unit-run-test-file)
  (define-key ruby-mode-map (kbd "C-c r") 'ruby-test-unit-run-rake-test)
  (define-key ruby-mode-map (kbd "C-c c") 'compile))

(defun ruby-test-unit-compilation-errors ()
  "Set error defs for ruby-test-unit in `compilation-mode'."
  (dolist (i '((ruby-test-unit-1 "\\s-*\\[?\\(\\S-+\\):\\([0-9]+\\)\\(?::in\\|$\\)" 1 2)
               (ruby-test-unit-2 "\\s-*from \\(\\S-+\\):\\([0-9]+\\)\\(?::in\\|$\\)" 1 2)
               (ruby-test-unit-3 "\\[\\(\\S-+\\):\\([0-9]+\\)\\]:$" 1 2)))
    (add-to-list 'compilation-error-regexp-alist (car i))
    (add-to-list 'compilation-error-regexp-alist-alist i)))

(ruby-test-unit-compilation-errors)

(provide 'ruby-test-unit)

;;; ruby-test-unit.el ends here

;; Local Variables:
;; mode: Emacs-Lisp
;; indent-tabs-mode: nil
;; End:
