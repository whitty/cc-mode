;;; cc-fonts.el --- custom indentation functions for CC Mode

;; Copyright (C) 2002 Free Software Foundation, Inc.

;; Authors:    2002- Martin Stjernholm
;;             jwz, then rms, then sm
;; Maintainer: bug-cc-mode@gnu.org
;; Created:    07-Jan-2002
;; Version:    See cc-mode.el
;; Keywords:   c languages oop

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; The use of standard faces:
;;
;; font-lock-comment-face	Comments.
;; font-lock-string-face	String and character literals.
;; font-lock-keyword-face	Keywords.
;; font-lock-builtin-face	?
;; font-lock-function-name-face	Function names in declarations and definitions,
;;				and classes in those contexts.  Also used for
;;				preprocessor defines with arguments.
;; font-lock-variable-name-face	Variables in declarations and definitions, and
;;				other identifiers in such variable contexts.
;;				Also used for preprocessor defines without
;;				arguments.
;; font-lock-constant-face	Builtin constants.  As opposed to the preceding
;;				two faces, this one is used on the names in
;;				expressions, and it's not used in
;;				declarations, even if there happen to be a
;;				"const" in them somewhere.
;; font-lock-type-face		Types (both pre- and user defined) and classes
;;				in type contexts.
;; font-lock-reference-face	Name qualifiers.
;;
;; Face aliases, mapped to different faces depending on (X)Emacs flavor:
;;
;; c-doc-face			Documentation comments (like Javadoc).
;; c-label-face			Label identifiers.
;; c-preprocessor-face		Preprocessor directives.
;; c-invalid-face		Invalid syntax.
;;
;; Special faces:
;;
;; c-doc-markup-face		Special markup in doc comments.
;;				Overlaid over `c-doc-face'.
;;
;; Some comments on the use of faces:
;;
;; o  `c-doc-face' is an alias for `font-lock-doc-string-face' in
;;    XEmacs, `font-lock-doc-face' in Emacs 21 and later, or
;;    `font-lock-comment-face' in older Emacs (that since source
;;    documentation are actually comments in these languages, as
;;    opposed to elisp).  FIXME: Doc comment fontification currently
;;    only works with font-lock packages that have
;;    `font-lock-syntactic-face-function', i.e Emacs 21 and later.
;;
;; o  `c-label-face' is an alias for either `font-lock-constant-face'
;;    (in Emacs 20 and later), or `font-lock-reference-face'
;;    otherwise.
;;
;; o  `c-preprocessor-face' is an alias for
;;    `font-lock-preprocessor-face' in XEmacs and - in lack of a
;;    closer equivalent - `font-lock-builtin-face' or
;;    `font-lock-reference-face' in Emacs.
;;
;; o  `c-invalid-face' is an alias for `font-lock-warning-face' in
;;    Emacs.  In XEmacs there's no corresponding standard face, so
;;    there it's defined as a face that stands out sharply.
;;
;;    This face is not used for the #error directive, since that's not
;;    a syntactic error in itself.  A parallel can be drawn to other
;;    error raising facilities, such as throw, which don't use this
;;    face either.

;;; Code:

(eval-when-compile
  (let ((load-path
	 (if (and (boundp 'byte-compile-dest-file)
		  (stringp byte-compile-dest-file))
	     (cons (file-name-directory byte-compile-dest-file) load-path)
	   load-path)))
    (require 'cc-bytecomp)))

(cc-require 'cc-defs)
(cc-require 'cc-langs)
(cc-require 'cc-vars)
(cc-require 'cc-engine)

;; Avoid repeated loading through the eval-after-load directive in
;; cc-mode.el.
(provide 'cc-fonts)

(require 'font-lock)


;; Note that font-lock in XEmacs doesn't expand face names as
;; variables, so we have to use the (eval . FORM) in the font lock
;; matchers wherever we use these alias variables.

(defvar c-doc-face
  (cond ((c-face-name-p 'font-lock-doc-string-face)
	 ;; XEmacs.
	 'font-lock-doc-string-face)
	((c-face-name-p 'font-lock-doc-face)
	 ;; Emacs 21 and later.
	 'font-lock-doc-face)
	(t
	 'font-lock-comment-face))
  "Face name used for source documentation that's extracted by special
tools (e.g. Javadoc).")

(defvar c-preprocessor-face
  (cond ((c-face-name-p 'font-lock-preprocessor-face)
	 ;; XEmacs has a font-lock-preprocessor-face.
	 'font-lock-preprocessor-face)
	((c-face-name-p 'font-lock-builtin-face)
	 ;; In Emacs 20 and later font-lock-builtin-face has
	 ;; traditionally been used for preprocessor directives.
	 'font-lock-builtin-face)
	(t
	 'font-lock-reference-face))
  "Face name used for preprocessor directives.")

(cc-bytecomp-defvar font-lock-constant-face)

(defvar c-label-face
  (cond ((c-face-name-p 'font-lock-label-face)
	 ;; If it happen to occur in the future.  (Well, the more
	 ;; pragmatic reason is to get unique faces for the test
	 ;; suite.)
	 'font-lock-label-face)
	((and (c-face-name-p 'font-lock-constant-face)
	      (eq font-lock-constant-face 'font-lock-constant-face))
	 ;; Test both if font-lock-constant-face exists and that it's
	 ;; not an alias for something else.  This is important since
	 ;; `c-font-lock-find-label' compares already set faces.
	 'font-lock-constant-face)
	(t
	 'font-lock-reference-face)))

(defvar c-invalid-face
  (if (c-face-name-p 'font-lock-warning-face)
      ;; Emacs 20 and later has a font-lock-warning-face.
      'font-lock-warning-face
    ;; Otherwise we provide a face.
    'c-invalid-face)
  "Face name used for invalid syntax.")

(unless (c-face-name-p c-invalid-face)
  (defface c-invalid-face
    '((((class color) (background light)) (:foreground "red"))
      (((class color)) (:foreground "hotpink"))
      (t (:inverse-video t)))
    "Face used to highlight invalid syntax."
    :group 'c-fonts))

;; To make hard spaces visible an inverted version of `c-invalid-face'
;; is used.  Since font-lock in Emacs expands all face names in
;; `font-lock-keywords' as variables we need to have a variable for it
;; that resolves to its own name.
(defconst c-nonbreakable-space-face 'c-nonbreakable-space-face)

(cc-bytecomp-defun face-inverse-video-p) ; Only in Emacs.
(cc-bytecomp-defun face-property-instance) ; Only in XEmacs.

(defun c-make-inverse-face (oldface newface)
  ;; Emacs and XEmacs have completely different face manipulation
  ;; routines. :P
  (copy-face oldface newface)
  (cond ((fboundp 'face-inverse-video-p)
	 ;; Emacs 20 and later.  This only looks at the inverse flag
	 ;; in the current frame.  Other display configurations might
	 ;; be different, but it can only show if the same Emacs has
	 ;; frames on e.g. a color and a monochrome display
	 ;; simultaneously.
	 (unless (face-inverse-video-p oldface)
	   (invert-face newface)))
	((fboundp 'face-property-instance)
	 ;; XEmacs.  Same pitfall here.
	 (unless (face-property-instance oldface 'reverse)
	   (invert-face newface)))
	(t
	 ;; Emacs 19 has no inverse flag at all.  Just inverse the
	 ;; face and hope it wasn't inversed already.
	 (invert-face newface))))

(defun c-font-lock-syntactic-face-function (state)
  (save-excursion
    (if (nth 3 state)
        ;; Check whether the string is properly terminated.
	(let ((nstate (parse-partial-sexp (point) (c-point 'eol)
                                          nil nil state 'syntax-table)))
	  (if (and (eolp)
		   (elt nstate 3)
		   ;; We're at eol inside a string.
		   (if (c-major-mode-is '(c-mode c++-mode objc-mode pike-mode))
		       ;; There's no \ before the newline.
		       (not (elt nstate 5))
		     ;; Quoted newlines aren't supported.
		     t)
		   (if (c-major-mode-is 'pike-mode)
		       ;; There's no # before the string, so newlines
		       ;; aren't allowed.
		       (not (eq (char-before (elt state 8)) ?#))
		     t))
              ;; We're inside a string, at EOL and there was no \.
	      c-invalid-face
            font-lock-string-face))
      (goto-char (elt state 8))
      (if (looking-at c-doc-comment-start-regexp)
	  c-doc-face
	font-lock-comment-face))))

;; Need to declare these during compilation since they're referenced
;; from the lambda generated by
;; `c-make-simple-font-lock-decl-function' which is defined during
;; compilation below.  They don't need to have the proper definitions,
;; though, since the generated lambdas aren't called during
;; compilation.
(cc-bytecomp-defun c-font-lock-type)
(cc-bytecomp-defun c-font-lock-declarators)

(eval-and-compile
  ;; We need the following function during compilation since it's
  ;; called when the `c-lang-defconst' initializers are evaluated.

  (defsubst c-skip-comments-and-strings (limit)
    ;; If the point is within a region fontified as a comment or
    ;; string literal skip to the end of it or to LIMIT, whichever
    ;; comes first, and return t.  Otherwise return nil.  The match
    ;; data is not clobbered.
    (when (memq (get-text-property (point) 'face)
		'(font-lock-comment-face font-lock-string-face))
      (goto-char (next-single-property-change (point) 'face nil limit))
      t))

  (defun c-make-simple-font-lock-decl-function (regexp type-submatch pre post)
    ;; This function makes a byte compiled function that searches for
    ;; REGEXP and fontifies each match outside font locked comments
    ;; and string literals as a declaration.  It works much like an
    ;; anchored font-lock matcher but cuts out a little bit of the
    ;; overhead.  However, the main reason is to pass the real search
    ;; limit to `c-font-lock-declarators' since most (if not all)
    ;; font-lock implementations arbitrarily limits anchored matchers
    ;; to the same line.
    ;;
    ;; TYPE-SUBMATCH is the submatch in REGEXP that surrounds the
    ;; type.  It can be nil if there's no type to fontify.  PRE is run
    ;; before calling `c-font-lock-declarators' and POST is run
    ;; afterwards.

    ;; Note: Replace `byte-compile' with `eval' to debug the generated
    ;; lambda easier.
    (byte-compile
     `(lambda (limit)
	(while (re-search-forward ,regexp limit t)
	  (unless (save-excursion
		    (goto-char (match-beginning 0))
		    (c-skip-comments-and-strings limit))
	    ,(when type-submatch
	       `(save-match-data
		  (c-font-lock-type (match-beginning ,type-submatch)
				    (match-end ,type-submatch))))
	    ,pre
	    (save-match-data
	      (c-font-lock-declarators limit t))
	    ,post))
	nil))))

(c-lang-defconst c-cpp-matchers
  ;; Font lock matchers for preprocessor directives and purely lexical
  ;; stuff.  Used on level 1 and higher.
  all
  `(,@(when (c-lang-var c-opt-cpp-prefix)
	`(;; The stuff after #error and #warning is a message, so fontify it
	  ;; as a string.
	  (,(concat (c-lang-var c-opt-cpp-prefix)
		    "\\(error\\|warning\\)\\>\\s *\\(.*\\)$")
	   2 font-lock-string-face)

	  ;; Fontify filenames in #include <...> as strings.
	  (,(concat (c-lang-var c-opt-cpp-prefix)
		    "\\(import\\|include\\)\\>\\s *\\(<[^>\n\r]*>?\\)")
	   2 font-lock-string-face)

	  ;; #define.
	  (,(concat
	     (c-lang-var c-opt-cpp-prefix)
	     "define\\s +"
	     (concat "\\("		; 1
		     ;; Macro with arguments - a "function".
		     "\\(" (c-lang-var c-symbol-key) "\\)\(" ; 2
		     "\\|"
		     ;; Macro without arguments - a "variable".
		     "\\(" (c-lang-var c-symbol-key) ; 3 + c-symbol-key-depth
		     "\\)\\(\\s \\|$\\)"
		     "\\)"))
	   (2 font-lock-function-name-face nil t)
	   (,(+ 3 (c-lang-var c-symbol-key-depth))
	    font-lock-variable-name-face nil t))

	  ;; Fontify symbol names in #elif or #if ... defined preprocessor
	  ;; directives.
	  (eval . (list
		   ,(concat (c-lang-var c-opt-cpp-prefix) "\\(if\\|elif\\)\\>")
		   (list
		    ,(concat "\\<\\("	; 1
			     ;; Don't use regexp-opt here to avoid the
			     ;; depth hazzle.  As it happens, it currently
			     ;; wouldn't have any effect anyway.
			     (mapconcat 'regexp-quote
					(c-lang-var c-cpp-defined-fns) "\\|")
			     "\\)\\>"
			     "\\s *\(?"
			     "\\(" (c-lang-var c-symbol-key) "\\)?") ; 2
		    nil nil
		    (list 1 c-preprocessor-face)
		    '(2 font-lock-variable-name-face nil t))))

	  ;; Fontify symbols after #ifdef and #ifndef.
	  (,(concat (c-lang-var c-opt-cpp-prefix)
		    "ifn?def\\s +\\(" (c-lang-var c-symbol-key) "\\)")
	   1 font-lock-variable-name-face)

	  ;; Fontify the directive names.
	  (,(byte-compile
	     `(lambda (limit)
		(while (re-search-forward
			,(concat (c-lang-var c-opt-cpp-prefix) "[a-z]+")
			limit t)
		  (or (c-skip-comments-and-strings limit)
		      (save-match-data
			(when (> (match-beginning 0)
				 (save-excursion
				   (c-beginning-of-macro)
				   (point)))
			  (c-end-of-macro)
			  (if (> (point) limit) (goto-char limit))
			  t))
		      (put-text-property (match-beginning 0) (match-end 0)
					 'face c-preprocessor-face)))
		nil)))
	  ))

      ,@(when (c-major-mode-is 'pike-mode)
	  `((eval . (list "\\`#![^\n\r]*"
			  0 c-preprocessor-face))))

      ;; Make hard spaces visible through an inverted `c-invalid-face'.
      (eval . (list
	       "\240"
	       0 (progn
		   (unless (c-face-name-p 'c-nonbreakable-space-face)
		     (c-make-inverse-face c-invalid-face
					  'c-nonbreakable-space-face))
		   'c-nonbreakable-space-face)))
      ))

(defun c-font-lock-labels (limit)
  ;; Fontify all the declarations from the point to LIMIT.  Assumes
  ;; that strings and comments have been fontified already.  This
  ;; function does both the search and the fontification itself to
  ;; avoid differences between the (X)Emacs flavors in where they
  ;; continue the search after a match.

  (while (re-search-forward ":[^:]" limit t)

    (if (get-text-property (match-beginning 0) 'face)
	;; Ignore hits inside highlighted stuff.
	(goto-char (next-single-property-change (point) 'face nil limit))

      (save-excursion
	(let (id-start)
	  (goto-char (match-beginning 0))
	  (c-backward-syntactic-ws)
	  (and (setq id-start (c-on-identifier))

	       (progn
		 (goto-char id-start)
		 (c-backward-syntactic-ws)
		 (or
		  ;; Check for a char that precedes a statement.
		  (memq (char-before) '(?\} ?\{ ?\) ?\;))
		  ;; Check for a preceding label.  We exploit the font
		  ;; locking made earlier by this function.
		  (and (eq (char-before) ?:)
		       (progn
			 (backward-char)
			 (c-backward-syntactic-ws)
			 (not (bobp)))
		       (eq (get-text-property (1- (point)) 'face)
			   c-label-face))
		  ;; Check for a keyword that precedes a statement.
		  (c-after-conditional)))

	       (progn
		 ;; Got a label.
		 (goto-char id-start)
		 (looking-at c-symbol-key)
		 (put-text-property (match-beginning 0) (match-end 0)
				    'face c-label-face))))))))

(c-lang-defconst c-basic-matchers
  ;; Font lock matchers for basic keywords, labels, references and
  ;; various other easily recognizable things.  Used on level 2 and
  ;; higher.

  all `(;; Fontify keyword constants.
	,@(when (c-lang-var c-constant-kwds)
	    `((,(concat "\\<\\(" (c-make-keywords-re nil
				   (c-lang-var c-constant-kwds)) "\\)\\>")
	       0 font-lock-constant-face)))

	;; Fontify all keywords except the primitive types.
	(,(concat "\\<" (c-lang-var c-nontype-keywords-regexp))
	 1 font-lock-keyword-face)

	;; Fontify leading identifiers in fully qualified names like
	;; "foo::bar" in languages that supports such things.
	,@(when (c-lang-var c-opt-identifier-concat-key)
	    `((,(byte-compile
		 ;; Must use a function here since we match longer
		 ;; than we want to move before doing a new search.
		 ;; This is not necessary for XEmacs >= 20 since it
		 ;; restarts the search from the end of the first
		 ;; highlighted submatch (something that causes
		 ;; problems in other places).
		 `(lambda (limit)
		    (while (re-search-forward
			    ,(concat "\\(\\<" ; 1
				     "\\(" (c-lang-var c-symbol-key) "\\)" ; 2
				     "[ \t\n\r]*"
				     (c-lang-var c-opt-identifier-concat-key)
				     "[ \t\n\r]*"
				     "\\)"
				     (c-lang-var c-symbol-start))
			    limit t)
		      (unless (save-excursion
				(goto-char (match-beginning 0))
				(c-skip-comments-and-strings limit))
			(put-text-property (match-beginning 2) (match-end 2)
					   'face font-lock-reference-face)
			(goto-char (match-end 1)))))))))

	;; Fontify labels in languages that supports them.
	,@(when (c-lang-var c-label-key)

	    `(;; Fontify goto targets and case labels.  This
	      ;; deliberately fontifies only a single identifier or a
	      ;; signed integer as a label; all other forms are
	      ;; considered to be expressions and thus fontified as
	      ;; such (i.e. not at all).

	      ;; (Got three different interpretation levels here,
	      ;; which makes it a bit complicated: 1) The backquote
	      ;; stuff is expanded when compiled or loaded, 2) the
	      ;; eval form is evaluated at font-lock setup (to
	      ;; substitute c-label-face correctly), and 3) the
	      ;; resulting structure is interpreted during
	      ;; fontification.)
	      (eval
	       . ,(let* ((c-before-label-re
			  (c-make-keywords-re nil
			    (c-lang-var c-before-label-kwds)))
			 (identifier-offset
			  (+ (c-regexp-opt-depth c-before-label-re)
			     3))
			 (integer-offset
			  (+ identifier-offset
			     (c-regexp-opt-depth (c-lang-var c-identifier-key))
			     1)))

		    `(list
		      ,(concat
			"\\<\\("
			c-before-label-re
			"\\)\\>"
			"\\s *"
			"\\("
			;; Match a qualified identifier.  We highlight
			;; the last symbol in it as a label.
			"\\(" (c-lang-var ; identifier-offset
			       c-identifier-key) "\\)"
			"\\|"
			;; Match an integer.
			"\\(-?[0-9]+\\)" ; integer-offset
			(if (c-major-mode-is 'pike-mode)
			    ;; Pike allows integer ranges.
			    (concat
			     "\\s *\\(\\.\\.\\s *\\(-?[0-9]+\\)?\\)?"
			     "\\|\\.\\.\\s *\\(-?[0-9]+\\)")
			  "")
			"\\)"
			"\\s *[:;]")

		      ,@(mapcar
			 (lambda (submatch)
			   `(list ,(+ identifier-offset submatch)
				  c-label-face nil t))
			 (c-lang-var c-identifier-last-sym-match))

		      (list ,integer-offset c-label-face nil t)

		      ,@(when (c-major-mode-is 'pike-mode)
			  `((list ,(+ integer-offset 2) c-label-face nil t)
			    (list ,(+ integer-offset 3) c-label-face nil t)))
		      )))

	      ;; Fontify normal labels.
	      c-font-lock-labels))

	,@(when (c-major-mode-is 'pike-mode)
	    `(;; Constant declarations in Pike lacks a type, so special
	      ;; treatment is necessary before the normal declaration
	      ;; fontification is done.
	      (,(concat "\\<constant\\>"
			(c-lang-var c-syntactic-ws)
			"\\(" (c-lang-var c-symbol-key) "\\)"
			(c-lang-var c-syntactic-ws)
			"=")
	       ,(+ (c-lang-var c-syntactic-ws-depth)
		   1)
	       font-lock-variable-name-face)

	      ;; Handle the identifier after "inherit" as a type.
	      ,(let ((identifier-offset
		      (1+ (c-lang-var c-syntactic-ws-depth))))
		 `(,(byte-compile
		     `(lambda (limit)
			(when (re-search-forward
			       ,(concat "\\<inherit\\>"
					(c-lang-var c-syntactic-ws)
					"\\(" ; identifier-offset
					(c-lang-var c-identifier-key)
					"\\)")
			       limit t)
			  ;; Register the type.
			  (save-match-data
			    (c-add-type (match-beginning ,identifier-offset)
					(match-end ,identifier-offset)))
			  t)))
		   ,@(mapcar
		      (lambda (submatch)
			`(,(+ identifier-offset submatch)
			  font-lock-type-face nil t))
		      (c-lang-var c-identifier-last-sym-match))))
	      ))

	;; Fontify the identifiers inside enum lists.  (The enum type
	;; name is handled by `c-simple-decl-matchers' or
	;; `c-complex-decl-matchers' below.
	,@(when (c-major-mode-is '(c-mode c++-mode pike-mode))
	    `((,(c-make-simple-font-lock-decl-function
		 (concat "\\<enum\\>"
			 ;; Disallow various common punctuation chars
			 ;; that can't come before the '{' of the enum
			 ;; list, to avoid searching too far.
			 "[^\]\[{}();,/#=]*"
			 "{")
		 nil
		 '(goto-char (match-end 0))
		 '(goto-char (match-end 0))))))
	))

(defun c-font-lock-declarators (limit list)
  ;; Assuming the point is at the first declarator in a declaration,
  ;; fontify it.  If LIST is non-nil, fontify also all following
  ;; declarators in a comma separated list (e.g.  "foo" and "bar" in
  ;; "int foo = 17, bar;").  Stop at LIMIT.

  ;;(message "c-font-lock-declarators from %s to %s" (point) limit)
  (let ((id-start (point)) id-end id-face got-init)

    (while (and
	    id-start
	    (< (point) limit)

	    (if (eq (char-after) ?\()
		;; Allow a parenthesized declaration expression in the
		;; first sexp of the declarator, to cope with
		;; e.g. "char (*foo)[]" (below we treat "(" as the
		;; start of the initializer/function prototype).
		;; Don't search past the end of the line to avoid
		;; running away very far in incorrect code.
		(= (car (parse-partial-sexp (point) (c-point 'eol) 0)) 0)
	      t)

	    ;; Search syntactically to the end of the identifier
	    ;; declarator (";", ",", a close paren, eob etc) or to the
	    ;; beginning of an initializer or function prototype ("="
	    ;; or "\\s\(").
	    (c-syntactic-re-search-forward
	     "[;,\{\[]\\|\\s\)\\|\\'\\|\\(=\\|\\(\\s\(\\)\\)"
	     limit t t t))

      (setq id-end (match-beginning 0)
	    id-face (if (match-beginning 2)
			'font-lock-function-name-face
		      'font-lock-variable-name-face)
	    got-init (match-beginning 1))

      ;; Fontify the qualified identifier within the type decl
      ;; expression.
      (goto-char id-start)
      (when (c-syntactic-re-search-forward c-identifier-key id-end 'move)

	(if (eq c-identifier-key c-symbol-key)
	    ;; Got no qualified identifiers in this language.
	    (unless (get-text-property (match-beginning 0) 'face)
	      (put-text-property (match-beginning 0) (match-end 0)
				 'face id-face))

	  (goto-char (match-beginning 0))
	  (let ((end (match-end 0)))
	    (while (c-syntactic-re-search-forward c-symbol-key end 'move)
	      (unless (get-text-property (match-beginning 0) 'face)
		(put-text-property (match-beginning 0) (match-end 0)
				   'face id-face))))
	  (goto-char id-end)))

      (cond ((eq id-face 'font-lock-function-name-face)
	     ;; Skip a parenthesized initializer (C++) or a function
	     ;; prototype.
	     (if (c-safe (c-forward-sexp 1) t)
		 (c-forward-syntactic-ws limit)
	       (goto-char limit)))

	    (got-init
	     ;; Skip an initializer expression.
	     (if (c-syntactic-re-search-forward "[;,]" limit 'move t)
		 (backward-char)))

	    (t (c-forward-syntactic-ws limit)))

      ;; Check for a comma if LIST is set.  If one is found we set
      ;; id-start to the next declarator and iterate.
      (if (and list (< (point) limit) (looking-at ","))
	  (progn
	    (forward-char)
	    (c-forward-syntactic-ws limit)
	    (setq id-start (point)))
	(setq id-start nil)))))

(defun c-font-lock-type (start end)
  ;; Fontify the individual identifiers within the given region with
  ;; the type face.  They're taken as all symbols that aren't
  ;; fontified as keywords or references.  Note that we want to
  ;; override function or variable name faces here, since those might
  ;; be put on by an earlier `c-font-lock-declarators' call which got
  ;; confused by a comma.  Point is left at the end of the region on
  ;; return.

  ;;(message "c-font-lock-type from %s to %s" start end)
  (goto-char start)
  (while (c-syntactic-re-search-forward c-symbol-key end 'move)
    (unless (get-text-property (match-beginning 0) 'face)
      (put-text-property (match-beginning 0) (match-end 0)
			 'face 'font-lock-type-face))))

(defconst c-font-lock-maybe-type-faces
  ;; List of faces that might be put at the start of a type when
  ;; `c-font-lock-declarations' runs.  This needs to be evaluated to
  ;; ensure that face name aliases in Emacs are resolved
  ;; (`font-lock-reference-face' might be an alias for
  ;; `font-lock-constant-face').
  (list nil font-lock-type-face font-lock-reference-face))

(defun c-font-lock-declarations (limit)
  ;; Fontify all the declarations and casts from the point to LIMIT.
  ;; Assumes that strings, comments and nontype keywords have been
  ;; fontified already.

  ;;(message "c-font-lock-declarations search from %s to %s" (point) limit)

  ;; Clear the list of found types if we start from the start of the
  ;; buffer, to make it easier to get rid of misspelled types and
  ;; variables that has gotten recognized as types in malformed code.
  (when (bobp)
    (c-clear-found-types))

  (save-restriction
    ;; Narrow to the limit to deliberately fail to fontify
    ;; declarations that crosses it.  E.g. the following is a common
    ;; situation while the first line is being written:
    ;;
    ;;     my_variable
    ;;     some_other_variable = 0;
    ;;
    ;; font-lock will put the limit at the end of the first line here,
    ;; and we use that to avoid recognizing my_variable as a type in a
    ;; declaration that spans to the next line.  This way the
    ;; statement isn't annoyingly flashed as a type while it's being
    ;; entered.
    (narrow-to-region (point-min) limit)

    ;; Must back up a bit since we look for the end of the previous
    ;; statement or declaration, which is earlier than the first
    ;; returned match.
    (when (memq (get-text-property (point) 'face)
		'(font-lock-comment-face font-lock-string-face))
      ;; But first we need to move to a syntactically relevant
      ;; position.  Can't use backward movement since the font-lock
      ;; package might not have fontified the comment or string all
      ;; the way to the start.
      (goto-char (next-single-property-change (point) 'face nil limit)))
    (c-beginning-of-macro)		; Must start outside any macro too.
    (c-backward-syntactic-ws)
    (c-safe (backward-char))

    (let ((match (if (bobp)
		     ;; We always consider bob as a match to get the first
		     ;; declaration in the file, but we have to step past
		     ;; initial comments to avoid that the
		     ;; match-inside-comment-or-string-literal code kicks in.
		     (progn (c-forward-comments)
			    ;; Setup the match data since we'll do a
			    ;; (match-beginning 0) below.
			    (looking-at "")
			    t)
		   (re-search-forward c-decl-prefix-re limit 'move)))
	  match-pos
	  ;; The position to continue searching at.
	  continue-pos
	  ;; The position of the last "real" token we've stopped at.  This can
	  ;; be greater than `continue-pos' when we get hits inside macros.
	  (token-pos -1)
	  ;; Nonzero if `c-decl-prefix-re' matches inside a function arglist,
	  ;; i.e. if it matches '(', '[', or ','.  If it's nonzero then the
	  ;; car of the value is the matched char.
	  arglist-match
	  ;; Set to the result of `c-forward-type'.
	  at-type
	  ;; These record the start and end of the type or possible type found
	  ;; by `c-forward-type'.
	  type-start type-end
	  ;; These store `at-type', `type-start' and `type-end' of the
	  ;; identifier before the one in those variables.  The previous
	  ;; identifier might turn out to be the real type in a declaration if
	  ;; the last one has to be the declarator in it.  If `prev-at-type'
	  ;; is nil then the other variables have undefined values.
	  prev-at-type prev-type-start prev-type-end
	  ;; Whether we've found a declaration or a cast.  We might know this
	  ;; before we've found the type in it.
	  at-decl-or-cast
	  ;; The position of the next token after the closing paren of the
	  ;; last fontified cast.
	  last-cast-end
	  ;; The same for the currently investigated cast.
	  cast-end
	  ;; The maximum of the end positions of all the checked type decl
	  ;; expressions in the successfully identified declarations.  The
	  ;; position might be either before or after the syntactic whitespace
	  ;; following the last token in the type decl expression.
	  (max-type-decl-end -1)
	  ;; Same as `max-type-decl-end', but used when we're before
	  ;; `token-pos'.
	  (max-type-decl-end-before-token -1)
	  ;; The end position of the last entered macro.
	  (macro-end -1))

      (while (progn
	       (while (and
		       match

		       (or
			;; Continue if the match is within a comment or a
			;; string literal.
			(when (memq (get-text-property (point) 'face)
				    '(font-lock-comment-face
				      font-lock-string-face))
			  ;; Go to the end of the highlighted region before
			  ;; continuing the search above.
			  (goto-char (next-single-property-change
				      (point) 'face nil limit))
			  t)

			(progn
			  (setq match-pos (match-beginning 0)
				arglist-match (memq (char-before)
						    '(?\( ?\[ ?,)))
			  ;; Skip forward past comments only to set the
			  ;; position to continue at, so we don't skip macros.
			  (c-forward-comments)
			  (setq continue-pos (point))
			  ;; If `continue-pos' is less or equal to
			  ;; `token-pos', we've got a hit inside a macro
			  ;; that's in the syntactic whitespace before the
			  ;; last "real" declaration we've checked.  If
			  ;; they're equal we've arrived at the declaration a
			  ;; second, so there's nothing to do.
			  (= continue-pos token-pos))

			(let (prop)
			  ;; If `continue-pos' is less than `token-pos' we're
			  ;; still searching macros in the syntactic
			  ;; whitespace, so we need only to skip comments and
			  ;; not macros, since they can't be nested.
			  (when (> continue-pos token-pos)
			    (c-forward-syntactic-ws)
			    (setq token-pos (point)))

			  ;; Continue if the following token isn't some kind
			  ;; of symbol or keyword that can't start a
			  ;; declaration, or if it's fontified as something
			  ;; else besides a type or reference (which might
			  ;; lead a type) already.
			  (when (or
				 (= (point) limit)
				 (not (looking-at c-symbol-start))
				 (if (eq (setq prop (get-text-property
						     (point) 'face))
					 'font-lock-keyword-face)
				     (looking-at c-not-decl-init-keywords)
				   (not (memq prop
					      c-font-lock-maybe-type-faces))))
			    (goto-char continue-pos)
			    t))
			))

		 ;; We only want to match at bob the first time, to avoid
		 ;; looping forever there.  That's not a problem anywhere else
		 ;; since `re-search-forward' will move forward at least one
		 ;; char (except at the limit).
		 (setq match (re-search-forward c-decl-prefix-re limit 'move)))

	       (< (point) limit))

	(catch 'continue
	  ;; Narrow to the end of the macro if we got a hit inside one.
	  (save-excursion
	    (goto-char match-pos)
	    (when (>= match-pos macro-end)
	      (setq macro-end
		    (if (save-excursion (and (c-beginning-of-macro)
					     (< (point) match-pos)))
			(progn (c-end-of-macro)
			       (point))
		      -1))))
	  (when (/= macro-end -1)
	    (when (<= macro-end (point))
	      (setq macro-end -1)
	      (throw 'continue t))
	    (narrow-to-region (point-min) macro-end))

	  (setq at-type nil
		at-decl-or-cast nil)

	  ;; Check for a type, but be prepared to skip over leading specifiers
	  ;; like "static".  We treat any symbols as specifiers here, to cope
	  ;; with macros like __INLINE__ or anything else that might be in
	  ;; front of declarations.
	  (while (let ((start (point))
		       (res (c-forward-type t)))

		   (cond ((eq res t)
			  ;; Found a known type, so stop searching.
			  (setq at-type t
				type-start start
				type-end (point))
			  nil)

			 (res
			  ;; Found a possible type or a prefix of a known
			  ;; type.  Record this, but continue so that we'll
			  ;; jump over all specifiers and type identifiers.
			  ;; The reason to do this for a known type prefix is
			  ;; to make things like "unsigned INT16" work.
			  (when at-type
			    ;; Got two identifiers with nothing but whitespace
			    ;; between them.  That can only happen in
			    ;; declarations.
			    (setq at-decl-or-cast t))
			  (setq prev-at-type at-type
				prev-type-start type-start
				prev-type-end type-end
				at-type res
				type-start start
				type-end (point)))

			 ((looking-at c-specifier-key)
			  ;; Found a known specifier keyword.  Can occur in
			  ;; both declarations and casts, but we don't set
			  ;; `at-decl-or-cast' here to avoid flashing types
			  ;; prematurely in declarations as they're being
			  ;; written.
			  (goto-char (match-end 1)))))

	    (c-forward-syntactic-ws))

	  (unless at-type
	    (throw 'continue t))
	  (if (eq at-type 'prefix) (setq at-type t))

	  ;; Check for and step over a type decl expression after the thing
	  ;; that is or might be a type.  We can skip this if we know we're in
	  ;; a declaration and don't have several possible positions for the
	  ;; type.
	  (if (and at-decl-or-cast (or (eq at-type t) (not prev-at-type)))
	      (progn
		;; Go to the end of the first type decl expression.  We know
		;; there's an identifier after the type.  If there's any
		;; parenthesis after the identifier we jump over that too
		;; under the assumption that it's a function decl arglist.
		(goto-char type-end)
		(when (c-safe (c-forward-sexp) t)
		  (c-forward-syntactic-ws)
		  (when (eq (char-after) ?\()
		    (c-safe (c-forward-sexp)))))

	    (if (catch 'at-decl-or-cast
		  (goto-char type-end)
		  (c-forward-syntactic-ws)
		  (let ((start (point)) (paren-depth 0)
			got-prefix-before-parens got-prefix
			got-parens no-identifier got-suffix)

		    ;; Skip over type decl prefix operators.
		    (while (looking-at c-type-decl-prefix-key)
		      (if (eq (char-after) ?\()
			  (progn
			    (setq paren-depth (1+ paren-depth))
			    (forward-char))
			(unless got-prefix-before-parens
			  (setq got-prefix-before-parens (= paren-depth 0)))
			(setq got-prefix t)
			(goto-char (match-end 1)))
		      (c-forward-syntactic-ws))
		    (setq got-parens (> paren-depth 0))

		    ;; Skip over an identifier.
		    (if (looking-at c-symbol-key)
			(if (eq (get-text-property (point) 'face)
				'font-lock-keyword-face)
			    ;; An invalid declaration.  Might be some macro
			    ;; that isn't followed by a semicolon in front of
			    ;; a statement.
			    (throw 'at-decl-or-cast nil)
			  (goto-char (match-end 0))
			  (c-forward-syntactic-ws))
		      ;; The identifier seems to be missing.
		      (setq no-identifier t))

		    ;; Skip over type decl suffix operators.
		    (while (and (looking-at c-type-decl-suffix-key)
				(if (eq (char-after) ?\))
				    (when (> paren-depth 0)
				      (setq paren-depth (1- paren-depth))
				      (forward-char)
				      t)
				  (if (save-match-data (looking-at "\\s\("))
				      (unless (c-safe (c-forward-sexp 1) t)
					(throw 'at-decl-or-cast nil))
				    (goto-char (match-end 1)))
				  (setq got-suffix t)))
		      (c-forward-syntactic-ws))

		    (when (or (= (point) start) (> paren-depth 0))
		      ;; We haven't found anything or we're at a token that
		      ;; isn't valid in a type decl inside a parenthesis.
		      (throw 'at-decl-or-cast nil))

		    (if no-identifier
			(progn
			  (when (or (eq at-type t)
				    (and got-prefix got-suffix)
				    (and got-parens got-prefix)
				    (and got-parens got-suffix))
			    ;; Found no identifier.  If the type is known we
			    ;; know that there can't be any identifier
			    ;; somewhere, and it's only in declarations in
			    ;; e.g. function prototypes and in casts that the
			    ;; identifier may be left out.
			    ;;
			    ;; Otherwise we require at least two of
			    ;; `got-prefix', `got-parens', and `got-suffix':
			    ;; `got-parens' only is not enough since it's
			    ;; probably an empty function call.  `got-suffix'
			    ;; only is not enough since it can build an
			    ;; ordinary expression together with the preceding
			    ;; identifier which we've taken as a type.
			    ;;
			    ;; However, we could actually accept on
			    ;; `got-prefix' only, but that can easily occur
			    ;; temporarily while writing an expression so we
			    ;; avoid that case anyway.  We could do a better
			    ;; job if we knew the point when the fontification
			    ;; was invoked.
			    (throw 'at-decl-or-cast t))

			  (when (and got-suffix
				     (not got-prefix)
				     (not got-parens)
				     prev-at-type)
			    ;; Got only a suffix and there are two identifiers
			    ;; before.  The second one is not the type
			    ;; afterall, so return nil to let the conditional
			    ;; below shift to the type in `prev-*'.
			    (throw 'at-decl-or-cast nil)))

		      (unless (or got-prefix got-parens)
			;; Got another identifier directly after the type,
			;; so it's a declaration.
			(throw 'at-decl-or-cast t))

		      (when (and got-suffix
				 (not arglist-match)
				 (eq (char-after) ?{))
			;; Only in a function definition does a '{' follow
			;; after the type decl expression.
			(throw 'at-decl-or-cast t))

		      (when (looking-at "[=\(]")
			;; There's an initializer after the type decl
			;; expression so we know it's a declaration.
			;; (Checking for `(' here normally has no effect since
			;; it's probably matched as a suffix.  That's often
			;; not a problem, however.)
			(throw 'at-decl-or-cast t)))

		    (unless (looking-at (if arglist-match "[,\)]" "[,;]"))
		      ;; If this is a declaration it should end here, so check
		      ;; for allowed separation tokens.
		      (throw 'at-decl-or-cast nil))

		    ;; If we get here we can't tell if this is a type decl or
		    ;; a normal expression by looking at it alone.  (That's
		    ;; under the assumption that normal expressions always can
		    ;; look like type decl expressions, which isn't really
		    ;; true but the cases where it doesn't hold are so
		    ;; uncommon (e.g. some placements of "const" in C++) it's
		    ;; not worth the effort to look for them.)

		    ;; It's a type decl expression if we know we're in a
		    ;; declaration, or if the preceding identifier is a known
		    ;; type.
		    (when (or at-decl-or-cast (memq at-type '(t found)))
		      (throw 'at-decl-or-cast t))

		    (when (and got-prefix-before-parens
			       (not no-identifier)
			       (not arglist-match)
			       (not got-suffix))
		      ;; Got something like "foo * bar".  If we're not inside
		      ;; an arglist then it would be a meaningless expression
		      ;; since the result isn't used.  We therefore choose to
		      ;; recognize it as a declaration.  Do not allow a suffix
		      ;; since it could then be a function call.
		      (throw 'at-decl-or-cast t))

		    ;; If we had a complete symbol table here (which rules out
		    ;; `c-found-types') we should return t due to the
		    ;; disambiguation rule (in at least C++) that anything
		    ;; that can be parsed as a declaration is a declaration.
		    ;; Now we're being more defensive and prefer to highlight
		    ;; things like "foo (bar);" as a declaration only if we're
		    ;; inside the type decl expression of an earlier
		    ;; recognized declaration.
		    (< (point) (if (< (point) token-pos)
				   max-type-decl-end-before-token
				 max-type-decl-end))))
		(setq at-decl-or-cast t)

	      (when prev-at-type
		;; Didn't find a type decl expression, but if we've passed two
		;; consecutive identifiers it's still a declaration - we only
		;; went a bit too far.
		(goto-char type-end)
		(setq at-type (if (eq prev-at-type 'prefix) t prev-at-type)
		      type-start prev-type-start
		      type-end prev-type-end
		      prev-at-type nil)

		;; We don't analyze a type decl expression as thoroughly at
		;; this point as we do above, so just jump over any following
		;; parenthesis under the assumption that it's a function
		;; decl arglist.
		(c-forward-syntactic-ws)
		(when (eq (char-after) ?\()
		  (c-safe (c-forward-sexp))))))

	  ;; Point is now after the type decl expression.

	  ;; Check for a cast.
	  (if (save-excursion
		(and
		 c-opt-cast-close-paren-key
		 arglist-match

		 ;; Should be the first type/identifier in a paren.
		 (memq (car arglist-match) '(?\( ?\[))

		 ;; The closing paren should match
		 ;; `c-opt-cast-close-paren-key'.
		 (progn
		   (c-forward-syntactic-ws)
		   (looking-at c-opt-cast-close-paren-key))

		 ;; There should be a symbol or an expression open paren
		 ;; after it.
		 (progn
		   (forward-char)
		   (c-forward-syntactic-ws)
		   (setq cast-end (point))
		   (or (and (looking-at c-symbol-start)
			    (not (looking-at c-keywords-regexp)))
		       (looking-at "[\(\[]")))

		 ;; There should either be a cast before it or something
		 ;; that isn't an identifier or close paren.
		 (progn
		   (goto-char match-pos)
		   (or (eq (point) last-cast-end)
		       (progn
			 (c-backward-syntactic-ws)
			 (or (bobp)
			     (and
			      (progn
				(backward-char)
				;; Check for a word or symbol char first since
				;; `c-on-identifier' returns nil on keywords
				;; and a paren after a keyword is not a cast.
				(not (looking-at "\\sw\\|\\s_\\|[\]\)]")))
			      (progn
				(forward-char)
				(not (c-on-identifier))))))))))

	      (progn
		(setq last-cast-end cast-end)
		(c-add-complex-type type-start type-end)
		(c-font-lock-type type-start type-end))

	    (if at-decl-or-cast
		;; We're at a declaration.  Highlight the type and the
		;; following declarators.

		(progn
		  ;; Set `max-type-decl-end' or
		  ;; `max-type-decl-end-before-token' under the assumption
		  ;; that we're after the first type decl expression in the
		  ;; declaration now.  That's not really true; we could also
		  ;; be after a parenthesized initializer expression in C++,
		  ;; but this is only used as a last resort to slant ambiguous
		  ;; expression/declarations, and overall it's worth the risk
		  ;; to occasionally fontify an expression as a declaration in
		  ;; an initializer expression compared to getting ambiguous
		  ;; things in normal function prototypes fontified as
		  ;; expressions.
		  (if (< (point) token-pos)
		      (setq max-type-decl-end-before-token
			    (max max-type-decl-end-before-token (point)))
		    (setq max-type-decl-end
			  (max max-type-decl-end (point))))

		  (c-font-lock-type type-start type-end)
		  (when (eq (get-text-property (1- type-end) 'face)
			    font-lock-type-face)
		    ;; Be extra careful so we don't enter something
		    ;; that was fontified as something else than a
		    ;; type.
		    (c-add-complex-type type-start type-end))
		  (c-forward-syntactic-ws)
		  (c-font-lock-declarators (point-max) (not arglist-match)))

	      ;; Not at a declaration, but if we know that we passed a
	      ;; type we should still highlight it.
	      (when (eq at-type t)
		(c-font-lock-type type-start type-end)
		(when (eq (get-text-property (1- type-end) 'face)
			  font-lock-type-face)
		  (c-add-complex-type type-start type-end))))))

	(when (/= macro-end -1)
	  ;; Restore limits if we did macro narrowment above.
	  (narrow-to-region (point-min) limit))
	(goto-char continue-pos)

	;; We search here to allow the first match at bob.  See note above.
	(setq match (re-search-forward c-decl-prefix-re limit 'move))))
    nil))

(c-lang-defconst c-simple-decl-matchers
  ;; Simple font lock matchers for types and declarations.  These are
  ;; used on level 2 only and so aren't combined with
  ;; `c-complex-decl-matchers'.

  all `(;; Fontify all type names and the identifiers in the
	;; declarations they might start.  Use eval here since
	;; `c-known-type-key' gets its value from
	;; `*-font-lock-extra-types' on mode init.
	(eval . (list (c-make-simple-font-lock-decl-function
		       c-known-type-key
		       1
		       '(progn (goto-char (match-end 1))
			       (c-forward-syntactic-ws))
		       '(goto-char (match-end 1)))))

	;; Fontify types preceded by `c-type-prefix-kwds' and the
	;; identifiers in the declarations they might start.
	,@(when (c-lang-var c-type-prefix-kwds)
	    (let ((prefix-re (c-make-keywords-re nil
			       (c-lang-var c-type-prefix-kwds))))
	      `((,(c-make-simple-font-lock-decl-function
		   (concat "\\<\\(" prefix-re "\\)"
			   "[ \t\n\r]+"
			   "\\(" (c-lang-var c-symbol-key) "\\)")
		   (+ (c-regexp-opt-depth prefix-re) 2)
		   '(progn (goto-char (match-end 2))
			   (c-forward-syntactic-ws))
		   '(goto-char (match-end 2)))))))
	))

(c-lang-defconst c-complex-decl-matchers
  ;; Complex font lock matchers for types and declarations.  Used on
  ;; level 3 and higher.

  all `(;; The first two rules here mostly find occurences that
	;; `c-font-lock-declarations' will find later anyway, but not
	;; declarations containing blocks in the type (see note
	;; below).  It's also useful to fontify these everywhere to
	;; show e.g. when a type keyword is accidentally used as an
	;; identifier.

	;; Fontify basic types.
	(,(concat "\\<\\("
		  (c-make-keywords-re nil (c-lang-var c-type-kwds))
		  "\\)\\>")
	 1 'font-lock-type-face)

	;; Fontify types preceded by `c-type-prefix-kwds'.
	,@(when (c-lang-var c-type-prefix-kwds)
	    (let ((prefix-re (c-make-keywords-re nil
			       (c-lang-var c-type-prefix-kwds))))
	      `((,(concat "\\<\\(" prefix-re "\\)"
			  "[ \t\n\r]+"
			  "\\(" (c-lang-var c-symbol-key) "\\)")
		 ,(+ (c-regexp-opt-depth prefix-re) 2) 'font-lock-type-face))))

	;; Fontify symbols after closing braces as declaration
	;; identifiers under the assumption that they are part of
	;; declarations like "class Foo { ... } foo;".  It's too
	;; expensive to check this accurately by skipping past the
	;; brace block, so we use the heuristic that it's such a
	;; declaration if the first identifier is on the same line as
	;; the closing brace.  `c-font-lock-declarations' will later
	;; override it if it turns out to be an new declaration, but
	;; it will be wrong if it's an expression (see the test
	;; decls-8.cc).
	,@(when (c-lang-var c-opt-block-decls-with-vars-key)
	    `((,(c-make-simple-font-lock-decl-function
		 (concat "}"
			 (c-lang-var c-single-line-syntactic-ws)
			 "\\("		; 1 + c-single-line-syntactic-ws-depth
			 (c-lang-var c-type-decl-prefix-key)
			 "\\|"
			 (c-lang-var c-symbol-key)
			 "\\)")
		 nil
		 `(goto-char
		   (match-beginning
		    ,(1+ (c-lang-var c-single-line-syntactic-ws-depth))))
		 nil))))

	;; Fontify all declarations and casts.
	c-font-lock-declarations
	))

(c-lang-defconst c-matchers-1
  all (c-lang-var c-cpp-matchers))

(c-lang-defconst c-matchers-2
  all (append (c-lang-var c-matchers-1)
	      (c-lang-var c-basic-matchers)
	      (c-lang-var c-simple-decl-matchers)))

(c-lang-defconst c-matchers-3
  all (append (c-lang-var c-matchers-1)
	      (c-lang-var c-basic-matchers)
	      (c-lang-var c-complex-decl-matchers)))

(c-lang-defconst c-matchers-4
  all (c-lang-var c-matchers-3))


(defun c-override-default-keywords (def-var new-def)
  ;; This is used to override the value on a `*-font-lock-keywords'
  ;; variable only if it's nil or has the same value as one of the
  ;; `*-font-lock-keywords-*' variables.  Older font-lock packages
  ;; define a default value for `*-font-lock-keywords' which we want
  ;; to override, but we should otoh avoid clobbering a user setting.
  ;; This heuristic for that isn't perfect, but I can't think of any
  ;; better. /mast
  (when (and (boundp def-var)
	     (memq (symbol-value def-var)
		   (cons nil
			 (mapcar
			  (lambda (suffix)
			    (let ((sym (intern (concat (symbol-name def-var)
						       suffix))))
			      (and (boundp sym) (symbol-value sym))))
			  '("-1" "-2" "-3" "-4")))))
    (set def-var new-def)))

;;; C.

(c-override-default-keywords 'c-font-lock-keywords
			     (c-lang-var c-matchers-3 c))

(defconst c-font-lock-keywords-1 (c-lang-var c-matchers-1 c)
  "Subdued level highlighting for C mode.
Fontifies only preprocessor directives (in addition to the syntactic
fontification of strings and comments).")

(defconst c-font-lock-keywords-2 (c-lang-var c-matchers-2 c)
  "Medium level highlighting for C mode.
In addition to `c-font-lock-keywords-1', this adds fontification of
keywords, simple types, declarations that are easy to recognize, and
the user defined types on `c-font-lock-extra-types'.")

(defconst c-font-lock-keywords-3 (c-lang-var c-matchers-3 c)
  "Gaudy level highlighting for C mode.
Like `c-font-lock-keywords-2' but detects declarations in a more
accurate way that works in most cases for arbitrary types without the
need for `c-font-lock-extra-types'.")

(defvar c-font-lock-keywords c-font-lock-keywords-3
  "Default expressions to highlight in C mode.")

;;; C++.

(c-override-default-keywords 'c++-font-lock-keywords
			     (c-lang-var c-matchers-3 c++))

(defconst c++-font-lock-keywords-1 (c-lang-var c-matchers-1 c++)
  "Subdued level highlighting for C++ mode.
Fontifies only preprocessor directives (in addition to the syntactic
fontification of strings and comments).")

(defconst c++-font-lock-keywords-2 (c-lang-var c-matchers-2 c++)
  "Medium level highlighting for C++ mode.
In addition to `c++-font-lock-keywords-1', this adds fontification of
keywords, simple types, declarations that are easy to recognize, and
the user defined types on `c++-font-lock-extra-types'.")

(defconst c++-font-lock-keywords-3 (c-lang-var c-matchers-3 c++)
  "Gaudy level highlighting for C++ mode.
Like `c++-font-lock-keywords-2' but detects declarations in a more
accurate way that works in most cases for arbitrary types without the
need for `c++-font-lock-extra-types'.")

(defvar c++-font-lock-keywords c++-font-lock-keywords-3
  "Default expressions to highlight in C++ mode.")

;;; Objective-C.

(c-override-default-keywords 'objc-font-lock-keywords
			     (c-lang-var c-matchers-3 objc))

(defconst objc-font-lock-keywords-1 (c-lang-var c-matchers-1 objc)
  "Subdued level highlighting for ObjC mode.
Fontifies only compiler directives (in addition to the syntactic
fontification of strings and comments).")

(defconst objc-font-lock-keywords-2 (c-lang-var c-matchers-2 objc)
  "Medium level highlighting for ObjC mode.
In addition to `objc-font-lock-keywords-1', this adds fontification of
keywords, simple types, declarations that are easy to recognize, and
the user defined types on `objc-font-lock-extra-types'.")

(defconst objc-font-lock-keywords-3 (c-lang-var c-matchers-3 objc)
  "Gaudy level highlighting for ObjC mode.
Like `objc-font-lock-keywords-2' but detects declarations in a more
accurate way that works in most cases for arbitrary types without the
need for `objc-font-lock-extra-types'.")

(defvar objc-font-lock-keywords objc-font-lock-keywords-3
  "Default expressions to highlight in ObjC mode.")

;;; Java.

(c-override-default-keywords 'java-font-lock-keywords
			     (c-lang-var c-matchers-3 java))

(defconst java-font-lock-keywords-1 (c-lang-var c-matchers-1 java)
  "Subdued level highlighting for Java mode.
Fontifies nothing except the syntactic fontification of strings and
comments.")

(defconst java-font-lock-keywords-2 (c-lang-var c-matchers-2 java)
  "Medium level highlighting for Java mode.
In addition to `java-font-lock-keywords-1', this adds fontification of
keywords, simple types, declarations that are easy to recognize, and
the user defined types on `java-font-lock-extra-types'.")

(defconst java-font-lock-keywords-3 (c-lang-var c-matchers-3 java)
  "Gaudy level highlighting for Java mode.
Like `java-font-lock-keywords-2' but detects declarations in a more
accurate way that works in most cases for arbitrary types without the
need for `java-font-lock-extra-types'.")

(defvar java-font-lock-keywords java-font-lock-keywords-3
  "Default expressions to highlight in Java mode.")

;;; IDL.

(c-override-default-keywords 'idl-font-lock-keywords
			     (c-lang-var c-matchers-3 idl))

(defconst idl-font-lock-keywords-1 (c-lang-var c-matchers-1 idl)
  "Subdued level highlighting for IDL mode.
Fontifies nothing except the syntactic fontification of strings and
comments.")

(defconst idl-font-lock-keywords-2 (c-lang-var c-matchers-2 idl)
  "Medium level highlighting for IDL mode.
In addition to `idl-font-lock-keywords-1', this adds fontification of
keywords, simple types, declarations that are easy to recognize, and
the user defined types on `idl-font-lock-extra-types'.")

(defconst idl-font-lock-keywords-3 (c-lang-var c-matchers-3 idl)
  "Gaudy level highlighting for IDL mode.
Like `idl-font-lock-keywords-2' but detects declarations in a more
accurate way that works in most cases for arbitrary types without the
need for `idl-font-lock-extra-types'.")

(defvar idl-font-lock-keywords idl-font-lock-keywords-3
  "Default expressions to highlight in IDL mode.")

;;; Pike.

(c-override-default-keywords 'pike-font-lock-keywords
			     (c-lang-var c-matchers-4 pike))

(defconst pike-font-lock-keywords-1 (c-lang-var c-matchers-1 pike)
  "Subdued level highlighting for Pike mode.
Fontifies only preprocessor directives (in addition to the syntactic
fontification of strings and comments).")

(defconst pike-font-lock-keywords-2 (c-lang-var c-matchers-2 pike)
  "Medium level highlighting for Pike mode.
In addition to `pike-font-lock-keywords-1', this adds fontification of
keywords, simple types, declarations that are easy to recognize, and
the user defined types on `pike-font-lock-extra-types'.")

(defconst pike-font-lock-keywords-3 (c-lang-var c-matchers-3 pike)
  "Gaudy level highlighting for Pike mode.
Like `pike-font-lock-keywords-2' but detects declarations in a more
accurate way that works in most cases for arbitrary types without the
need for `pike-font-lock-extra-types'.")

(defconst pike-font-lock-keywords-4 (c-lang-var c-matchers-4 pike)
  "Extra gaudy level highlighting for Pike mode.
In addition to `pike-font-lock-keywords-3', this adds fontification of
refdoc comments and the markup inside them.")

(defvar pike-font-lock-keywords pike-font-lock-keywords-4
  "Default expressions to highlight in Pike mode.")


(cc-provide 'cc-fonts)

;;; cc-fonts.el ends here
