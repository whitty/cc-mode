;;; cc-engine.el --- core syntax guessing engine for CC mode

;; Copyright (C) 1985,1987,1992-2001 Free Software Foundation, Inc.

;; Authors:    2000- Martin Stjernholm
;;	       1998-1999 Barry A. Warsaw and Martin Stjernholm
;;             1992-1997 Barry A. Warsaw
;;             1987 Dave Detlefs and Stewart Clamen
;;             1985 Richard M. Stallman
;; Maintainer: bug-cc-mode@gnu.org
;; Created:    22-Apr-1997 (split from cc-mode.el)
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
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; The functions which have docstring documentation can be considered
;; part of an API which other packages can use in CC Mode buffers.
;; Otoh, undocumented functions and functions with the documentation
;; in comments are considered purely internal and can change semantics
;; or even disappear in the future.
;;
;; (This policy applies to CC Mode as a whole, not just this file.  It
;; probably also applies to many other Emacs packages, but here it's
;; clearly spelled out.)

;;; Code:

(eval-when-compile
  (let ((load-path
	 (if (and (boundp 'byte-compile-dest-file)
		  (stringp byte-compile-dest-file))
	     (cons (file-name-directory byte-compile-dest-file) load-path)
	   load-path)))
    (require 'cc-bytecomp)))

(cc-require 'cc-defs)
(cc-require 'cc-vars)
(cc-require 'cc-langs)

;; Silence the compiler.
(cc-bytecomp-defun buffer-syntactic-context) ; XEmacs


(defun c-calculate-state (arg prevstate)
  ;; Calculate the new state of PREVSTATE, t or nil, based on arg. If
  ;; arg is nil or zero, toggle the state. If arg is negative, turn
  ;; the state off, and if arg is positive, turn the state on
  (if (or (not arg)
	  (zerop (setq arg (prefix-numeric-value arg))))
      (not prevstate)
    (> arg 0)))


(defvar c-in-literal-cache t)
(defvar c-parsing-error nil)

;; KLUDGE ALERT: c-maybe-labelp is used to pass information between
;; c-crosses-statement-barrier-p and c-beginning-of-statement-1.  A
;; better way should be implemented, but this will at least shut up
;; the byte compiler.
(defvar c-maybe-labelp nil)

;; Macros used internally in c-beginning-of-statement-1 for the
;; automaton actions.
(defmacro c-bos-push-state ()
  '(setq stack (cons (cons state saved-pos)
		     stack)))
(defmacro c-bos-pop-state (&optional do-if-done)
  `(if (setq state (car (car stack))
	     saved-pos (cdr (car stack))
	     stack (cdr stack))
       t
     ,do-if-done
     (throw 'loop nil)))
(defmacro c-bos-pop-state-and-retry ()
  '(throw 'loop (setq state (car (car stack))
		      saved-pos (cdr (car stack))
		      ;; Throw nil if stack is empty, else throw non-nil.
		      stack (cdr stack))))
(defmacro c-bos-save-pos ()
  '(setq saved-pos (vector pos tok ptok pptok)))
(defmacro c-bos-restore-pos ()
  '(unless (eq (elt saved-pos 0) start)
     (setq pos (elt saved-pos 0)
	   tok (elt saved-pos 1)
	   ptok (elt saved-pos 2)
	   pptok (elt saved-pos 3))
     (goto-char pos)
     (setq sym nil)))
(defmacro c-bos-save-error-info (missing got)
  `(setq saved-pos (vector pos ,missing ,got)))
(defmacro c-bos-report-error ()
  '(unless noerror
     (setq c-parsing-error
	   (format "No matching `%s' found for `%s' on line %d"
		   (elt saved-pos 1)
		   (elt saved-pos 2)
		   (1+ (count-lines (point-min)
				    (c-point 'bol (elt saved-pos 0))))))))

(defun c-beginning-of-statement-1 (&optional lim ignore-labels
					     noerror comma-delim)
  "Move to the start of the current statement or declaration, or to
the previous one if already at the beginning of one.  Only
statements/declarations on the same level are considered, i.e. don't
move into or out of sexps (not even normal expression parentheses).

Stop at statement continuation tokens like \"else\", \"catch\", \"finally\"
and the \"while\" in \"do ... while\" if the start point is within the
continuation.  If starting at such a token, move to the corresponding
statement start.  If at the beginning of a statement, move to the closest
containing statement if there is any.  This might also stop at a continuation
clause.

Labels are treated as separate statements if IGNORE-LABELS is non-nil.
The function is not overly intelligent in telling labels from other
uses of colons; if used outside a statement context it might trip up
on e.g. inherit colons, so IGNORE-LABELS should be used then.  There
should be no such mistakes in a statement context, however.

Macros are ignored unless point is within one, in which case the
content of the macro is treated as normal code.  Aside from any normal
statement starts found in it, stop at the first token of the content
in the macro, i.e. the expression of an \"#if\" or the start of the
definition in a \"#define\".  Also stop at start of macros before
leaving them.

Return 'label if stopped at a label, 'same if stopped at the beginning
of the current statement, 'up if stepped to a containing statement,
'previous if stepped to a preceding statement, 'beginning if stepped
from a statement continuation clause to its start clause, or 'macro if
stepped to a macro start.  Note that 'same and not 'label is returned
if stopped at the same label without crossing the colon character.

LIM may be given to limit the search.  If the search hits the limit,
point will be left at the closest following token, or at the start
position if that is less ('same is returned in this case).

NOERROR turns off error logging to `c-parsing-error'.

Normally only ';' is considered to delimit statements, but if
COMMA-DELIM is non-nil then ',' is treated likewise."

  ;; The bulk of this function is a pushdown automaton that looks at statement
  ;; boundaries and the tokens (such as "while") in c-opt-block-stmt-key.  Its
  ;; purpose is to keep track of nested statements, ensuring that such
  ;; statments are skipped over in their entirety (somewhat akin to what C-M-p
  ;; does with nested braces/brackets/parentheses).
  ;;
  ;; Note: The position of a boundary is the following token.
  ;;
  ;; Beginning with the current token (the one following point), move back one
  ;; sexp at a time (where a sexp is, more or less, either a token or the
  ;; entire contents of a brace/bracket/paren pair).  Each time a statement
  ;; boundary is crossed or a "while"-like token is found, update the state of
  ;; the PDA.  Stop at the beginning of a statement when the stack (holding
  ;; nested statement info) is empty and the position has been moved.
  ;;
  ;; The following variables constitue the PDA:
  ;;
  ;; sym:    This is either the "while"-like token (e.g. 'for) we've just
  ;;         scanned back over, 'boundary if we've just gone back over a
  ;;         statement boundary, or nil otherwise.
  ;; state:  takes one of the values (nil else else-boundary while
  ;;         while-boundary catch catch-boundary).
  ;;         nil means "no "while"-like token yet scanned".
  ;;         'else, for example, means "just gone back over an else".
  ;;         'else-boundary means "just gone back over a statement boundary
  ;;         immediately after having gone back over an else".
  ;; saved-pos: A vector of either saved positions (tok ptok pptok, etc.) or
  ;;         of error reporting information.
  ;; stack:  The stack onto which the PDA pushes its state.  Each entry
  ;;         consists of a saved value of state and saved-pos.  An entry is
  ;;         pushed when we move back over a "continuation" token (e.g. else)
  ;;         and popped when we encounter the corresponding opening token
  ;;         (e.g. if).
  ;;
  ;;
  ;; The following diagram briefly outlines the PDA.  
  ;;
  ;; Common state:
  ;;   "else": Push state, goto state `else'.
  ;;   "while": Push state, goto state `while'.
  ;;   "catch" or "finally": Push state, goto state `catch'.
  ;;   boundary: Pop state.
  ;;   other: Do nothing special.
  ;;
  ;; State `else':
  ;;   boundary: Goto state `else-boundary'.
  ;;   other: Error, pop state, retry token.
  ;;
  ;; State `else-boundary':
  ;;   "if": Pop state.
  ;;   boundary: Error, pop state.
  ;;   other: See common state.
  ;;
  ;; State `while':
  ;;   boundary: Save position, goto state `while-boundary'.
  ;;   other: Pop state, retry token.
  ;;
  ;; State `while-boundary':
  ;;   "do": Pop state.
  ;;   boundary: Restore position if it's not at start, pop state. [*see below]
  ;;   other: See common state.
  ;;
  ;; State `catch':
  ;;   boundary: Goto state `catch-boundary'.
  ;;   other: Error, pop state, retry token.
  ;;
  ;; State `catch-boundary':
  ;;   "try": Pop state.
  ;;   "catch": Goto state `catch'.
  ;;   boundary: Error, pop state.
  ;;   other: See common state.
  ;;
  ;; [*] In the `while-boundary' state, we had pushed a 'while state, and were
  ;; searching for a "do" which would have opened a do-while.  If we didn't
  ;; find it, we discard the analysis done since the "while", go back to this
  ;; token in the buffer and restart the scanning there, this time WITHOUT
  ;; pushing the 'while state onto the stack.
  ;;
  ;; In addition to the above there is some special handling of labels
  ;; and macros.

  (let ((case-fold-search nil)
	(start (point))
	macro-start
	(delims (if comma-delim '(?\; ?,) '(?\;)))
	(c-stmt-delim-chars (if comma-delim
				c-stmt-delim-chars-with-comma
			      c-stmt-delim-chars))
	pos				; Current position.
	boundary-pos      ; Position of last stmt boundary character (e.g. ;).
	after-labels-pos		; Value of tok after first found colon.
	last-label-pos			; Value of tok after last found colon.
	sym         ; Symbol just scanned back over (e.g. 'while or
		    ; 'boundary). See above
	state                     ; Current state in the automaton. See above.
	saved-pos			; Current saved positions. See above
	stack				; Stack of conses (state . saved-pos).
	(cond-key (or c-opt-block-stmt-key ; regexp which matches "for", "if", etc.
		      "\\<\\>"))	; Matches nothing.
	(ret 'same)                     ; Return value.
	tok ptok pptok			; Pos of last three sexps or bounds.
	c-in-literal-cache c-maybe-labelp saved)

    (save-restriction
      (if lim (narrow-to-region lim (point-max)))

      (if (save-excursion
	    (and (c-beginning-of-macro)
		 (/= (point) start)))
	  (setq macro-start (point)))

      ;; Try to skip back over unary operator characters, to register
      ;; that we've moved.
      (while (progn
	       (setq pos (point))
	       (c-backward-syntactic-ws)
	       (/= (skip-chars-backward "-+!*&~@`#") 0)))

      ;; Skip back over any semicolon here.  If it was a bare semicolon, we're
      ;; done.  Later on we ignore the boundaries for statements that doesn't
      ;; contain any sexp.  The only thing that is affected is that the error
      ;; checking is a little less strict, and we really don't bother.
      (if (and (memq (char-before) delims)
	       (progn (forward-char -1)
		      (setq saved (point))
		      (c-backward-syntactic-ws)
		      (or (memq (char-before) delims)
			  (memq (char-before) '(?: nil))
			  (eq (char-syntax (char-before)) ?\())))
	  (setq ret 'previous
		pos saved)

	;; Begin at start and not pos to detect macros if we stand
	;; directly after the #.
	(goto-char start)
	(if (looking-at "\\<\\|\\W")
	    ;; Record this as the first token if not starting inside it.
	    (setq tok start))

        ;; The following while loop goes back one sexp (balanced parens,
        ;; etc. with contents, or symbol or suchlike) each iteration.  This
        ;; movement is accomplished with a call to scan-sexps approx 130 lines
        ;; below.
	(while
	    (catch 'loop ;; Throw nil to break, non-nil to continue.
	      (cond
	       ;; Check for macro start.
	       ((save-excursion
		  (and macro-start
		       (looking-at "[ \t]*[a-zA-Z0-9!]")
		       (progn (skip-chars-backward " \t")
			      (eq (char-before) ?#))
		       (progn (setq saved (1- (point)))
			      (beginning-of-line)
			      (not (eq (char-before (1- (point))) ?\\)))
		       (progn (skip-chars-forward " \t")
			      (eq (point) saved))))
		(goto-char saved)
		(if (and (c-forward-to-cpp-define-body)
			 (progn (c-forward-syntactic-ws start)
				(< (point) start)))
		    ;; Stop at the first token in the content of the macro.
		    (setq pos (point)
			  ignore-labels t) ; Avoid the label check on exit.
		  (setq pos saved
			ret 'macro
			ignore-labels t))
		(throw 'loop nil))

	       ;; Do a round through the automaton if we've just passed a
	       ;; statement boundary or passed a "while"-like token.
	       ((or sym
		    (and (looking-at cond-key)
			 (setq sym (intern (match-string 1)))))

		(when (and (< pos start) (null stack))
		  (throw 'loop nil))

		;; The PDA state handling.
                ;;
                ;; Refer to the description of the PDA in the openining
                ;; comments.  In the following OR form, the first leaf
                ;; attempts to handles one of the specific actions detailed
                ;; (e.g., finding token "if" whilst in state `else-boundary').
                ;; We drop through to the second leaf (which handles common
                ;; state) if no specific handler is found in the first cond.
                ;; If a parsing error is detected (e.g. an "else" with no
                ;; preceding "if"), we throw to the enclosing catch.
                ;;
                ;; Note that the (eq state 'else) means
		;; "we've just passed an else", NOT "we're looking for an
		;; else".
		(or (cond
		     ((eq state 'else)
		      (if (eq sym 'boundary)
			  (setq state 'else-boundary)
			(c-bos-report-error)
			(c-bos-pop-state-and-retry)))

		     ((eq state 'else-boundary)
		      (cond ((eq sym 'if)
			     (c-bos-pop-state (setq ret 'beginning)))
			    ((eq sym 'boundary)
			     (c-bos-report-error)
			     (c-bos-pop-state))))

		     ((eq state 'while)
		      (if (and (eq sym 'boundary)
			       ;; Since this can cause backtracking we do a
			       ;; little more careful analysis to avoid it:
			       ;; If there's a label in front of the while
			       ;; it can't be part of a do-while.
			       (not after-labels-pos))
			  (progn (c-bos-save-pos)
				 (setq state 'while-boundary))
			(c-bos-pop-state-and-retry))) ; Can't be a do-while

		     ((eq state 'while-boundary)
		      (cond ((eq sym 'do)
			     (c-bos-pop-state (setq ret 'beginning)))
			    ((eq sym 'boundary) ; isn't a do-while
			     (c-bos-restore-pos) ; the position of the while
			     (c-bos-pop-state)))) ; no longer searching for do.

		     ((eq state 'catch)
		      (if (eq sym 'boundary)
			  (setq state 'catch-boundary)
			(c-bos-report-error)
			(c-bos-pop-state-and-retry)))

		     ((eq state 'catch-boundary)
		      (cond
		       ((eq sym 'try)
			(c-bos-pop-state (setq ret 'beginning)))
		       ((eq sym 'catch)
			(setq state 'catch))
		       ((eq sym 'boundary)
			(c-bos-report-error)
			(c-bos-pop-state)))))

		    ;; This is state common.  We get here when the previous
		    ;; cond statement found no particular state handler.
		    (cond ((eq sym 'boundary)
			   ;; If we have a boundary at the start
			   ;; position we push a frame to go to the
			   ;; previous statement.
			   (if (>= pos start)
			       (c-bos-push-state)
			     (c-bos-pop-state)))
			  ((eq sym 'else)
			   (c-bos-push-state)
			   (c-bos-save-error-info 'if 'else)
			   (setq state 'else))
			  ((eq sym 'while)
			   (when (or (not pptok)
				     (memq (char-after pptok) delims))
			     ;; Since this can cause backtracking we do a
			     ;; little more careful analysis to avoid it: If
			     ;; the while isn't followed by a semicolon it
			     ;; can't be a do-while.
			     (c-bos-push-state)
			     (setq state 'while)))
			  ((memq sym '(catch finally))
			   (c-bos-push-state)
			   (c-bos-save-error-info 'try sym)
			   (setq state 'catch))))

		(when c-maybe-labelp
		  ;; We're either past a statement boundary or at the
		  ;; start of a statement, so throw away any label data
		  ;; for the previous one.
		  (setq after-labels-pos nil
			last-label-pos nil
			c-maybe-labelp nil))))

	      ;; Step to the previous sexp, but not if we crossed a
	      ;; boundary, since that doesn't consume an sexp.
	      (if (eq sym 'boundary)
		  (setq ret 'previous)
                ;; HERE IS THE SINGLE PLACE INSIDE THE PDA LOOP WHERE WE MOVE
                ;; BACKWARDS THROUGH THE SOURCE. The following loop goes back
                ;; one sexp and then only loops in special circumstances (line
                ;; continuations and skipping past entire macros).
		(while
		    (progn
		      (or (c-safe (goto-char (scan-sexps (point) -1)) t)
			  ;; Give up if we hit an unbalanced block.
			  ;; Since the stack won't be empty the code
			  ;; below will report a suitable error.
			  (throw 'loop nil))
		      (cond ((looking-at "\\\\$")
			     ;; Step again if we hit a line continuation.
			     t)
			    (macro-start
			     ;; If we started inside a macro then this
			     ;; sexp is always interesting.
			     nil)
			    (t
			     ;; Otherwise check that we didn't step
			     ;; into a macro from the end.
			     (let ((macro-start
				    (save-excursion
				      (and (c-beginning-of-macro)
					   (point)))))
			       (when macro-start
				 (goto-char macro-start)
				 t))))))

		;; Did the last movement by a sexp cross a statement boundary?
		(when (save-excursion
			(if (if (eq (char-after) ?{)
				(c-looking-at-inexpr-block lim nil)
			      (eq (char-syntax (char-after)) ?\())
			    ;; Need to move over parens and
			    ;; in-expression blocks to get a good start
			    ;; position for the boundary check.
			    (c-forward-sexp 1))
			(setq boundary-pos (c-crosses-statement-barrier-p
					    (point) pos)))
		  (setq pptok ptok
			ptok tok
			tok boundary-pos
			sym 'boundary)
		  (throw 'loop t))) ; like a C "continue".  Analyze the next sexp.

	      (when (and (numberp c-maybe-labelp) (not ignore-labels))
		;; c-crosses-statement-barrier-p has found a colon, so
		;; we might be in a label now.
		(if (not after-labels-pos)
		    (setq after-labels-pos tok))
		(setq last-label-pos tok
		      c-maybe-labelp t))

	      ;; ObjC method def?
	      (when (and c-opt-method-key
			 (setq saved (c-in-method-def-p)))
		(setq pos saved
		      ignore-labels t)	; Avoid the label check on exit.
		(throw 'loop nil))

              ;; We've moved back by a sexp, so update the token positions. 
	      (setq sym nil
		    pptok ptok
		    ptok tok
		    tok (point)
		    pos tok)))		; Not nil (for the while loop).

	;; If the stack isn't empty there might be errors to report.
	(while stack
	  (if (and (vectorp saved-pos) (eq (length saved-pos) 3))
	      (c-bos-report-error))
	  (setq saved-pos (cdr (car stack))
		stack (cdr stack)))

	(when (and (eq ret 'same)
		   (not (memq sym '(boundary ignore nil))))
	  ;; Need to investigate closer whether we've crossed
	  ;; between a substatement and its containing statement.
	  (if (setq saved (if (looking-at c-block-stmt-1-key)
			      ptok
			    pptok))
	      (cond ((> start saved) (setq pos saved))
		    ((= start saved) (setq ret 'up)))))

	(when (and c-maybe-labelp
		   (not ignore-labels)
		   (not (eq ret 'beginning))
		   after-labels-pos)
	  ;; We're in a label.  Maybe we should step to the statement
	  ;; after it.
	  (if (< after-labels-pos start)
	      (setq pos after-labels-pos)
	    (setq ret 'label)
	    (if (< last-label-pos start)
		(setq pos last-label-pos)))))

      ;; Skip over the unary operators that can start the statement.
      (goto-char pos)
      (while (progn
	       (c-backward-syntactic-ws)
	       (/= (skip-chars-backward "-+!*&~@`#") 0))
	(setq pos (point)))
      (goto-char pos)
      ret)))

(defun c-crosses-statement-barrier-p (from to)
  "Return non-nil if buffer positions FROM to TO cross one or more
statement or declaration boundaries.  The returned value is actually
the position of the earliest boundary char.

The variable `c-maybe-labelp' is set to the position of the first `:' that
might start a label (i.e. not part of `::' and not preceded by `?').  If a
single `?' is found, then `c-maybe-labelp' is cleared."
  (let ((skip-chars c-stmt-delim-chars)
	lit-range)
    (save-excursion
      (catch 'done
	(goto-char from)
	(while (progn (skip-chars-forward skip-chars to)
		      (< (point) to))
	  (if (setq lit-range (c-literal-limits from))
	      (goto-char (setq from (cdr lit-range)))
	    (cond ((eq (char-after) ?:)
		   (forward-char)
		   (if (and (eq (char-after) ?:)
			    (< (point) to))
		       ;; Ignore scope operators.
		       (forward-char)
		     (setq c-maybe-labelp (1- (point)))))
		  ((eq (char-after) ??)
		   ;; A question mark.  Can't be a label, so stop
		   ;; looking for more : and ?.
		   (setq c-maybe-labelp nil
			 skip-chars (substring c-stmt-delim-chars 0 -2)))
		  (t (throw 'done (point))))))
	nil))))


;; A set of functions that covers various idiosyncrasies in
;; implementations of `forward-comment'.
;;
;; Note: Some emacsen considers incorrectly that any line comment
;; ending with a backslash continues to the next line.  I can't think
;; of any way to work around that in a reliable way without changing
;; the buffer, though.  Suggestions welcome. ;) (No, temporarily
;; changing the syntax for backslash doesn't work since we must treat
;; escapes in string literals correctly.)

(defun c-forward-single-comment ()
  "Move forward past whitespace and the closest following comment, if any.
Return t if a comment was found, nil otherwise.  In either case, the
point is moved past the following whitespace.  Line continuations,
i.e. a backslashes followed by line breaks, are treated as whitespace.
The line breaks that end line comments are considered to be the
comment enders, so the point will be put on the beginning of the next
line if it moved past a line comment."

  (let ((start (point)))
    (when (looking-at "\\([ \t\n\r\f]\\|\\\\[\n\r]\\)+")
      (goto-char (match-end 0)))

    (when (forward-comment 1)
      (if (eobp)
	  ;; Some emacsen (e.g. XEmacs 21) return t when moving
	  ;; forwards at eob.
	  nil

	;; Emacs includes the ending newline in a b-style (c++)
	;; comment, but XEmacs doesn't.  We depend on the Emacs
	;; behavior (which also is symmetric).
	(if (and (eolp) (elt (parse-partial-sexp start (point)) 7))
	    (condition-case nil (forward-char 1)))

	t))))

(defun c-forward-comments ()
  "Move forward past all following whitespace and comments.
Line continuations, i.e. a backslashes followed by line breaks, are
treated as whitespace."

  (while (or
	  ;; If forward-comment in at least XEmacs 21 is given a large
	  ;; positive value, it'll loop all the way through if it hits
	  ;; eob.
	  (and (forward-comment 5)
	       ;; Some emacsen (e.g. XEmacs 21) return t when moving
	       ;; forwards at eob.
	       (not (eobp)))

	  (when (looking-at "\\\\[\n\r]")
	    (forward-char 2)
	    t))))

(defun c-backward-single-comment ()
  "Move backward past whitespace and the closest preceding comment, if any.
Return t if a comment was found, nil otherwise.  In either case, the
point is moved past the preceding whitespace.  Line continuations,
i.e. a backslashes followed by line breaks, are treated as whitespace.
The line breaks that end line comments are considered to be the
comment enders, so the point cannot be at the end of the same line to
move over a line comment."

  (let ((start (point)))
    ;; When we got newline terminated comments, forward-comment in all
    ;; supported emacsen so far will stop at eol of each line not
    ;; ending with a comment when moving backwards.  This corrects for
    ;; that, and at the same time handles line continuations.
    (while (progn
	     (skip-chars-backward " \t\n\r\f")
	     (and (looking-at "[\n\r]")
		  (eq (char-before) ?\\)
		  (< (point) start)))
      (backward-char))

    (if (bobp)
	;; Some emacsen (e.g. Emacs 19.34) return t when moving
	;; backwards at bob.
	nil

      ;; Leave point after the closest following newline if we've
      ;; backed up over any above, since forward-comment won't move
      ;; backward over a line comment if it starts at the end of that
      ;; line.
      (if (and (looking-at "\\s *[\n\r]")
	       (<= (match-end 0) start))
	  (goto-char (match-end 0)))

      (if (forward-comment -1)
	  (if (eolp)
	      ;; If forward-comment above succeeded and we're at eol
	      ;; then the newline we moved over above didn't end a
	      ;; line comment, so we give it another go.
	      (forward-comment -1)
	    t)))))

(defun c-backward-comments ()
  "Move backward past all preceding whitespace and comments.
Line continuations, i.e. a backslashes followed by line breaks, are
treated as whitespace.  The line breaks that end line comments are
considered to be the comment enders, so the point cannot be at the end
of the same line to move over a line comment."

  (let ((start (point)))
    (while (or
	    ;; If forward-comment in Emacs 19.34 is given a large
	    ;; negative value, it'll loop all the way through if it
	    ;; hits bob.
	    (and (forward-comment -5)
		 ;; Some emacsen (e.g. Emacs 19.34) return t when
		 ;; moving backwards at bob.
		 (not (bobp)))

	    ;; XEmacs treats line continuations as whitespace but only
	    ;; in the backward direction, which seems a bit odd.
	    ;; Anyway, this is necessary for Emacs.
	    (when (and (looking-at "[\n\r]")
		       (eq (char-before) ?\\)
		       (< (point) start))
	      (backward-char)
	      t)))))


;; This is a dynamically bound cache used together with
;; c-query-macro-start and c-query-and-set-macro-start.  It only works
;; as long as point doesn't cross a macro boundary.
(defvar c-macro-start 'unknown)

(defsubst c-query-and-set-macro-start ()
  (if (symbolp c-macro-start)
      (setq c-macro-start (save-excursion
			    (and (c-beginning-of-macro)
				 (point))))
    c-macro-start))

(defsubst c-query-macro-start ()
  (if (symbolp c-macro-start)
      (save-excursion
	(and (c-beginning-of-macro)
	     (point)))
    c-macro-start))

(defun c-beginning-of-macro (&optional lim)
  "Go to the beginning of a preprocessor directive.
Leave point at the beginning of the directive and return t if in one,
otherwise return nil and leave point unchanged."
  (let ((here (point)))
    (save-restriction
      (if lim (narrow-to-region lim (point-max)))
      (beginning-of-line)
      (while (eq (char-before (1- (point))) ?\\)
	(forward-line -1))
      (back-to-indentation)
      (if (and (<= (point) here)
	       (looking-at "#[ \t]*[a-zA-Z0-9!]"))
	  t
	(goto-char here)
	nil))))

(defun c-end-of-macro ()
  "Go to the end of a preprocessor directive.
More accurately, move point to the end of the closest following line
that doesn't end with a line continuation backslash."
  (while (progn
	   (end-of-line)
	   (when (and (eq (char-before) ?\\)
		      (not (eobp)))
	     (forward-char)
	     t))))

(defun c-forward-syntactic-ws (&optional limit)
  "Forward skip of syntactic whitespace.
Syntactic whitespace is defined as whitespace characters, comments,
and preprocessor directives.  However if point starts inside a comment
or preprocessor directive, the content of it is not treated as
whitespace.

LIMIT sets an upper limit of the forward movement, if specified.  If
LIMIT or the end of the buffer is reached inside a comment or
preprocessor directive, the point will be left there."

  (let ((here (point-max)))
    (or limit (setq limit here))

    (while (/= here (point))
      (c-forward-comments)
      (setq here (point))

      (cond
       ;; Skip preprocessor directives.
       ((and (looking-at "#[ \t]*[a-zA-Z0-9!]")
	     (save-excursion
	       (skip-chars-backward " \t")
	       (bolp)))
	(end-of-line)
	(while (and (<= (point) limit)
		    (eq (char-before) ?\\)
			 (= (forward-line 1) 0))
	  (end-of-line))
	(when (> (point) limit)
	  ;; Don't move past the macro if that'd take us past the limit.
	  (goto-char here)))

       ;; Skip in-comment line continuations (used for Pike refdoc).
       ((and c-opt-in-comment-lc (looking-at c-opt-in-comment-lc))
	(goto-char (match-end 0)))))

    (goto-char (min (point) limit))))

(defun c-backward-syntactic-ws (&optional limit)
  "Backward skip of syntactic whitespace.
Syntactic whitespace is defined as whitespace characters, comments,
and preprocessor directives.  However if point starts inside a comment
or preprocessor directive, the content of it is not treated as
whitespace.

LIMIT sets a lower limit of the backward movement, if specified.  If
LIMIT or the beginning of the buffer is reached inside a comment or
preprocessor directive, the point might be left anywhere between the
limit and the end of that comment or preprocessor directive."
  (let ((here (point-min))
	prev-pos)
    (or limit (setq limit here))

    (while (/= here (point))
      (setq prev-pos (point))
      (c-backward-comments)
      (setq here (point))

      (cond
       ((c-beginning-of-macro)
	(let ((macro-beg (point)))
	  (if (or (progn (goto-char prev-pos)
			 (beginning-of-line)
			 (and (c-safe (backward-char) t)
			      (eq (char-before) ?\\)))
		  (<= (point) macro-beg)
		  (< macro-beg limit))
	      ;; Don't move past the macro if we began inside it, or
	      ;; if the move would take us past the limit.  We detect
	      ;; the inside of the macro by checking that the previous
	      ;; line doesn't end with "\" or that the macro begins on
	      ;; this line.  That means that the position at the end
	      ;; of the last line of the macro is also considered to
	      ;; be within it.
	      (goto-char here)
	    (goto-char macro-beg))))

       ;; Skip in-comment line continuations (used for Pike refdoc).
       ((and c-opt-in-comment-lc
	     (save-excursion
	       (and (c-safe (beginning-of-line)
			    (backward-char 2)
			    t)
		    (looking-at c-opt-in-comment-lc)
		    (eq (match-end 0) here))))
	(goto-char (match-beginning 0)))))

    (goto-char (max (point) limit))))

(defun c-forward-token-1 (&optional count balanced lim)
  "Move forward by tokens.
A token is defined as all symbols and identifiers which aren't
syntactic whitespace \(note that e.g. \"->\" is considered to be two
tokens).  Point is always either left at the beginning of a token or
not moved at all.  COUNT specifies the number of tokens to move; a
negative COUNT moves in the opposite direction.  A COUNT of 0 moves to
the next token beginning only if not already at one.  If BALANCED is
true, move over balanced parens, otherwise move into them.  Also, if
BALANCED is true, never move out of an enclosing paren.  LIM sets the
limit for the movement and defaults to the point limit.

Return the number of tokens left to move \(positive or negative).  If
BALANCED is true, a move over a balanced paren counts as one.  Note
that if COUNT is 0 and no appropriate token beginning is found, 1 will
be returned.  Thus, a return value of 0 guarantees that point is at
the requested position and a return value less \(without signs) than
COUNT guarantees that point is at the beginning of some token."
  (or count (setq count 1))
  (if (< count 0)
      (- (c-backward-token-1 (- count) balanced lim))
    (let ((jump-syntax (if balanced
			   '(?w ?_ ?\( ?\) ?\" ?\\ ?/ ?$ ?')
			 '(?w ?_ ?\" ?\\ ?/ ?')))
	  (last (point))
	  (prev (point)))
      (save-restriction
	(if lim (narrow-to-region (point-min) lim))
	(if (/= (point)
		(progn (c-forward-syntactic-ws) (point)))
	    ;; Skip whitespace.  Count this as a move if we did in fact
	    ;; move and aren't out of bounds.
	    (or (eobp)
		(setq count (max (1- count) 0))))
	(if (and (= count 0)
		 (or (and (memq (char-syntax (or (char-after) ? )) '(?w ?_))
			  (memq (char-syntax (or (char-before) ? )) '(?w ?_)))
		     (eobp)))
	    ;; If count is zero we should jump if in the middle of a
	    ;; token or if there is whitespace between point and the
	    ;; following token beginning.
	    (setq count 1))
	(if (eobp)
	    (goto-char last)
	  ;; Avoid having the limit tests inside the loop.
	  (condition-case nil
	      (while (> count 0)
		(setq prev last
		      last (point))
		(if (memq (char-syntax (char-after)) jump-syntax)
		    (goto-char (scan-sexps (point) 1))
		  (forward-char))
		(c-forward-syntactic-ws)
		(setq count (1- count)))
	    (error (goto-char last)))
	  (when (eobp)
	    (goto-char prev)
	    (setq count (1+ count)))))
      count)))

(defun c-backward-token-1 (&optional count balanced lim)
  "Move backward by tokens.
See `c-forward-token-1' for details."
  (or count (setq count 1))
  (if (< count 0)
      (- (c-forward-token-1 (- count) balanced lim))
    (let ((jump-syntax (if balanced
			   '(?w ?_ ?\( ?\) ?\" ?\\ ?/ ?$ ?')
			 '(?w ?_ ?\" ?\\ ?/ ?')))
	  last)
      (if (and (= count 0)
	       (or (and (memq (char-syntax (or (char-after) ? )) '(?w ?_))
			(memq (char-syntax (or (char-before) ? )) '(?w ?_)))
		   (/= (point)
		       (save-excursion
			 (c-forward-syntactic-ws (1+ lim))
			 (point)))
		   (eobp)))
	  ;; If count is zero we should jump if in the middle of a
	  ;; token or if there is whitespace between point and the
	  ;; following token beginning.
	  (setq count 1))
      (save-restriction
	(if lim (narrow-to-region lim (point-max)))
	(or (bobp)
	    (progn
	      ;; Avoid having the limit tests inside the loop.
	      (condition-case nil
		  (while (progn
			   (setq last (point))
			   (> count 0))
		    (c-backward-syntactic-ws)
		    (if (memq (char-syntax (char-before)) jump-syntax)
			(goto-char (scan-sexps (point) -1))
		      (backward-char))
		    (setq count (1- count)))
		(error (goto-char last)))
	      (if (bobp) (goto-char last)))))
      count)))

(defun c-syntactic-re-search-forward (regexp &optional bound noerror count
				      paren-level not-inside-token)
  "Like `re-search-forward', but only report matches that are found
in syntactically significant text.  I.e. matches in comments, macros
or string literals are ignored.  The start point is assumed to be
outside any comment, macro or string literal, or else the content of
that region is taken as syntactically significant text.

If PAREN-LEVEL is non-nil, an additional restriction is added to
ignore matches in nested paren sexps, and the search will also not go
outside the current paren sexp.

If NOT-INSIDE-TOKEN is non-nil, matches in the middle of tokens are
ignored.  Things like multicharacter operators and special symbols
\(e.g. \"`()\" in Pike) are handled but currently not floating point
constants.

If there is at least one submatch in the regexp and the first one
matches, the end position of that submatch is used to check for
syntactic significance, otherwise the start position of the whole
match is used."

  (or bound (setq bound (point-max)))
  (or count (setq count 1))
  (if paren-level (setq paren-level -1))

  (let ((start (point))
	(pos (point))
	(last-token-end-pos (point-min))
	match-pos syntactic-match-pos state)

    (condition-case err
	(while (and (> count 0)
		    (progn
		      ;; Kludge: XEmacs (up to and including 21.4 at
		      ;; least) has a bug where it doesn't clear the
		      ;; submatches from earlier searches, so when we
		      ;; do (match-end 1) below we could get some old
		      ;; result if REGEXP doesn't contain a submatch.
		      (set-match-data nil)
		      (re-search-forward regexp bound noerror)))

	  (setq match-pos (point)
		syntactic-match-pos (or (match-end 1) (match-beginning 0))
		state (parse-partial-sexp pos syntactic-match-pos
					  paren-level nil state)
		pos syntactic-match-pos)

	  (cond ((elt state 3)
		 ;; Match inside a string.  Skip to the end of it
		 ;; before continuing.
		 (let ((ender (make-string 1 (elt state 3))))
		   (while (if (search-forward ender bound noerror)
			      (progn
				(setq state (parse-partial-sexp pos (point)
								nil nil state)
				      pos (point))
				(elt state 3))
			    (setq count -1)
			    nil))))

		((elt state 7)
		 ;; Match inside a line comment.  Skip to eol.  Use
		 ;; `re-search-forward' instead of
		 ;; `skip-chars-forward' to get the right bound
		 ;; behavior.
		 (or (re-search-forward "[\n\r]" bound noerror)
		     (setq count -1)))

		((elt state 4)
		 ;; Match inside a block comment.  Skip to the '*/'.
		 (or (search-forward "*/" bound noerror)
		     (setq count -1)))

		((and (not (elt state 5))
		      (eq (char-before syntactic-match-pos) ?/)
		      (memq (char-after syntactic-match-pos) '(?/ ?*)))
		 ;; Match in the middle of the opener of a block or
		 ;; line comment.
		 (or (if (= (char-after syntactic-match-pos) ?/)
			 (re-search-forward "[\n\r]" bound noerror)
		       (search-forward "*/" bound noerror))
		     (setq count -1)))

		((and not-inside-token
		      (> syntactic-match-pos last-token-end-pos)
		      (save-match-data
			(let (tmp-pos)
			  (save-excursion
			    (when (zerop (skip-syntax-backward
					  ".()" last-token-end-pos))
			      (backward-char))
			    (while (if (looking-at
					c-multichar-op-sym-token-regexp)
				       (< (setq tmp-pos (match-end 0)) pos)
				     (setq tmp-pos nil))
			      (goto-char tmp-pos)))
			  (and tmp-pos
			       (> tmp-pos syntactic-match-pos)
			       (progn (goto-char tmp-pos)
				      (skip-syntax-forward "w_")
				      (setq last-token-end-pos (point))
				      t)))))
		 ;; Match inside a token.
		 (when (> (point) bound)
		   (if noerror
		       (setq count -1)
		     (signal 'search-failed "end of token"))))

		((save-excursion
		   (save-match-data
		     (c-beginning-of-macro start)))
		 ;; Match inside a macro.  Skip to the end of it.
		 (c-end-of-macro)
		 (when (> (point) bound)
		   (if noerror
		       (setq count -1)
		     (signal 'search-failed "end of macro"))))

		((and paren-level (/= (car state) 0))
		 (if (> (car state) 0)
		     ;; Match inside a nested paren sexp.  Skip out of it.
		     (setq state (parse-partial-sexp pos bound 0 nil state)
			   pos (point))
		   ;; Have exited the current paren sexp.  The
		   ;; parse-partial-sexp above has left us just after
		   ;; the closing paren in this case.  Just make
		   ;; re-search-forward above fail in the appropriate
		   ;; way; we'll adjust the leave off point below if
		   ;; necessary.
		   (setq bound (point))))

		(t
		 ;; A real match.
		 (setq count (1- count)))))

      (error
       (goto-char start)
       (signal (car err) (cdr err))))

    (if (= count 0)
	(progn
	  (goto-char match-pos)
	  match-pos)

      ;; Search failed.  Set point as appropriate.
      (cond ((eq noerror t)
	     (goto-char start))
	    (paren-level
	     (if (eq (car (parse-partial-sexp pos bound -1 nil state)) -1)
		 (backward-char)))
	    (t
	     (goto-char bound)))
      nil)))


(defun c-in-literal (&optional lim detect-cpp)
  "Return the type of literal point is in, if any.
The return value is `c' if in a C-style comment, `c++' if in a C++
style comment, `string' if in a string literal, `pound' if DETECT-CPP
is non-nil and on a preprocessor line, or nil if somewhere else.
Optional LIM is used as the backward limit of the search.  If omitted,
or nil, `c-beginning-of-defun' is used.

The last point calculated is cached if the cache is enabled, i.e. if
`c-in-literal-cache' is bound to a two element vector."
  (if (and (vectorp c-in-literal-cache)
	   (= (point) (aref c-in-literal-cache 0)))
      (aref c-in-literal-cache 1)
    (let ((rtn (save-excursion
		 (let* ((lim (or lim (c-point 'bod)))
			(state (parse-partial-sexp lim (point))))
		   (cond
		    ((elt state 3) 'string)
		    ((elt state 4) (if (elt state 7) 'c++ 'c))
		    ((and detect-cpp (c-beginning-of-macro lim)) 'pound)
		    (t nil))))))
      ;; cache this result if the cache is enabled
      (if (not c-in-literal-cache)
	  (setq c-in-literal-cache (vector (point) rtn)))
      rtn)))

;; XEmacs has a built-in function that should make this much quicker.
;; I don't think we even need the cache, which makes our lives more
;; complicated anyway.  In this case, lim is only used to detect
;; cpp directives.
(defun c-fast-in-literal (&optional lim detect-cpp)
  (let ((context (buffer-syntactic-context)))
    (cond
     ((eq context 'string) 'string)
     ((eq context 'comment) 'c++)
     ((eq context 'block-comment) 'c)
     ((and detect-cpp (save-excursion (c-beginning-of-macro lim))) 'pound))))

(if (fboundp 'buffer-syntactic-context)
    (defalias 'c-in-literal 'c-fast-in-literal))

(defun c-literal-limits (&optional lim near not-in-delimiter)
  "Return a cons of the beginning and end positions of the comment or
string surrounding point (including both delimiters), or nil if point
isn't in one.  If LIM is non-nil, it's used as the \"safe\" position
to start parsing from.  If NEAR is non-nil, then the limits of any
literal next to point is returned.  \"Next to\" means there's only [
\t] between point and the literal.  The search for such a literal is
done first in forward direction.  If NOT-IN-DELIMITER is non-nil, the
case when point is inside a starting delimiter won't be recognized.
This only has effect for comments, which have starting delimiters with
more than one character."

  (save-excursion
    (let* ((pos (point))
	   (lim (or lim (c-point 'bod)))
	   (state (parse-partial-sexp lim (point))))

      (cond ((elt state 3)
	     ;; String.  Search backward for the start.
	     (while (elt state 3)
	       (search-backward (make-string 1 (elt state 3)))
	       (setq state (parse-partial-sexp lim (point))))
	     (cons (point) (or (c-safe (c-forward-sexp 1) (point))
			       (point-max))))

	    ((elt state 7)
	     ;; Line comment.  Search from bol for the comment starter.
	     (beginning-of-line)
	     (setq state (parse-partial-sexp lim (point))
		   lim (point))
	     (while (not (elt state 7))
	       (search-forward "//")	; Should never fail.
	       (setq state (parse-partial-sexp
			    lim (point) nil nil state)
		     lim (point)))
	     (backward-char 2)
	     (cons (point) (progn (c-forward-single-comment) (point))))

	    ((elt state 4)
	     ;; Block comment.  Search backward for the comment starter.
	     (while (elt state 4)
	       (search-backward "/*")	; Should never fail.
	       (setq state (parse-partial-sexp lim (point))))
	     (cons (point) (progn (c-forward-single-comment) (point))))

	    ((and (not not-in-delimiter)
		  (not (elt state 5))
		  (eq (char-before) ?/)
		  (looking-at "[/*]"))
	     ;; We're standing in a comment starter.
	     (backward-char 1)
	     (cons (point) (progn (c-forward-single-comment) (point))))

	    (near
	     (goto-char pos)

	     ;; Search forward for a literal.
	     (skip-chars-forward " \t")

	     (cond
	      ((eq (char-syntax (or (char-after) ?\ )) ?\") ; String.
	       (cons (point) (or (c-safe (c-forward-sexp 1) (point))
				 (point-max))))

	      ((looking-at "/[/*]")	; Line or block comment.
	       (cons (point) (progn (c-forward-single-comment) (point))))

	      (t
	       ;; Search backward.
	       (skip-chars-backward " \t")

	       (let ((end (point)) beg)
		 (cond
		  ((eq (char-syntax (or (char-before) ?\ )) ?\") ; String.
		   (setq beg (c-safe (c-backward-sexp 1) (point))))

		  ((and (c-safe (forward-char -2) t)
			(looking-at "*/"))
		   ;; Block comment.  Due to the nature of line
		   ;; comments, they will always be covered by the
		   ;; normal case above.
		   (goto-char end)
		   (c-backward-single-comment)
		   ;; If LIM is bogus, beg will be bogus.
		   (setq beg (point))))

		 (if beg (cons beg end))))))
	    ))))

(defun c-literal-limits-fast (&optional lim near not-in-delimiter)
  ;; Like c-literal-limits, but for emacsen whose `parse-partial-sexp'
  ;; returns the pos of the comment start.
  (save-excursion
    (let* ((pos (point))
	   (lim (or lim (c-point 'bod)))
	   (state (parse-partial-sexp lim (point))))

      (cond ((elt state 3)		; String.
	     (goto-char (elt state 8))
	     (cons (point) (or (c-safe (c-forward-sexp 1) (point))
			       (point-max))))

	    ((elt state 4)		; Comment.
	     (goto-char (elt state 8))
	     (cons (point) (progn (c-forward-single-comment) (point))))

	    ((and (not not-in-delimiter)
		  (not (elt state 5))
		  (eq (char-before) ?/)
		  (looking-at "[/*]"))
	     ;; We're standing in a comment starter.
	     (backward-char 1)
	     (cons (point) (progn (c-forward-single-comment) (point))))

	    (near
	     (goto-char pos)

	     ;; Search forward for a literal.
	     (skip-chars-forward " \t")

	     (cond
	      ((eq (char-syntax (or (char-after) ?\ )) ?\") ; String.
	       (cons (point) (or (c-safe (c-forward-sexp 1) (point))
				 (point-max))))

	      ((looking-at "/[/*]")	; Line or block comment.
	       (cons (point) (progn (c-forward-single-comment) (point))))

	      (t
	       ;; Search backward.
	       (skip-chars-backward " \t")

	       (let ((end (point)) beg)
		 (cond
		  ((eq (char-syntax (or (char-before) ?\ )) ?\") ; String.
		   (setq beg (c-safe (c-backward-sexp 1) (point))))

		  ((and (c-safe (forward-char -2) t)
			(looking-at "*/"))
		   ;; Block comment.  Due to the nature of line
		   ;; comments, they will always be covered by the
		   ;; normal case above.
		   (goto-char end)
		   (c-backward-single-comment)
		   ;; If LIM is bogus, beg will be bogus.
		   (setq beg (point))))

		 (if beg (cons beg end))))))
	    ))))

(if (c-safe (> (length (save-excursion (parse-partial-sexp 1 1))) 8))
    (defalias 'c-literal-limits 'c-literal-limits-fast))

(defun c-collect-line-comments (range)
  "If the argument is a cons of two buffer positions (such as returned by
`c-literal-limits'), and that range contains a C++ style line comment,
then an extended range is returned that contains all adjacent line
comments (i.e. all comments that starts in the same column with no
empty lines or non-whitespace characters between them).  Otherwise the
argument is returned."
  (save-excursion
    (condition-case nil
	(if (and (consp range) (progn
				 (goto-char (car range))
				 (looking-at "//")))
	    (let ((col (current-column))
		  (beg (point))
		  (bopl (c-point 'bopl))
		  (end (cdr range)))
	      ;; Got to take care in the backward direction to handle
	      ;; comments which are preceded by code.
	      (while (and (c-backward-single-comment)
			  (>= (point) bopl)
			  (looking-at "//")
			  (= col (current-column)))
		(setq beg (point)
		      bopl (c-point 'bopl)))
	      (goto-char end)
	      (while (and (progn (skip-chars-forward " \t")
				 (looking-at "//"))
			  (= col (current-column))
			  (prog1 (zerop (forward-line 1))
			    (setq end (point)))))
	      (cons beg end))
	  range)
      (error range))))

(defun c-literal-type (range)
  "Convenience function that given the result of `c-literal-limits',
returns nil or the type of literal that the range surrounds.  It's
much faster than using `c-in-literal' and is intended to be used when
you need both the type of a literal and its limits."
  (if (consp range)
      (save-excursion
	(goto-char (car range))
	(cond ((eq (char-syntax (or (char-after) ?\ )) ?\") 'string)
	      ((looking-at "//") 'c++)
	      (t 'c)))			; Assuming the range is valid.
    range))



;; utilities for moving and querying around syntactic elements

(defvar c-state-cache nil)
(make-variable-buffer-local 'c-state-cache)
;; The state cache used by `c-parse-state' to cut down the amount of
;; searching.  It's the result from some earlier `c-parse-state' call.
;; The use of the cached info is more effective if the next
;; `c-parse-state' call is on a line close by the one the cached state
;; was made at; the cache can actually slow down a little if the
;; cached state was made very far back in the buffer.  The cache is
;; most effective if `c-parse-state' is used on each line while moving
;; forward.

(defvar c-state-cache-start 1)
(make-variable-buffer-local 'c-state-cache-start)
;; This is (point-min) when `c-state-cache' was calculated, since a
;; change of narrowing is likely to affect the parens that are visible
;; before the point.

(defun c-parse-state ()
  ;; Finds and records all noteworthy parens between some good point
  ;; earlier in the file and point.  That good point is at least the
  ;; beginning of the top-level construct we are in, or the beginning
  ;; of the preceding top-level construct if we aren't in one.
  ;;
  ;; The returned value is a list of the noteworthy parens with the
  ;; last one first.  If an element in the list is an integer, it's
  ;; the position of an open paren which has not been closed before
  ;; point.  If an element is a cons, it gives the position of a
  ;; closed brace paren pair; the car is the start paren position and
  ;; the cdr is the position following the closing paren.  Only the
  ;; last closed brace paren pair before each open paren is recorded,
  ;; and thus the state never contains two cons elements in
  ;; succession.

  (save-restriction
    (let* ((here (point))
	   (c-macro-start (c-query-macro-start))
	   (in-macro-start (or c-macro-start (point)))
	   old-state last-pos pairs pos)

      ;; Somewhat ugly use of c-check-state-cache to get rid of the
      ;; part of the state cache that is after point.  Can't use
      ;; c-whack-state-after for the same reasons as in that function.
      (c-check-state-cache (point) nil nil)

      ;; If the minimum position has changed due to narrowing then we
      ;; have to fix the tail of `c-state-cache' accordingly.
      (unless (= c-state-cache-start (point-min))
	(if (> (point-min) c-state-cache-start)
	    ;; If point-min has moved forward then we just need to cut
	    ;; off a bit of the tail.
	    (let ((ptr (cons nil c-state-cache)) elem)
	      (while (and (setq elem (cdr ptr))
			  (>= (if (consp elem) (car elem) elem)
			      (point-min)))
		(setq ptr elem))
	      (when (consp ptr)
		(if (eq (cdr ptr) c-state-cache)
		    (setq c-state-cache nil)
		  (setcdr ptr nil))))
	  ;; If point-min has moved backward then we drop the state
	  ;; completely.  It's possible to do a better job here and
	  ;; recalculate the top only.
	  (setq c-state-cache nil))
	(setq c-state-cache-start (point-min)))

      ;; Get the latest position we know are directly inside the
      ;; closest containing paren of the cached state.
      (setq last-pos (and c-state-cache
			  (if (consp (car c-state-cache))
			      (cdr (car c-state-cache))
			    (1+ (car c-state-cache)))))

      ;; Check if the found last-pos is in a macro.  If it is, and
      ;; we're not in the same macro, we must discard everything on
      ;; c-state-cache that is inside the macro before using it.
      (when last-pos
	(save-excursion
	  (goto-char last-pos)
	  (when (and (c-beginning-of-macro)
		     (/= (point) in-macro-start))
	    (c-check-state-cache (point) nil nil)
	    ;; Set last-pos again, just like above.
	    (setq last-pos (and c-state-cache
				(if (consp (car c-state-cache))
				    (cdr (car c-state-cache))
				  (1+ (car c-state-cache))))))))

      (setq pos
	    ;; Find the start position for the forward search.  (Can't
	    ;; search in the backward direction since point might be
	    ;; in some kind of literal.)
	    (or (when last-pos

		  ;; There's a cached state with a containing paren.  Pop
		  ;; off the stale containing sexps from it by going
		  ;; forward out of parens as far as possible.
		  (narrow-to-region (point-min) here)
		  (let (placeholder pair-beg)
		    (while (and c-state-cache
				(setq placeholder
				      (c-up-list-forward last-pos)))
		      (setq last-pos placeholder)
		      (if (consp (car c-state-cache))
			  (setq pair-beg (car-safe (cdr c-state-cache))
				c-state-cache (cdr-safe (cdr c-state-cache)))
			(setq pair-beg (car c-state-cache)
			      c-state-cache (cdr c-state-cache))))

		    (when (and pair-beg (eq (char-after pair-beg) ?{))
		      ;; The last paren pair we moved out from was a brace
		      ;; pair.  Modify the state to record this as a closed
		      ;; pair now.
		      (if (consp (car-safe c-state-cache))
			  (setq c-state-cache (cdr c-state-cache)))
		      (setq c-state-cache (cons (cons pair-beg last-pos)
						c-state-cache))))

		  ;; Check if the preceding balanced paren is within a
		  ;; macro; it should be ignored if we're outside the
		  ;; macro.  There's no need to check any further upwards;
		  ;; if the macro contains an unbalanced opening paren then
		  ;; we're smoked anyway.
		  (when (and (<= (point) in-macro-start)
			     (consp (car c-state-cache)))
		    (save-excursion
		      (goto-char (car (car c-state-cache)))
		      (when (c-beginning-of-macro)
			(setq here (point)
			      c-state-cache (cdr c-state-cache)))))

		  (when c-state-cache
		    (setq old-state c-state-cache)
		    last-pos))

		(save-excursion
		  ;; go back 2 bods, but ignore any bogus positions
		  ;; returned by beginning-of-defun (i.e. open paren in
		  ;; column zero)
		  (goto-char here)
		  (let ((cnt 2))
		    (while (not (or (bobp) (zerop cnt)))
		      (c-beginning-of-defun-1)
		      (if (eq (char-after) ?\{)
			  (setq cnt (1- cnt)))))
		  (point))))

      (narrow-to-region (point-min) here)

      (while pos
	;; Find the balanced brace pairs.
	(setq pairs nil)
	(while (and (setq last-pos (c-down-list-forward pos))
		    (setq pos (c-up-list-forward last-pos)))
	  (if (eq (char-before last-pos) ?{)
	      (setq pairs (cons (cons last-pos pos) pairs))))

	;; Should ignore any pairs that are in a macro, providing
	;; we're not in the same one.
	(when (and pairs (< (car (car pairs)) in-macro-start))
	  (while (and (save-excursion
			(goto-char (car (car pairs)))
			(c-beginning-of-macro))
		      (setq pairs (cdr pairs)))))

	;; Record the last brace pair.
	(when pairs
	  (if (and (eq c-state-cache old-state)
		   (consp (car-safe c-state-cache)))
	      ;; There's a closed pair on the cached state but we've
	      ;; found a later one, so remove it.
	      (setq c-state-cache (cdr c-state-cache)))
	  (setq pairs (car pairs))
	  (setcar pairs (1- (car pairs)))
	  (when (consp (car-safe c-state-cache))
	    ;; There could already be a cons first in `c-state-cache'
	    ;; if we've jumped over an unbalanced open paren in a
	    ;; macro below.
	    (setq c-state-cache (cdr c-state-cache)))
	  (setq c-state-cache (cons pairs c-state-cache)))

	(if last-pos
	    ;; Prepare to loop, but record the open paren only if it's
	    ;; outside a macro or within the same macro as point.
	    (progn
	      (setq pos last-pos)
	      (if (or (>= last-pos in-macro-start)
		      (save-excursion
			(goto-char last-pos)
			(not (c-beginning-of-macro))))
		  (setq c-state-cache (cons (1- pos) c-state-cache))))

	  (if (setq last-pos (c-up-list-forward pos))
	      ;; Found a close paren without a corresponding opening
	      ;; one.  Maybe we didn't go back far enough, so try to
	      ;; scan backward for the start paren and then start over.
	      (progn
		(setq pos (c-up-list-backward pos)
		      c-state-cache nil)
		(unless pos
		  (setq pos last-pos
			c-parsing-error
			(format "Unbalanced close paren at line %d"
				(1+ (count-lines (point-min)
						 (c-point 'bol last-pos)))))))
	    (setq pos nil))))

      c-state-cache)))

;; Debug tool to catch cache inconsistencies.
(defvar c-debug-parse-state nil)
(unless (fboundp 'c-real-parse-state)
  (fset 'c-real-parse-state (symbol-function 'c-parse-state)))
(cc-bytecomp-defun c-real-parse-state)
(defun c-debug-parse-state ()
  (let ((res1 (c-real-parse-state)) res2)
    (let ((c-state-cache nil))
      (setq res2 (c-real-parse-state)))
    (unless (equal res1 res2)
      (error "c-parse-state inconsistency: using cache: %s, from scratch: %s"
	     res1 res2))
    res1))
(defun c-toggle-parse-state-debug (&optional arg)
  (interactive "P")
  (setq c-debug-parse-state (c-calculate-state arg c-debug-parse-state))
  (fset 'c-parse-state (symbol-function (if c-debug-parse-state
					    'c-debug-parse-state
					  'c-real-parse-state)))
  (c-keep-region-active))

(defun c-check-state-cache (beg end old-length)
  ;; Used on `after-change-functions' to adjust `c-state-cache'.
  ;; Prefer speed to finesse here, since there will be many more calls
  ;; to this function than times `c-state-cache' is used.
  ;;
  ;; This is much like `c-whack-state-after', but it never changes a
  ;; paren pair element into an open paren element.  Doing that would
  ;; mean that the new open paren wouldn't have the required preceding
  ;; paren pair element.
  (while (and c-state-cache
	      (let ((elem (car c-state-cache)))
		(if (consp elem)
		    (or (<= beg (car elem))
			(< beg (cdr elem)))
		  (<= beg elem))))
    (setq c-state-cache (cdr c-state-cache))))

(defun c-whack-state-before (bufpos paren-state)
  ;; Whack off any state information from PAREN-STATE which lies
  ;; before BUFPOS.  Not destructive on PAREN-STATE.
  (let* ((newstate (list nil))
	 (ptr newstate)
	 car)
    (while paren-state
      (setq car (car paren-state)
	    paren-state (cdr paren-state))
      (if (< (if (consp car) (car car) car) bufpos)
	  (setq paren-state nil)
	(setcdr ptr (list car))
	(setq ptr (cdr ptr))))
    (cdr newstate)))

(defun c-whack-state-after (bufpos paren-state)
  ;; Whack off any state information from PAREN-STATE which lies at or
  ;; after BUFPOS.  Not destructive on PAREN-STATE.
  (catch 'done
    (while paren-state
      (let ((car (car paren-state)))
	(if (consp car)
	    ;; just check the car, because in a balanced brace
	    ;; expression, it must be impossible for the corresponding
	    ;; close brace to be before point, but the open brace to
	    ;; be after.
	    (if (<= bufpos (car car))
		nil			; whack it off
	      (if (< bufpos (cdr car))
		  ;; its possible that the open brace is before
		  ;; bufpos, but the close brace is after.  In that
		  ;; case, convert this to a non-cons element.  The
		  ;; rest of the state is before bufpos, so we're
		  ;; done.
		  (throw 'done (cons (car car) (cdr paren-state)))
		;; we know that both the open and close braces are
		;; before bufpos, so we also know that everything else
		;; on state is before bufpos.
		(throw 'done paren-state)))
	  (if (<= bufpos car)
	      nil			; whack it off
	    ;; it's before bufpos, so everything else should too.
	    (throw 'done paren-state)))
	(setq paren-state (cdr paren-state)))
      nil)))


(defun c-beginning-of-inheritance-list (&optional lim)
  ;; Go to the first non-whitespace after the colon that starts a
  ;; multiple inheritance introduction.  Optional LIM is the farthest
  ;; back we should search.
  (let* ((lim (or lim (c-point 'bod))))
    (c-with-syntax-table c++-template-syntax-table
      (c-backward-token-1 0 t lim)
      (while (and (looking-at "[_a-zA-Z<,]")
		  (= (c-backward-token-1 1 t lim) 0)))
      (skip-chars-forward "^:"))))

(defun c-in-method-def-p ()
  ;; Return nil if we aren't in a method definition, otherwise the
  ;; position of the initial [+-].
  (save-excursion
    (beginning-of-line)
    (and c-opt-method-key
	 (looking-at c-opt-method-key)
	 (point))
    ))

;; Contributed by Kevin Ryde <user42@zip.com.au>.
(defun c-in-gcc-asm-p ()
  ;; Return non-nil if point is within a gcc \"asm\" block.
  ;;
  ;; This should be called with point inside an argument list.
  ;;
  ;; Only one level of enclosing parentheses is considered, so for
  ;; instance `nil' is returned when in a function call within an asm
  ;; operand.

  (and c-opt-asm-stmt-key
       (save-excursion
	 (beginning-of-line)
	 (backward-up-list 1)
	 (c-beginning-of-statement-1 (point-min) nil t)
	 (looking-at c-opt-asm-stmt-key))))

(defun c-beginning-of-syntax ()
  ;; This is used for `font-lock-beginning-of-syntax-function'.  It
  ;; goes to the closest previous point that is known to be outside
  ;; any string literal or comment, using `c-state-cache'.
  (let ((paren-state (or c-state-cache (c-parse-state))) elem)
    (goto-char
     (catch 'done
       (while paren-state
	 (setq elem (car paren-state)
	       paren-state (cdr paren-state))
	 (if (consp elem)
	     (cond ((<= (cdr elem) (point))
		    (throw 'done (cdr elem)))
		   ((<= (car elem) (point))
		    (throw 'done (car elem))))
	   (if (<= elem (point))
	       (throw 'done elem))))
       (point-min)))))

(defun c-at-toplevel-p ()
  "Return a determination as to whether point is at the `top-level'.
Being at the top-level means that point is either outside any
enclosing block (such function definition), or inside a class,
namespace or extern definition, but outside any method blocks.

If point is not at the top-level (e.g. it is inside a method
definition), then nil is returned.  Otherwise, if point is at a
top-level not enclosed within a class definition, t is returned.
Otherwise, a 2-vector is returned where the zeroth element is the
buffer position of the start of the class declaration, and the first
element is the buffer position of the enclosing class's opening
brace."
  (let ((paren-state (c-parse-state)))
    (or (not (c-most-enclosing-brace paren-state))
	(c-search-uplist-for-classkey paren-state))))

(defun c-forward-to-cpp-define-body ()
  ;; Assuming point is at the "#" that introduces a preprocessor
  ;; directive, it's moved forward to the start of the definition body
  ;; if it's a "#define".  Non-nil is returned in this case, in all
  ;; other cases nil is returned and point isn't moved.
  (when (and (looking-at
	      (concat "#[ \t]*"
		      "define[ \t]+\\(\\sw\\|_\\)+\\(\([^\)]*\)\\)?"
		      "\\([ \t]\\|\\\\\n\\)*"))
	     (not (= (match-end 0) (c-point 'eol))))
    (goto-char (match-end 0))))

(defun c-just-after-func-arglist-p (&optional lim)
  ;; Return t if we are between a function's argument list closing
  ;; paren and its opening brace.  Note that the list close brace
  ;; could be followed by a "const" specifier or a member init hanging
  ;; colon.  LIM is used as bound for some backward buffer searches;
  ;; the search might continue past it.
  ;;
  ;; Note: This test is easily fooled.  It only works reasonably well
  ;; in the situations where `c-guess-basic-syntax' uses it.
  (save-excursion
    (c-backward-syntactic-ws lim)
    (let ((checkpoint (point)))
      ;; could be looking at const specifier
      (if (and (eq (char-before) ?t)
	       (forward-word -1)
	       (looking-at "\\<const\\>[^_]"))
	  (c-backward-syntactic-ws lim)
	;; otherwise, we could be looking at a hanging member init
	;; colon
	(goto-char checkpoint)
	(while (eq (char-before) ?,)
	  ;; this will catch member inits with multiple
	  ;; line arglists
	  (forward-char -1)
	  (c-backward-syntactic-ws (c-point 'bol))
	  (if (eq (char-before) ?\))
	      (c-backward-sexp 2)
	    (c-backward-sexp 1))
	  (c-backward-syntactic-ws lim))
	(if (and (eq (char-before) ?:)
		 (progn
		   (forward-char -1)
		   (c-backward-syntactic-ws lim)
		   (looking-at "\\([ \t\n]\\|\\\\\n\\)*:\\([^:]+\\|$\\)")))
	    nil
	  (goto-char checkpoint))
	)
      (setq checkpoint (point))
      (and (eq (char-before) ?\))
	   ;; Check that it isn't a cpp expression, e.g. the
	   ;; expression of an #if directive or the "function header"
	   ;; of a #define.
	   (or (not (c-beginning-of-macro))
	       (and (c-forward-to-cpp-define-body)
		    (< (point) checkpoint)))
	   ;; check if we are looking at an ObjC method def
	   (or (not c-opt-method-key)
	       (progn
		 (goto-char checkpoint)
		 (c-forward-sexp -1)
		 (forward-char -1)
		 (c-backward-syntactic-ws lim)
		 (not (or (memq (char-before) '(?- ?+))
			  ;; or a class category
			  (progn
			    (c-forward-sexp -2)
			    (looking-at c-class-key))
			  )))))
      )))

(defun c-in-knr-argdecl (&optional lim)
  ;; Return the position of the first argument declaration if point is
  ;; inside a K&R style argument declaration list, nil otherwise.
  ;; `c-recognize-knr-p' is not checked.  If LIM is non-nil, it's a
  ;; position that bounds the backward search for the argument list.
  ;;
  ;; Note: A declaration level context is assumed; the test can return
  ;; false positives for statements.  This test is even more easily
  ;; fooled than `c-just-after-func-arglist-p'.
  (save-excursion
    (save-restriction
      ;; Go back to the closest preceding normal parenthesis sexp.  We
      ;; take that as the argument list in the function header.  Then
      ;; check that it's followed by some symbol before the next ';'
      ;; or '{'.  If it does, it's the header of the K&R argdecl we're
      ;; in.
      (if lim (narrow-to-region lim (point)))
      (let ((outside-macro (not (c-query-macro-start)))
	    paren-end)
	(catch 'done
	  (while (if (and (c-safe (setq paren-end
					(c-down-list-backward (point))))
			  (eq (char-after paren-end) ?\)))
		     (progn
		       (goto-char (1+ paren-end))
		       (if outside-macro
			   (c-beginning-of-macro)))
		   (throw 'done nil))))
	(and (progn
	       (c-forward-syntactic-ws)
	       (looking-at "\\w\\|\\s_"))
	     (c-safe (c-up-list-backward paren-end))
	     (point))))))

(defun c-skip-conditional ()
  ;; skip forward over conditional at point, including any predicate
  ;; statements in parentheses. No error checking is performed.
  (c-forward-sexp (cond
		   ;; else if()
		   ((looking-at (concat "\\<else"
					"\\([ \t\n]\\|\\\\\n\\)+"
					"if\\>\\([^_]\\|$\\)"))
		    3)
		   ;; do, else, try, finally
		   ((looking-at (concat "\\<\\("
					"do\\|else\\|try\\|finally"
					"\\)\\>\\([^_]\\|$\\)"))
		    1)
		   ;; for, if, while, switch, catch, synchronized, foreach
		   (t 2))))

(defun c-after-conditional (&optional lim)
  ;; If looking at the token after a conditional then return the
  ;; position of its start, otherwise return nil.
  (save-excursion
    (and (= (c-backward-token-1 1 t lim) 0)
	 (or (looking-at c-block-stmt-1-key)
	     (and (eq (char-after) ?\()
		  (= (c-backward-token-1 1 t lim) 0)
		  (looking-at c-block-stmt-2-key)))
	 (point))))

(defsubst c-backward-to-block-anchor (&optional lim)
  ;; Assuming point is at a brace that opens a statement block of some
  ;; kind, move to the proper anchor point for that block.  It might
  ;; need to be adjusted further by c-add-stmt-syntax, but the
  ;; position at return is suitable as start position for that
  ;; function.
  (unless (= (point) (c-point 'boi))
    (let ((start (c-after-conditional lim)))
      (if start
	  (goto-char start)))))

(defun c-backward-to-decl-anchor (&optional lim)
  ;; Assuming point is at a brace that opens the block of a top level
  ;; declaration of some kind, move to the proper anchor point for
  ;; that block.
  (unless (= (point) (c-point 'boi))
    ;; What we have below is actually an extremely stripped variant of
    ;; c-beginning-of-statement-1.
    (let ((pos (point)))
      ;; Switch syntax table to avoid stopping at line continuations.
      (save-restriction
	(if lim (narrow-to-region lim (point-max)))
	(while (and (progn
		      (c-backward-syntactic-ws)
		      (c-safe (goto-char (scan-sexps (point) -1)) t))
		    (not (c-crosses-statement-barrier-p (point) pos)))
	  (setq pos (point)))
	(goto-char pos)))))

(defsubst c-search-decl-header-end ()
  ;; Search forward for the end of the "header" of the current
  ;; declaration.  That's the position where the definition body
  ;; starts, or the first variable initializer, or the ending
  ;; semicolon.  I.e. search forward for the closest following
  ;; (syntactically relevant) '{', '=' or ';' token.  Point is left
  ;; _after_ the first found token, or at point-max if none is found.
  (if (c-major-mode-is 'c++-mode)
      ;; In C++ we need to take special care to handle those pesky
      ;; template brackets.
      (while (and (c-syntactic-re-search-forward "[;{=<]" nil 'move 1 t t)
		  (when (eq (char-before) ?<)
		    (c-with-syntax-table c++-template-syntax-table
		      (if (c-safe (goto-char (c-up-list-forward (point))))
			  t
			(goto-char (point-max))
			nil)))))
    (c-syntactic-re-search-forward "[;{=]" nil 'move 1 t t)))

(defun c-beginning-of-decl-1 (&optional lim)
  ;; Go to the beginning of the current declaration, or the beginning
  ;; of the previous one if already at the start of it.  Point won't
  ;; be moved out of any surrounding paren.  Return a cons cell on the
  ;; form (MOVE . KNR-POS).  MOVE is like the return value from
  ;; `c-beginning-of-statement-1'.  If point skipped over some K&R
  ;; style argument declarations (and they are to be recognized) then
  ;; KNR-POS is set to the start of the first such argument
  ;; declaration, otherwise KNR-POS is nil.  If LIM is non-nil, it's a
  ;; position that bounds the backward search.
  ;;
  ;; NB: Cases where the declaration continues after the block, as in
  ;; "struct foo { ... } bar;", are currently recognized as two
  ;; declarations, e.g. "struct foo { ... }" and "bar;" in this case.
  (catch 'return
    (let* ((start (point))
	   (last-stmt-start (point))
	   (move (c-beginning-of-statement-1 lim t t)))

      ;; `c-beginning-of-statement-1' stops at a block start, but we
      ;; want to continue if the block doesn't begin a top level
      ;; construct, i.e. if it isn't preceded by ';', '}', ':', or bob.
      (let ((beg (point)) tentative-move)
	(while (and
		;; Must check with c-opt-method-key in ObjC mode.
		(not (and c-opt-method-key
			  (looking-at c-opt-method-key)))
		(/= last-stmt-start (point))
		(progn
		  (c-backward-syntactic-ws lim)
		  (not (memq (char-before) '(?\; ?} ?: nil))))
		;; Check that we don't move from the first thing in a
		;; macro to its header.
		(not (eq (setq tentative-move
			       (c-beginning-of-statement-1 lim t t))
			 'macro)))
	  (setq last-stmt-start beg
		beg (point)
		move tentative-move))
	(goto-char beg))

      (when c-recognize-knr-p
	(let ((fallback-pos (point)) knr-argdecl-start)
	  ;; Handle K&R argdecls.  Back up after the "statement" jumped
	  ;; over by `c-beginning-of-statement-1', unless it was the
	  ;; function body, in which case we're sitting on the opening
	  ;; brace now.  Then test if we're in a K&R argdecl region and
	  ;; that we started at the other side of the first argdecl in
	  ;; it.
	  (unless (eq (char-after) ?{)
	    (goto-char last-stmt-start))
	  (if (and (setq knr-argdecl-start (c-in-knr-argdecl lim))
		   (< knr-argdecl-start start)
		   (progn
		     (goto-char knr-argdecl-start)
		     (not (eq (c-beginning-of-statement-1 lim t t) 'macro))))
	      (throw 'return
		     (cons (if (eq (char-after fallback-pos) ?{)
			       'previous
			     'same)
			   knr-argdecl-start))
	    (goto-char fallback-pos))))

      (when c-opt-access-key
	;; Might have ended up before a protection label.  This should
	;; perhaps be checked before `c-recognize-knr-p' to be really
	;; accurate, but we know that no language has both.
	(while (looking-at c-opt-access-key)
	  (goto-char (match-end 0))
	  (c-forward-syntactic-ws)
	  (when (>= (point) start)
	    (goto-char start)
	    (throw 'return (cons 'same nil)))))

      ;; `c-beginning-of-statement-1' counts each brace block as a
      ;; separate statement, so the result will be 'previous if we've
      ;; moved over any.  If they were brace list initializers we might
      ;; not have moved over a declaration boundary though, so change it
      ;; to 'same if we've moved past a '=' before '{', but not ';'.
      ;; (This ought to be integrated into `c-beginning-of-statement-1',
      ;; so we avoid this extra pass which potentially can search over a
      ;; large amount of text.)
      (if (and (eq move 'previous)
	       (c-with-syntax-table (if (c-major-mode-is 'c++-mode)
					c++-template-syntax-table
				      (syntax-table))
		 (save-excursion
		   (and (c-syntactic-re-search-forward "[;={]" start t 1 t t)
			(eq (char-before) ?=)
			(c-syntactic-re-search-forward "[;{]" start t 1 t)
			(eq (char-before) ?{)
			(c-safe (goto-char (c-up-list-forward (point))) t)
			(not (c-syntactic-re-search-forward
			      ";" start t 1 t))))))
	  (cons 'same nil)
	(cons move nil)))))

(defun c-end-of-decl-1 ()
  ;; Assuming point is at the start of a declaration (as detected by
  ;; e.g. `c-beginning-of-decl-1'), go to the end of it.  Unlike
  ;; `c-beginning-of-decl-1', this function handles the case when a
  ;; block is followed by identifiers in e.g. struct declarations in C
  ;; or C++.  If a proper end was found then t is returned, otherwise
  ;; point is moved as far as possible within the current sexp and nil
  ;; is returned.  This function doesn't handle macros; use
  ;; `c-end-of-macro' instead in those cases.
  (let ((start (point))
	(decl-syntax-table (if (c-major-mode-is 'c++-mode)
			       c++-template-syntax-table
			     (syntax-table))))
    (catch 'return
      (c-search-decl-header-end)

      (when (and c-recognize-knr-p
		 (eq (char-before) ?\;)
		 (c-in-knr-argdecl start))
	;; Stopped at the ';' in a K&R argdecl section which is
	;; detected using the same criteria as in
	;; `c-beginning-of-decl-1'.  Move to the following block
	;; start.
	(c-syntactic-re-search-forward "{" nil 'move 1 t))

      (when (eq (char-before) ?{)
	;; Encountered a block in the declaration.  Jump over it.
	(condition-case nil
	    (goto-char (c-up-list-forward (point)))
	  (goto-char (point-max))
	  (throw 'return nil))
	(if (or (not c-opt-block-decls-with-vars-key)
		(save-excursion
		  (c-with-syntax-table decl-syntax-table
		    (let ((lim (point)))
		      (goto-char start)
		      (not (and
			    ;; Check for `c-opt-block-decls-with-vars-key'
			    ;; before the first paren.
			    (c-syntactic-re-search-forward
			     (concat "[;=\(\[{]\\|\\("
				     c-opt-block-decls-with-vars-key
				     "\\)")
			     lim t 1 t t)
			    (match-beginning 1)
			    (not (eq (char-before) ?_))
			    ;; Check that the first following paren is
			    ;; the block.
			    (c-syntactic-re-search-forward "[;=\(\[{]"
							   lim t 1 t t)
			    (eq (char-before) ?{)))))))
	    ;; The declaration doesn't have any of the
	    ;; `c-opt-block-decls-with-vars' keywords in the
	    ;; beginning, so it ends here at the end of the block.
	    (throw 'return t)))

      (c-with-syntax-table decl-syntax-table
	(while (progn
		 (if (eq (char-before) ?\;)
		     (throw 'return t))
		 (c-syntactic-re-search-forward ";" nil 'move 1 t))))
      nil)))

(defun c-remove-ws (string)
  ;; Return the given string with any whitespace characters removed.
  (let* ((pos 0) (parts (list nil)) (tail parts))
    (while (string-match "[^ \t\n\r]+" string pos)
      (setcdr tail (list (match-string 0 string)))
      (setq tail (cdr tail)
	    pos (match-end 0)))
    (apply 'concat (cdr parts))))

;; Buffer local variable that contains an obarray with the types we've
;; found.  If a declaration is recognized somewhere we record the
;; fully qualified identifier in it to recognize it as a type
;; elsewhere in the file too.  This is not accurate since we do not
;; bother with the scoping rules of the languages, but in practice the
;; same name is seldom used as both a type and something else in a
;; file, and we only use this as a last resort in ambiguous cases (see
;; `c-font-lock-declarations').
;;
;; FIXME: This doesn't yet correctly handle template types in C++.
(defvar c-found-types nil)
(make-variable-buffer-local 'c-found-types)

(defsubst c-clear-found-types ()
  ;; Clears `c-found-types'.
  (setq c-found-types (make-vector 53 0)))

(defsubst c-add-type (type)
  ;; Add the given string as a type in `c-found-types'.  If there's
  ;; already a type which is equal to the given one except that the
  ;; last character is missing, it's removed.  That's done to avoid
  ;; adding all prefixes of a type as it's being entered and font
  ;; locked.  We should perhaps do the same when characters are
  ;; removed from the end of a type, but that'd require some sort of
  ;; fast lookup based on prefixes.
  (setq type (c-remove-ws type))
  (unintern (substring type 0 -1) c-found-types)
  (intern type c-found-types))

(defsubst c-check-type (string)
  ;; Return non-nil if the given string is a type in `c-found-types'.
  (intern-soft (c-remove-ws string) c-found-types))

(defsubst c-add-complex-type (from to)
  ;; The given region is taken to contain a type expression.  The
  ;; individual types in it are added to `c-found-types'.
  (goto-char from)
  (while (and (< (point) to)
	      (re-search-forward c-qualified-identifier-key to 'move))
    (let ((type (buffer-substring-no-properties (match-beginning 0)
						(match-end 0))))
      (unless (looking-at c-type-prefix-key)
	;; This adds types on `c-known-type-key' too.  There's no real
	;; harm in doing so, and it's simpler than checking.
	(c-add-type type)))))

(defun c-list-found-types ()
  ;; Return all the types in `c-found-types' as a sorted list of
  ;; strings.
  (let (type-list)
    (mapatoms (lambda (type)
		(setq type-list (cons (symbol-name type)
				      type-list)))
	      c-found-types)
    (sort type-list 'string-lessp)))

(defun c-forward-type (&optional use-font-property)
  ;; If the point is at the beginning of a type spec, move to the end
  ;; of it.  Return t if it is a known type, nil if it isn't (the
  ;; point isn't moved), 'prefix if it is a known prefix of a type,
  ;; 'found if it's a type that matches one in `c-found-types', or
  ;; 'maybe if it's an identfier that might be a type.  The point is
  ;; assumed to be at the beginning of a token.  If USE-FONT-PROPERTY
  ;; is non-nil then we use the 'font text property instead of some
  ;; regexp matches, under the assumption that the font-lock package
  ;; has fontified the nontype keywords.
  ;;
  ;; Note that this function doesn't skip past the brace definition
  ;; that might be considered part of the type, e.g.
  ;; "enum {a, b, c} foo".

  (let* ((start (point))
	 (res (cond
	       ((and c-complex-type-key
		     (looking-at c-complex-type-key))
		;; It's a type, but it might also be a complex one if it's
		;; followed by a parenthesis.  This only applies to Pike.
		(goto-char (match-end 1))
		(let ((end (point)))
		  (c-forward-syntactic-ws)
		  (unless (and (eq (char-after) ?\()
			       (c-safe (c-forward-sexp 1) t))
		    (goto-char end)))
		t)

	       ((looking-at c-type-prefix-key)
		;; Looking at a keyword that prefixes a type
		;; identifier, e.g. "class".
		(goto-char (match-end 1))
		(c-forward-syntactic-ws)
		(if (looking-at c-symbol-key)
		    (progn (goto-char (match-end 0))
			   (c-add-type (buffer-substring-no-properties
					(match-beginning 0) (match-end 0)))
			   t)
		  (goto-char start)
		  nil))

	       ((c-with-syntax-table c-identifier-syntax-table
		  (looking-at c-known-type-key))
		;; Looking at a known type identifier.

		(if (and c-primitive-type-prefix-key
			 (save-match-data
			   (looking-at c-primitive-type-prefix-key)))
		    ;; There might be more keywords for the type.
		    (let (pos)
		      (goto-char (match-end 1))
		      (while (progn
			       (setq pos (point))
			       (c-forward-syntactic-ws)
			       (looking-at c-primitive-type-prefix-key))
			(goto-char (match-end 1)))
		      (if (looking-at c-primitive-type-key)
			  (progn (goto-char (match-end 1))
				 t)
			(goto-char pos)
			'prefix))
		  (goto-char (match-end 1))
		  t))

	       ((and (looking-at c-qualified-identifier-key)
		     (if use-font-property
			 (not (eq (get-text-property (point) 'face)
				  'font-lock-keyword-face))
		       (save-match-data
			 (not (looking-at c-nontype-keywords-regexp)))))
		(goto-char (match-end 0))
		(if (c-check-type (match-string 0))
		    ;; It's an identifier that has been used as a type
		    ;; somewhere else.
		    'found
		  ;; It's an identifier that might be a type.
		  'maybe)))))

    ;; Step over any type suffix operators.  Do not let the existence
    ;; of these alter the classification of the found type, since
    ;; these operators typically are allowed in normal expressions
    ;; too.
    (when (and c-type-suffix-key res)
      (let (pos)
	(while (progn
		 (setq pos (point))
		 (c-forward-syntactic-ws)
		 (looking-at c-type-suffix-key))
	  (goto-char (match-end 1)))
	(goto-char pos)))

    (if (and c-type-concat-key res)
	;; Look for a trailing operator that concatenate the type with
	;; a following one, and if so step past that one through a
	;; recursive call.
	(let ((pos (point)) res2)
	  (c-forward-syntactic-ws)
	  (if (and (looking-at c-type-concat-key)
		   (progn
		     (goto-char (match-end 1))
		     (c-forward-syntactic-ws)
		     (setq res2 (c-forward-type))))
	      ;; If either operand certainly is a type then both are,
	      ;; but we don't let the existence of the operator itself
	      ;; promote two uncertain types to a certain one.
	      (cond ((eq res t) t)
		    ((eq res2 t) t)
		    ((eq res 'found) 'found)
		    ((eq res2 'found) 'found)
		    (t 'maybe))
	    (goto-char pos)
	    res))
      res)))

(defun c-beginning-of-member-init-list (&optional limit)
  ;; Goes to the beginning of a member init list (i.e. just after the
  ;; ':') if inside one. Returns t in that case, nil otherwise.
  (or limit
      (setq limit (point-min)))
  (skip-chars-forward " \t")
  (if (eq (char-after) ?,)
      (forward-char 1)
    (c-backward-syntactic-ws limit))
  (while (and (< limit (point))
	      (eq (char-before) ?,))
    ;; this will catch member inits with multiple
    ;; line arglists
    (forward-char -1)
    (c-backward-syntactic-ws limit)
    (if (eq (char-before) ?\))
	(c-backward-sexp 1))
    (c-backward-syntactic-ws limit)
    ;; Skip over any template arg to the class.
    (if (eq (char-before) ?>)
	(c-with-syntax-table c++-template-syntax-table
	  (c-backward-sexp 1)))
    (c-backward-sexp 1)
    (c-backward-syntactic-ws limit)
    ;; Skip backwards over a fully::qualified::name.
    (while (and (eq (char-before) ?:)
		(save-excursion
		  (forward-char -1)
		  (eq (char-before) ?:)))
      (backward-char 2)
      (c-backward-sexp 1))
    ;; now continue checking
    (c-backward-syntactic-ws limit))
  (and (< limit (point))
       (eq (char-before) ?:)))

(defun c-search-uplist-for-classkey (paren-state)
  ;; search for the containing class, returning a 2 element vector if
  ;; found. aref 0 contains the bufpos of the boi of the class key
  ;; line, and aref 1 contains the bufpos of the open brace.
  (if (null paren-state)
      ;; no paren-state means we cannot be inside a class
      nil
    (let ((carcache (car paren-state))
	  search-start search-end)
      (if (consp carcache)
	  ;; a cons cell in the first element means that there is some
	  ;; balanced sexp before the current bufpos. this we can
	  ;; ignore. the nth 1 and nth 2 elements define for us the
	  ;; search boundaries
	  (setq search-start (nth 2 paren-state)
		search-end (nth 1 paren-state))
	;; if the car was not a cons cell then nth 0 and nth 1 define
	;; for us the search boundaries
	(setq search-start (nth 1 paren-state)
	      search-end (nth 0 paren-state)))
      ;; if search-end is nil, or if the search-end character isn't an
      ;; open brace, we are definitely not in a class
      (if (or (not search-end)
	      (< search-end (point-min))
	      (not (eq (char-after search-end) ?{)))
	  nil
	;; now, we need to look more closely at search-start.  if
	;; search-start is nil, then our start boundary is really
	;; point-min.
	(if (not search-start)
	    (setq search-start (point-min))
	  ;; if search-start is a cons cell, then we can start
	  ;; searching from the end of the balanced sexp just ahead of
	  ;; us
	  (if (consp search-start)
	      (setq search-start (cdr search-start))))
	;; now we can do a quick regexp search from search-start to
	;; search-end and see if we can find a class key.  watch for
	;; class like strings in literals
	(save-excursion
	  (save-restriction
	    (goto-char search-start)
	    (let (foundp class match-end)
	      (while (and (not foundp)
			  (progn
			    (c-forward-syntactic-ws search-end)
			    (> search-end (point)))
			  (re-search-forward c-decl-block-key search-end t))
		(setq class (match-beginning 0)
		      match-end (match-end 0))
		(goto-char class)
		(if (c-in-literal search-start)
		    (goto-char match-end) ; its in a comment or string, ignore
		  (c-skip-ws-forward)
		  (setq foundp (vector (c-point 'boi) search-end))
		  (cond
		   ;; check for embedded keywords
		   ((let ((char (char-after (1- class))))
		      (and char
			   (memq (char-syntax char) '(?w ?_))))
		    (goto-char match-end)
		    (setq foundp nil))
		   ;; make sure we're really looking at the start of a
		   ;; class definition, and not an ObjC method.
		   ((and c-opt-method-key
			 (re-search-forward c-opt-method-key search-end t)
			 (not (c-in-literal class)))
		    (setq foundp nil))
		   ;; Check if this is an anonymous inner class.
		   ((and c-opt-inexpr-class-key
			 (looking-at c-opt-inexpr-class-key))
		    (while (and (= (c-forward-token-1 1 t) 0)
				(looking-at "(\\|\\w\\|\\s_\\|\\.")))
		    (if (eq (point) search-end)
			;; We're done.  Just trap this case in the cond.
			nil
		      ;; False alarm; all conditions aren't satisfied.
		      (setq foundp nil)))
		   ;; Its impossible to define a regexp for this, and
		   ;; nearly so to do it programmatically.
		   ;;
		   ;; ; picks up forward decls
		   ;; = picks up init lists
		   ;; ) picks up return types
		   ;; > picks up templates, but remember that we can
		   ;;   inherit from templates!
		   ((let ((skipchars "^;=)"))
		      ;; try to see if we found the `class' keyword
		      ;; inside a template arg list
		      (save-excursion
			(skip-chars-backward "^<>" search-start)
			(if (eq (char-before) ?<)
			    (setq skipchars (concat skipchars ">"))))
		      (while (progn
			       (skip-chars-forward skipchars search-end)
			       (c-in-literal class))
			(forward-char))
		      (/= (point) search-end))
		    (setq foundp nil))
		   )))
	      foundp))
	  )))))

(defun c-inside-bracelist-p (containing-sexp paren-state)
  ;; return the buffer position of the beginning of the brace list
  ;; statement if we're inside a brace list, otherwise return nil.
  ;; CONTAINING-SEXP is the buffer pos of the innermost containing
  ;; paren.  BRACE-STATE is the remainder of the state of enclosing
  ;; braces
  ;;
  ;; N.B.: This algorithm can potentially get confused by cpp macros
  ;; places in inconvenient locations.  Its a trade-off we make for
  ;; speed.
  (or
   ;; this will pick up enum lists
   (c-safe
    (save-excursion
      (goto-char containing-sexp)
      (c-forward-sexp -1)
      (let (bracepos)
	(if (and (or (looking-at "enum\\>[^_]")
		     (progn (c-forward-sexp -1)
			    (looking-at "enum\\>[^_]")))
		 (setq bracepos (c-down-list-forward (point)))
		 (not (c-crosses-statement-barrier-p (point)
						     (- bracepos 2))))
	    (point)))))
   ;; this will pick up array/aggregate init lists, even if they are nested.
   (save-excursion
     (let ((class-key
	    ;; Pike can have class definitions anywhere, so we must
	    ;; check for the class key here.
	    (and (c-major-mode-is 'pike-mode)
		 c-decl-block-key))
	   bufpos braceassignp lim next-containing)
       (while (and (not bufpos)
		   containing-sexp)
	   (when paren-state
	     (if (consp (car paren-state))
		 (setq lim (cdr (car paren-state))
		       paren-state (cdr paren-state))
	       (setq lim (car paren-state)))
	     (when paren-state
	       (setq next-containing (car paren-state)
		     paren-state (cdr paren-state))))
	   (goto-char containing-sexp)
	   (if (c-looking-at-inexpr-block next-containing next-containing)
	       ;; We're in an in-expression block of some kind.  Do not
	       ;; check nesting.  We deliberately set the limit to the
	       ;; containing sexp, so that c-looking-at-inexpr-block
	       ;; doesn't check for an identifier before it.
	       (setq containing-sexp nil)
	     ;; see if the open brace is preceded by = or [...] in
	     ;; this statement, but watch out for operator=
	     (setq braceassignp 'dontknow)
	     (c-backward-token-1 1 t lim)
	     ;; Checks to do only on the first sexp before the brace.
	     (when (and (c-major-mode-is 'java-mode)
			(eq (char-after) ?\[))
	       ;; In Java, an initialization brace list may follow
	       ;; directly after "new Foo[]", so check for a "new"
	       ;; earlier.
	       (while (eq braceassignp 'dontknow)
		 (setq braceassignp
		       (cond ((/= (c-backward-token-1 1 t lim) 0) nil)
			     ((looking-at "new\\>[^_]") t)
			     ((looking-at "\\sw\\|\\s_\\|[.[]")
			      ;; Carry on looking if this is an
			      ;; identifier (may contain "." in Java)
			      ;; or another "[]" sexp.
			      'dontknow)
			     (t nil)))))
	     ;; Checks to do on all sexps before the brace, up to the
	     ;; beginning of the statement.
	     (while (eq braceassignp 'dontknow)
	       (cond ((eq (char-after) ?\;)
		      (setq braceassignp nil))
		     ((and class-key
			   (looking-at class-key))
		      (setq braceassignp nil))
		     ((eq (char-after) ?=)
		      ;; We've seen a =, but must check earlier tokens so
		      ;; that it isn't something that should be ignored.
		      (setq braceassignp 'maybe)
		      (while (and (eq braceassignp 'maybe)
				  (zerop (c-backward-token-1 1 t lim)))
			(setq braceassignp
			      (cond
			       ;; Check for operator =
			       ((looking-at "operator\\>[^_]") nil)
			       ;; Check for `<opchar>= in Pike.
			       ((and (c-major-mode-is 'pike-mode)
				     (or (eq (char-after) ?`)
					 ;; Special case for Pikes
					 ;; `[]=, since '[' is not in
					 ;; the punctuation class.
					 (and (eq (char-after) ?\[)
					      (eq (char-before) ?`))))
				nil)
			       ((looking-at "\\s.") 'maybe)
			       ;; make sure we're not in a C++ template
			       ;; argument assignment
			       ((and
				 (c-major-mode-is 'c++-mode)
				 (save-excursion
				   (let ((here (point))
					 (pos< (progn
						 (skip-chars-backward "^<>")
						 (point))))
				     (and (eq (char-before) ?<)
					  (not (c-crosses-statement-barrier-p
						pos< here))
					  (not (c-in-literal))
					  ))))
				nil)
			       (t t))))))
	       (if (and (eq braceassignp 'dontknow)
			(/= (c-backward-token-1 1 t lim) 0))
		   (setq braceassignp nil)))
	     (if (not braceassignp)
		 (if (eq (char-after) ?\;)
		     ;; Brace lists can't contain a semicolon, so we're done.
		     (setq containing-sexp nil)
		   ;; Go up one level.
		   (setq containing-sexp next-containing
			 lim nil
			 next-containing nil))
	       ;; we've hit the beginning of the aggregate list
	       (c-beginning-of-statement-1
		(c-most-enclosing-brace paren-state))
	       (setq bufpos (point))))
	   )
       bufpos))
   ))

(defun c-looking-at-special-brace-list (&optional lim)
  ;; If we're looking at the start of a pike-style list, ie `({ })',
  ;; `([ ])', `(< >)' etc, a cons of a cons of its starting and ending
  ;; positions and its entry in c-special-brace-lists is returned, nil
  ;; otherwise.  The ending position is nil if the list is still open.
  ;; LIM is the limit for forward search.  The point may either be at
  ;; the `(' or at the following paren character.  Tries to check the
  ;; matching closer, but assumes it's correct if no balanced paren is
  ;; found (i.e. the case `({ ... } ... )' is detected as _not_ being
  ;; a special brace list).
  (if c-special-brace-lists
      (condition-case ()
	  (save-excursion
	    (let ((beg (point))
		  end type)
	      (c-forward-syntactic-ws)
	      (if (eq (char-after) ?\()
		  (progn
		    (forward-char 1)
		    (c-forward-syntactic-ws)
		    (setq type (assq (char-after) c-special-brace-lists)))
		(if (setq type (assq (char-after) c-special-brace-lists))
		    (progn
		      (c-backward-syntactic-ws)
		      (forward-char -1)
		      (setq beg (if (eq (char-after) ?\()
				    (point)
				  nil)))))
	      (if (and beg type)
		  (if (and (c-safe (goto-char beg)
				   (c-forward-sexp 1)
				   (setq end (point))
				   (= (char-before) ?\)))
			   (c-safe (goto-char beg)
				   (forward-char 1)
				   (c-forward-sexp 1)
				   ;; Kludges needed to handle inner
				   ;; chars both with and without
				   ;; paren syntax.
				   (or (/= (char-syntax (char-before)) ?\))
				       (= (char-before) (cdr type)))))
		      (if (or (/= (char-syntax (char-before)) ?\))
			      (= (progn
				   (c-forward-syntactic-ws)
				   (point))
				 (1- end)))
			  (cons (cons beg end) type))
		    (cons (list beg) type)))))
	(error nil))))

(defun c-looking-at-bos (&optional lim)
  ;; Return non-nil if between two statements or declarations, assuming
  ;; point is not inside a literal or comment.
  (save-excursion
    (c-backward-syntactic-ws lim)
    (or (bobp)
	;; Return t if at the start inside some parenthesis expression
	;; too, to catch macros that have statements as arguments.
	(memq (char-before) '(?\; ?} ?\())
	(and (eq (char-before) ?{)
	     (not (and c-special-brace-lists
		       (progn (backward-char)
			      (c-looking-at-special-brace-list))))))))

(defun c-looking-at-inexpr-block (lim containing-sexp)
  ;; Returns non-nil if we're looking at the beginning of a block
  ;; inside an expression.  The value returned is actually a cons of
  ;; either 'inlambda, 'inexpr-statement or 'inexpr-class and the
  ;; position of the beginning of the construct.  LIM limits the
  ;; backward search.  CONTAINING-SEXP is the start position of the
  ;; closest containing list.  If it's nil, the containing paren isn't
  ;; used to decide whether we're inside an expression or not.  If
  ;; both LIM and CONTAINING-SEXP is used, LIM needs to be farther
  ;; back.
  (save-excursion
    (let ((res 'maybe) passed-bracket
	  (closest-lim (or containing-sexp lim (point-min)))
	  ;; Look at the character after point only as a last resort
	  ;; when we can't disambiguate.
	  (block-follows (and (eq (char-after) ?{) (point))))
      (while (and (eq res 'maybe)
		  (progn (c-backward-syntactic-ws)
			 (> (point) closest-lim))
		  (not (bobp))
		  (progn (backward-char)
			 (looking-at "[\]\).]\\|\\w\\|\\s_"))
		  (progn (forward-char)
			 (goto-char (scan-sexps (point) -1))))
	(setq res
	      (cond
	       ((and block-follows
		     c-opt-inexpr-class-key
		     (looking-at c-opt-inexpr-class-key))
		(and (not passed-bracket)
		     (or (not (looking-at c-class-key))
			 ;; If the class definition is at the start of
			 ;; a statement, we don't consider it an
			 ;; in-expression class.
			 (let ((prev (point)))
			   (while (and
				   (= (c-backward-token-1 1 nil closest-lim) 0)
				   (eq (char-syntax (char-after)) ?w))
			     (setq prev (point)))
			   (goto-char prev)
			   (not (c-looking-at-bos)))
			 ;; Also, in Pike we treat it as an
			 ;; in-expression class if it's used in an
			 ;; object clone expression.
			 (save-excursion
			   (and (c-major-mode-is 'pike-mode)
				(progn (goto-char block-follows)
				       (= (c-forward-token-1 1 t) 0))
				(eq (char-after) ?\())))
		     (cons 'inexpr-class (point))))
	       ((and c-opt-inexpr-block-key
		     (looking-at c-opt-inexpr-block-key))
		(cons 'inexpr-statement (point)))
	       ((and c-opt-lambda-key
		     (looking-at c-opt-lambda-key))
		(cons 'inlambda (point)))
	       ((and c-opt-block-stmt-key
		     (looking-at c-opt-block-stmt-key))
		nil)
	       (t
		(if (eq (char-after) ?\[)
		    (setq passed-bracket t))
		'maybe))))
      (if (eq res 'maybe)
	  (when (and block-follows
		     containing-sexp
		     (eq (char-after containing-sexp) ?\())
	    (goto-char containing-sexp)
	    (if (or (save-excursion
		      (c-backward-syntactic-ws lim)
		      (and (> (point) (or lim (point-min)))
			   (c-on-identifier)))
		    (and c-special-brace-lists
			 (c-looking-at-special-brace-list)))
		nil
	      (cons 'inexpr-statement (point))))
	res))))

(defun c-looking-at-inexpr-block-backward (paren-state)
  ;; Returns non-nil if we're looking at the end of an in-expression
  ;; block, otherwise the same as `c-looking-at-inexpr-block'.
  ;; PAREN-STATE is the paren state relevant at the current position.
  (save-excursion
    ;; We currently only recognize a block.
    (let ((here (point))
	  (elem (car-safe paren-state))
	  containing-sexp)
      (when (and (consp elem)
		 (progn (goto-char (cdr elem))
			(c-forward-syntactic-ws here)
			(= (point) here)))
	(goto-char (car elem))
	(if (setq paren-state (cdr paren-state))
	    (setq containing-sexp (car-safe paren-state)))
	(c-looking-at-inexpr-block (c-safe-position containing-sexp
						    paren-state)
				   containing-sexp)))))

(defun c-on-identifier ()
  "Return non-nil if the point is on or directly after an identifier.
Keywords are recognized and not considered identifiers.  If an
identifier is detected, the returned value is its starting position.
If an identifier both starts and stops at the point \(can only happen
in Pike) then the point for the preceding one is returned."

  (save-excursion
    (if (zerop (skip-syntax-backward "w_"))

	(when (c-major-mode-is 'pike-mode)
	  ;; Handle the `<operator> syntax in Pike.
	  (let ((pos (point)))
	    (skip-chars-backward "!%&*+\\-/<=>^|~")
	    (and (if (eq (char-before) ?\`)
		     (progn (backward-char) t)
		   (goto-char pos)
		   (eq (char-after) ?\`))
		 (looking-at c-multichar-op-sym-token-regexp)
		 (>= (match-end 0) pos)
		 (point))))

      (and (not (looking-at c-keywords-regexp))
	   (point)))))


(defun c-most-enclosing-brace (paren-state &optional bufpos)
  ;; Return the bufpos of the innermost enclosing open paren before
  ;; bufpos that hasn't been narrowed out, or nil if none was found.
  (let (enclosingp)
    (or bufpos (setq bufpos 134217727))
    (while paren-state
      (setq enclosingp (car paren-state)
	    paren-state (cdr paren-state))
      (if (or (consp enclosingp)
	      (>= enclosingp bufpos))
	  (setq enclosingp nil)
	(if (< enclosingp (point-min))
	    (setq enclosingp nil))
	(setq paren-state nil)))
    enclosingp))

(defun c-least-enclosing-brace (paren-state &optional bufpos)
  ;; Return the bufpos of the outermost enclosing open paren before
  ;; bufpos that hasn't been narrowed out, or nil if none was found.
  (let (pos elem)
    (or bufpos (setq bufpos 134217727))
    (while paren-state
      (setq elem (car paren-state)
	    paren-state (cdr paren-state))
      (unless (or (consp elem)
		  (>= elem bufpos))
	(if (>= elem (point-min))
	    (setq pos elem))))
    pos))

(defun c-safe-position (bufpos paren-state)
  ;; Return the closest known safe position higher up than BUFPOS, or
  ;; nil if PAREN-STATE doesn't contain one.  Return nil if BUFPOS is
  ;; nil, which is useful to find the closest limit before a given
  ;; limit that might be nil.
  (when bufpos
    (let ((c-macro-start (c-query-macro-start)) safepos)
      (if (and c-macro-start
	       (< c-macro-start bufpos))
	  ;; Make sure bufpos is outside the macro we might be in.
	  (setq bufpos c-macro-start))
      (catch 'done
	(while paren-state
	  (setq safepos
		(if (consp (car paren-state))
		    (cdr (car paren-state))
		  (car paren-state)))
	  (if (< safepos bufpos)
	      (throw 'done safepos)
	    (setq paren-state (cdr paren-state))))
	(if (eq c-macro-start bufpos)
	    ;; Backed up bufpos to the macro start and got outside the
	    ;; state.  We know the macro is at the top level in this case,
	    ;; so we can use the macro start as the safe position.
	    c-macro-start)))))

(defun c-narrow-out-enclosing-class (paren-state lim)
  ;; Narrow the buffer so that the enclosing class is hidden.  Uses
  ;; and returns the value from c-search-uplist-for-classkey.
  (setq paren-state (c-whack-state-after (point) paren-state))
  (let (inclass-p)
    (and paren-state
	 (setq inclass-p (c-search-uplist-for-classkey paren-state))
	 (narrow-to-region
	  (progn
	    (goto-char (1+ (aref inclass-p 1)))
	    (c-skip-ws-forward lim)
	    ;; if point is now left of the class opening brace, we're
	    ;; hosed, so try a different tact
	    (if (<= (point) (aref inclass-p 1))
		(progn
		  (goto-char (1+ (aref inclass-p 1)))
		  (c-forward-syntactic-ws lim)))
	    (point))
	  ;; end point is the end of the current line
	  (progn
	    (goto-char lim)
	    (c-point 'eol))))
    ;; return the class vector
    inclass-p))


;; c-guess-basic-syntax and the functions that precedes it below
;; implements the main decision tree for determining the syntactic
;; analysis of the current line of code.

(defsubst c-add-syntax (symbol &rest args)
  ;; A simple function to prepend a new syntax element to
  ;; `c-syntactic-context'.  Using `setq' on it is unsafe since it
  ;; should always be dynamically bound but since we read it first
  ;; we'll fail properly anyway if this function is misused.
  (setq c-syntactic-context (cons (cons symbol args)
				  c-syntactic-context)))

(defsubst c-append-syntax (symbol &rest args)
  ;; Like `c-add-syntax' but appends to the end of the syntax list.
  ;; (Normally not necessary.)
  (setq c-syntactic-context (nconc c-syntactic-context
				   (list (cons symbol args)))))

(defun c-add-stmt-syntax (syntax-symbol
			  syntax-extra-args
			  stop-at-boi-only
			  at-block-start
			  containing-sexp
			  paren-state)
  ;; Do the generic processing to anchor the given syntax symbol on
  ;; the preceding statement: Skip over any labels and containing
  ;; statements on the same line, and then search backward until we
  ;; find a statement or block start that begins at boi without a
  ;; label or comment.
  ;;
  ;; Point is assumed to be at the prospective anchor point for the
  ;; given SYNTAX-SYMBOL.  More syntax entries are added if we need to
  ;; skip past open parens and containing statements.  All the added
  ;; syntax elements will get the same anchor point.
  ;;
  ;; SYNTAX-EXTRA-ARGS are a list of the extra arguments for the
  ;; syntax symbol.  They are appended after the anchor point.
  ;;
  ;; If STOP-AT-BOI-ONLY is nil, we might stop in the middle of the
  ;; line if another statement precedes the current one on this line.
  ;;
  ;; If AT-BLOCK-START is non-nil, point is taken to be at the
  ;; beginning of a block or brace list, which then might be nested
  ;; inside an expression.  If AT-BLOCK-START is nil, this is found
  ;; out by checking whether the character at point is "{" or not.
  (if (= (point) (c-point 'boi))
      ;; This is by far the most common case, so let's give it special
      ;; treatment.
      (apply 'c-add-syntax syntax-symbol (point) syntax-extra-args)

    (let ((savepos (point))
	  (syntax-last c-syntactic-context)
	  (boi (c-point 'boi))
	  (prev-paren (if at-block-start ?{ (char-after)))
	  step-type step-tmp at-comment)
      (apply 'c-add-syntax syntax-symbol nil syntax-extra-args)

      ;; Begin by skipping any labels and containing statements that
      ;; are on the same line.
      (while (and (/= (point) boi)
		  (if (memq (setq step-tmp
				  (c-beginning-of-statement-1 boi nil t))
			    '(up label))
		      t
		    (goto-char savepos)
		    nil)
		  (/= (point) savepos))
	(setq savepos (point)
	      step-type step-tmp))

      (catch 'done
	  ;; Loop if we have to back out of the containing block.
	  (while
	    (progn

	      ;; Loop if we have to back up another statement.
	      (while
		  (progn

		    ;; Always start by skipping over any comments that
		    ;; stands between the statement and boi.
		    (while (and (/= (setq savepos (point)) boi)
				(c-backward-single-comment))
		      (setq at-comment t
			    boi (c-point 'boi)))
		    (goto-char savepos)

		    (and
		     (or at-comment
			 (eq step-type 'label)
			 (/= savepos boi))

		     (progn
		       ;; Current position might not be good enough;
		       ;; skip backward another statement.
		       (setq step-type (c-beginning-of-statement-1
					containing-sexp))

		       (if (and (not stop-at-boi-only)
				(/= savepos boi)
				(memq step-type '(up previous)))
			   ;; If stop-at-boi-only is nil, we shouldn't
			   ;; back up over previous or containing
			   ;; statements to try to reach boi, so go
			   ;; back to the last position and exit.
			   (progn
			     (goto-char savepos)
			     nil)
			 (if (and (not stop-at-boi-only)
				  (memq step-type '(up previous beginning)))
			     ;; If we've moved into another statement
			     ;; then we should no longer try to stop
			     ;; after boi.
			     (setq stop-at-boi-only t))

			 ;; Record this a substatement if we skipped up
			 ;; one level, but not if we're still on the
			 ;; same line.  This so e.g. a sequence of "else
			 ;; if" clauses won't indent deeper and deeper.
			 (when (and (eq step-type 'up)
				    (< (point) boi))
			   (c-add-syntax 'substatement nil))

			 (setq boi (c-point 'boi))
			 (/= (point) savepos)))))

		(setq savepos (point)
		      at-comment nil))
	      (setq at-comment nil)

	      (when (and (eq step-type 'same)
			 containing-sexp)
		(goto-char containing-sexp)
		(setq paren-state (c-whack-state-after containing-sexp
						       paren-state)
		      containing-sexp (c-most-enclosing-brace paren-state)
		      savepos (point)
		      boi (c-point 'boi))

		(if (eq (setq prev-paren (char-after)) ?\()
		    (progn
		      (c-backward-syntactic-ws containing-sexp)
		      (when (/= savepos boi)
			(if (and (or (not (looking-at "\\>"))
				     (not (c-on-identifier)))
				 (save-excursion
				   (c-forward-syntactic-ws)
				   (forward-char)
				   (c-forward-syntactic-ws)
				   (eq (char-after) ?{)))
			    ;; We're in an in-expression statement.
			    ;; This syntactic element won't get an anchor pos.
			    (c-add-syntax 'inexpr-statement)
			  (c-add-syntax 'arglist-cont-nonempty nil savepos)))
		      (goto-char (max boi
				      (if containing-sexp
					  (1+ containing-sexp)
					(point-min))))
		      (setq step-type 'same))
		  (setq step-type
			(c-beginning-of-statement-1 containing-sexp)))

		(let ((at-bod (and (eq step-type 'same)
				   (/= savepos (point))
				   (eq prev-paren ?{))))

		  (when (= savepos boi)
		    ;; If the open brace was at boi, we're always
		    ;; done.  The c-beginning-of-statement-1 call
		    ;; above is necessary anyway, to decide the type
		    ;; of block-intro to add.
		    (goto-char savepos)
		    (setq savepos nil))

		  (when (eq prev-paren ?{)
		    (c-add-syntax (if at-bod
				      'defun-block-intro
				    'statement-block-intro)
				  nil))

		  (when (and (not at-bod) savepos)
		    ;; Loop if the brace wasn't at boi, and we didn't
		    ;; arrive at a defun block.
		    (if (eq step-type 'same)
			;; Avoid backing up another sexp if the point
			;; we're at now is found to be good enough in
			;; the loop above.
			(setq step-type nil))
		    (if (and (not stop-at-boi-only)
			     (memq step-type '(up previous beginning)))
			(setq stop-at-boi-only t))
		    (setq boi (c-point 'boi)))))
	      )))

      ;; Fill in the current point as the anchor for all the symbols
      ;; added above.
      (let ((p c-syntactic-context))
	(while (not (eq p syntax-last))
	  (if (cdr (car p))
	      (setcar (cdr (car p)) (point)))
	  (setq p (cdr p))))

      )))

(defun c-add-class-syntax (symbol classkey paren-state)
  ;; The inclass and class-close syntactic symbols are added in
  ;; several places and some work is needed to fix everything.
  ;; Therefore it's collected here.
  (save-restriction
    (widen)
    (let (inexpr anchor containing-sexp)
      (goto-char (aref classkey 1))
      (if (and (eq symbol 'inclass) (= (point) (c-point 'boi)))
	  (c-add-syntax symbol (setq anchor (point)))
	(c-add-syntax symbol (setq anchor (aref classkey 0)))
	(if (and c-opt-inexpr-class-key
		 (setq containing-sexp (c-most-enclosing-brace paren-state
							       (point))
		       inexpr (cdr (c-looking-at-inexpr-block
				    (c-safe-position containing-sexp
						     paren-state)
				    containing-sexp)))
		 (/= inexpr (c-point 'boi inexpr)))
	    (c-add-syntax 'inexpr-class)))
      anchor)))

(defun c-guess-continued-construct (indent-point
				    char-after-ip
				    beg-of-same-or-containing-stmt
				    containing-sexp
				    paren-state)
  ;; This function contains the decision tree reached through both
  ;; cases 18 and 10.  It's a continued statement or top level
  ;; construct of some kind.

  (let (special-brace-list)
    (goto-char indent-point)
    (skip-chars-forward " \t")

    (cond
     ;; (CASE A removed.)
     ;; CASE B: open braces for class or brace-lists
     ((setq special-brace-list
	    (or (and c-special-brace-lists
		     (c-looking-at-special-brace-list))
		(eq char-after-ip ?{)))

      (cond
       ;; CASE B.1: class-open
       ((save-excursion
	  (skip-chars-forward "{")
	  (let ((decl (c-search-uplist-for-classkey (c-parse-state))))
	    (and decl
		 (setq beg-of-same-or-containing-stmt (aref decl 0)))
	    ))
	(c-add-syntax 'class-open beg-of-same-or-containing-stmt))

       ;; CASE B.2: brace-list-open
       ((or (consp special-brace-list)
	    (save-excursion
	      (goto-char beg-of-same-or-containing-stmt)
	      (c-syntactic-re-search-forward "=" indent-point t 1 t t)))
	;; The most semantically accurate symbol here is
	;; brace-list-open, but we report it simply as a statement-cont.
	;; The reason is that one normally adjusts brace-list-open for
	;; brace lists as top-level constructs, and brace lists inside
	;; statements is a completely different context.
	(c-beginning-of-statement-1 containing-sexp)
	(c-add-stmt-syntax 'statement-cont nil nil nil
			   containing-sexp paren-state))

       ;; CASE B.3: The body of a function declared inside a normal
       ;; block.  Can occur e.g. in Pike and when using gcc
       ;; extensions.  Might also trigger it with some macros followed
       ;; by blocks, and this gives sane indentation then too.
       ;; C.f. cases E, 16F and 17G.
       ((and (not (c-looking-at-bos))
	     (eq (c-beginning-of-statement-1 containing-sexp nil nil t)
		 'same))
	(c-add-stmt-syntax 'defun-open nil t nil
			   containing-sexp paren-state))

       ;; CASE B.4: Continued statement with block open.
       (t
	(goto-char beg-of-same-or-containing-stmt)
	(c-add-stmt-syntax 'statement-cont nil nil nil
			   containing-sexp paren-state)
	(c-add-syntax 'block-open))
       ))

     ;; CASE C: iostream insertion or extraction operator
     ((and (looking-at "<<\\|>>")
	   (save-excursion
	     (goto-char beg-of-same-or-containing-stmt)
	     ;; If there is no preceding streamop in the statement
	     ;; then indent this line as a normal statement-cont.
	     (when (c-syntactic-re-search-forward
		    "<<\\|>>" indent-point 'move 1 t t)
	       (c-add-syntax 'stream-op (c-point 'boi))
	       t))))

     ;; CASE E: In the "K&R region" of a function declared inside a
     ;; normal block.  C.f. case B.3.
     ((and (save-excursion
	     ;; Check that the next token is a '{'.  This works as
	     ;; long as no language that allows nested function
	     ;; definitions doesn't allow stuff like member init
	     ;; lists, K&R declarations or throws clauses there.
	     ;;
	     ;; Note that we do a forward search for something ahead
	     ;; of the indentation line here.  That's not good since
	     ;; the user might not have typed it yet.  Unfortunately
	     ;; it's exceedingly tricky to recognize a function
	     ;; prototype in a code block without resorting to this.
	     (c-forward-syntactic-ws)
	     (eq (char-after) ?{))
	   (not (c-looking-at-bos))
	   (eq (c-beginning-of-statement-1 containing-sexp nil nil t)
	       'same))
      (c-add-stmt-syntax 'func-decl-cont nil t nil
			 containing-sexp paren-state))

     ;; CASE D: continued statement.
     (t
      (c-beginning-of-statement-1 containing-sexp)
      (c-add-stmt-syntax 'statement-cont nil nil nil
			 containing-sexp paren-state))
     )))

(defun c-guess-basic-syntax ()
  "Return the syntactic context of the current line."
  (save-excursion
    (save-restriction
      (beginning-of-line)
      (let* ((indent-point (point))
	     (case-fold-search nil)
	     (paren-state (c-parse-state))
	     literal containing-sexp char-before-ip char-after-ip lim
	     c-syntactic-context placeholder c-in-literal-cache step-type
	     tmpsymbol keyword injava-inher special-brace-list
	     ;; narrow out any enclosing class or extern "C" block
	     (inclass-p (c-narrow-out-enclosing-class paren-state
						      indent-point))
	     ;; `c-state-cache' is shadowed here so that we don't
	     ;; throw it away due to the narrowing that might be done
	     ;; by the function above.  That means we must not do any
	     ;; changes during the execution of this function, since
	     ;; `c-check-state-cache' then would change this local
	     ;; variable and leave a bogus value in the global one.
	     (c-state-cache (if inclass-p
				(c-whack-state-before (point-min) paren-state)
			      paren-state))
	     (c-state-cache-start (point-min))
	     inenclosing-p macro-start in-macro-expr
	     ;; There's always at most one syntactic element which got
	     ;; a relpos.  It's stored in syntactic-relpos.
	     syntactic-relpos
	     (c-stmt-delim-chars c-stmt-delim-chars))
	;; check for meta top-level enclosing constructs, possible
	;; extern language definitions, possibly (in C++) namespace
	;; definitions.
	(save-excursion
	  (save-restriction
	    (widen)
	    (if (and inclass-p
		     (progn
		       (goto-char (aref inclass-p 0))
		       (looking-at c-other-decl-block-key)))
		(let ((enclosing (match-string 1)))
		  (cond
		   ((string-equal enclosing "extern")
		    (setq inenclosing-p 'extern))
		   ((string-equal enclosing "namespace")
		    (setq inenclosing-p 'namespace))
		   )))))

	;; Init some position variables:
	;;
	;; containing-sexp is the open paren of the closest
	;; surrounding sexp or nil if there is none that hasn't been
	;; narrowed out.
	;;
	;; lim is the position after the closest preceding brace sexp
	;; (nested sexps are ignored), or the position after
	;; containing-sexp if there is none, or (point-min) if
	;; containing-sexp is nil.
	;;
	;; c-state-cache is the state from c-parse-state at
	;; indent-point, without any parens outside the region
	;; narrowed by c-narrow-out-enclosing-class.
	;;
	;; paren-state is the state from c-parse-state outside
	;; containing-sexp, or at indent-point if containing-sexp is
	;; nil.  paren-state is not limited to the narrowed region, as
	;; opposed to c-state-cache.
	(if c-state-cache
	    (progn
	      (setq containing-sexp (car paren-state)
		    paren-state (cdr paren-state))
	      (if (consp containing-sexp)
		  (progn
		    (setq lim (cdr containing-sexp))
		    (if (cdr c-state-cache)
			;; Ignore balanced paren.  The next entry
			;; can't be another one.
			(setq containing-sexp (car (cdr c-state-cache))
			      paren-state (cdr paren-state))
		      ;; If there is no surrounding open paren then
		      ;; put the last balanced pair back on paren-state.
		      (setq paren-state (cons containing-sexp paren-state)
			    containing-sexp nil)))
		(setq lim (1+ containing-sexp))))
	  (setq lim (point-min)))

	;; If we're in a parenthesis list then ',' delimits the
	;; "statements" rather than being an operator (with the
	;; exception of the "for" clause).  This difference is
	;; typically only noticeable when statements are used in macro
	;; arglists.
	(when (and containing-sexp
		   (eq (char-after containing-sexp) ?\())
	  (setq c-stmt-delim-chars c-stmt-delim-chars-with-comma))

	;; cache char before and after indent point, and move point to
	;; the most likely position to perform the majority of tests
	(goto-char indent-point)
	(c-backward-syntactic-ws lim)
	(setq char-before-ip (char-before))
	(goto-char indent-point)
	(skip-chars-forward " \t")
	(setq char-after-ip (char-after))

	;; are we in a literal?
	(setq literal (c-in-literal lim))

	;; now figure out syntactic qualities of the current line
	(cond
	 ;; CASE 1: in a string.
	 ((eq literal 'string)
	  (c-add-syntax 'string (c-point 'bopl)))
	 ;; CASE 2: in a C or C++ style comment.
	 ((memq literal '(c c++))
	  (c-add-syntax literal (car (c-literal-limits lim))))
	 ;; CASE 3: in a cpp preprocessor macro continuation.
	 ((and (save-excursion
		 (when (c-beginning-of-macro)
		   (setq macro-start (point))))
	       (/= macro-start (c-point 'boi))
	       (progn
		 (setq tmpsymbol 'cpp-macro-cont)
		 (or (not c-syntactic-indentation-in-macros)
		     (save-excursion
		       (goto-char macro-start)
		       ;; If at the beginning of the body of a #define
		       ;; directive then analyze as cpp-define-intro
		       ;; only.  Go on with the syntactic analysis
		       ;; otherwise.  in-macro-expr is set if we're in a
		       ;; cpp expression, i.e. before the #define body
		       ;; or anywhere in a non-#define directive.
		       (if (c-forward-to-cpp-define-body)
			   (let ((indent-boi (c-point 'boi indent-point)))
			     (setq in-macro-expr (> (point) indent-boi)
				   tmpsymbol 'cpp-define-intro)
			     (= (point) indent-boi))
			 (setq in-macro-expr t)
			 nil)))))
	  (c-add-syntax tmpsymbol macro-start)
	  (setq macro-start nil))
	 ;; CASE 11: an else clause?
	 ((looking-at "else\\>[^_]")
	  (c-beginning-of-statement-1 containing-sexp)
	  (c-add-stmt-syntax 'else-clause nil t nil
			     containing-sexp paren-state))
	 ;; CASE 12: while closure of a do/while construct?
	 ((and (looking-at "while\\>[^_]")
	       (save-excursion
		 (prog1 (eq (c-beginning-of-statement-1 containing-sexp)
			    'beginning)
		   (setq placeholder (point)))))
	  (goto-char placeholder)
	  (c-add-stmt-syntax 'do-while-closure nil t nil
			     containing-sexp paren-state))
	 ;; CASE 13: A catch or finally clause?  This case is simpler
	 ;; than if-else and do-while, because a block is required
	 ;; after every try, catch and finally.
	 ((save-excursion
	    (and (cond ((c-major-mode-is 'c++-mode)
			(looking-at "catch\\>[^_]"))
		       ((c-major-mode-is 'java-mode)
			(looking-at "\\(catch\\|finally\\)\\>[^_]")))
		 (and (c-safe (c-backward-syntactic-ws)
			      (c-backward-sexp)
			      t)
		      (eq (char-after) ?{)
		      (c-safe (c-backward-syntactic-ws)
			      (c-backward-sexp)
			      t)
		      (if (eq (char-after) ?\()
			  (c-safe (c-backward-sexp) t)
			t))
		 (looking-at "\\(try\\|catch\\)\\>[^_]")
		 (setq placeholder (point))))
	  (goto-char placeholder)
	  (c-add-stmt-syntax 'catch-clause nil t nil
			     containing-sexp paren-state))
	 ;; CASE 18: A substatement we can recognize by keyword.
	 ((save-excursion
	    (and c-opt-block-stmt-key
		 (not (eq char-before-ip ?\;))
		 (not (memq char-after-ip '(?\) ?\] ?,)))
		 (or (not (eq char-before-ip ?}))
		     (c-looking-at-inexpr-block-backward c-state-cache))
		 (> (point)
		    (progn
		      ;; Ought to cache the result from the
		      ;; c-beginning-of-statement-1 calls here.
		      (setq placeholder (point))
		      (while (eq (setq step-type
				       (c-beginning-of-statement-1 lim))
				 'label))
		      (if (eq step-type 'previous)
			  (goto-char placeholder)
			(setq placeholder (point))
			(if (and (eq step-type 'same)
				 (not (looking-at c-opt-block-stmt-key)))
			    ;; Step up to the containing statement if we
			    ;; stayed in the same one.
			    (let (step)
			      (while (eq
				      (setq step
					    (c-beginning-of-statement-1 lim))
				      'label))
			      (if (eq step 'up)
				  (setq placeholder (point))
				;; There was no containing statement afterall.
				(goto-char placeholder)))))
		      placeholder))
		 (if (looking-at c-block-stmt-2-key)
		     ;; Require a parenthesis after these keywords.
		     ;; Necessary to catch e.g. synchronized in Java,
		     ;; which can be used both as statement and
		     ;; modifier.
		     (and (= (c-forward-token-1 1 nil) 0)
			  (eq (char-after) ?\())
		   (looking-at c-opt-block-stmt-key))))
	  (if (eq step-type 'up)
	      ;; CASE 18A: Simple substatement.
	      (progn
		(goto-char placeholder)
		(cond
		 ((eq char-after-ip ?{)
		  (c-add-stmt-syntax 'substatement-open nil nil nil
				     containing-sexp paren-state))
		 ((save-excursion
		    (goto-char indent-point)
		    (back-to-indentation)
		    (looking-at c-label-key))
		  (c-add-stmt-syntax 'substatement-label nil nil nil
				     containing-sexp paren-state))
		 (t
		  (c-add-stmt-syntax 'substatement nil nil nil
				     containing-sexp paren-state))))
	    ;; CASE 18B: Some other substatement.  This is shared
	    ;; with case 10.
	    (c-guess-continued-construct indent-point
					 char-after-ip
					 placeholder
					 lim
					 paren-state)))
	 ;; CASE 4: In-expression statement.  C.f. cases 7B, 16A and
	 ;; 17E.
	 ((and (or c-opt-inexpr-class-key
		   c-opt-inexpr-block-key
		   c-opt-lambda-key)
	       (setq placeholder (c-looking-at-inexpr-block
				  (c-safe-position containing-sexp paren-state)
				  containing-sexp)))
	  (setq tmpsymbol (assq (car placeholder)
				'((inexpr-class . class-open)
				  (inexpr-statement . block-open))))
	  (if tmpsymbol
	      ;; It's a statement block or an anonymous class.
	      (setq tmpsymbol (cdr tmpsymbol))
	    ;; It's a Pike lambda.  Check whether we are between the
	    ;; lambda keyword and the argument list or at the defun
	    ;; opener.
	    (setq tmpsymbol (if (eq char-after-ip ?{)
				'inline-open
			      'lambda-intro-cont)))
	  (goto-char (cdr placeholder))
	  (back-to-indentation)
	  (c-add-stmt-syntax tmpsymbol nil t nil
			     (c-most-enclosing-brace c-state-cache (point))
			     (c-whack-state-after (point) paren-state))
	  (unless (eq (point) (cdr placeholder))
	    (c-add-syntax (car placeholder))))
	 ;; CASE 5: Line is at top level.
	 ((null containing-sexp)
	  (cond
	   ;; CASE 5A: we are looking at a defun, brace list, class,
	   ;; or inline-inclass method opening brace
	   ((setq special-brace-list
		  (or (and c-special-brace-lists
			   (c-looking-at-special-brace-list))
		      (eq char-after-ip ?{)))
	    (cond
	     ;; CASE 5A.1: extern language or namespace construct
	     ((save-excursion
		(goto-char indent-point)
		(skip-chars-forward " \t")
		(and (c-safe (c-backward-sexp 2) t)
		     (looking-at c-other-decl-block-key)
		     (setq keyword (match-string 1)
			   placeholder (point))
		     (or (and (string-equal keyword "namespace")
			      (setq tmpsymbol 'namespace-open))
			 (and (string-equal keyword "extern")
			      (progn
				(c-forward-sexp 1)
				(c-forward-syntactic-ws)
				(eq (char-after) ?\"))
			      (setq tmpsymbol 'extern-lang-open)))
		     ))
	      (goto-char placeholder)
	      (c-add-syntax tmpsymbol (c-point 'boi)))
	     ;; CASE 5A.2: we are looking at a class opening brace
	     ((save-excursion
		(goto-char indent-point)
		(skip-chars-forward " \t{")
		(let ((decl (c-search-uplist-for-classkey (c-parse-state))))
		  (and decl
		       (setq placeholder (aref decl 0)))
		  ))
	      (c-add-syntax 'class-open placeholder))
	     ;; CASE 5A.3: brace list open
	     ((save-excursion
		(c-beginning-of-decl-1 lim)
		(if (looking-at "typedef\\>[^_]")
		    (progn (c-forward-sexp 1)
			   (c-forward-syntactic-ws indent-point)))
		(setq placeholder (c-point 'boi))
		(or (consp special-brace-list)
		    (and (or (save-excursion
			       (goto-char indent-point)
			       (setq tmpsymbol nil)
			       (while (and (> (point) placeholder)
					   (= (c-backward-token-1 1 t) 0)
					   (/= (char-after) ?=))
				 (if (and (not tmpsymbol)
					  (looking-at "new\\>[^_]"))
				     (setq tmpsymbol 'topmost-intro-cont)))
			       (eq (char-after) ?=))
			     (looking-at "enum\\>[^_]"))
			 (save-excursion
			   (while (and (< (point) indent-point)
				       (= (c-forward-token-1 1 t) 0)
				       (not (memq (char-after) '(?\; ?\()))))
			   (not (memq (char-after) '(?\; ?\()))
			   ))))
	      (if (and (c-major-mode-is 'java-mode)
		       (eq tmpsymbol 'topmost-intro-cont))
		  ;; We're in Java and have found that the open brace
		  ;; belongs to a "new Foo[]" initialization list,
		  ;; which means the brace list is part of an
		  ;; expression and not a top level definition.  We
		  ;; therefore treat it as any topmost continuation
		  ;; even though the semantically correct symbol still
		  ;; is brace-list-open, on the same grounds as in
		  ;; case 10B.2.
		  (progn
		    (c-beginning-of-statement-1 lim)
		    (c-add-syntax 'topmost-intro-cont (c-point 'boi)))
		(c-add-syntax 'brace-list-open placeholder)))
	     ;; CASE 5A.4: inline defun open
	     ((and inclass-p (not inenclosing-p))
	      (c-add-syntax 'inline-open)
	      (c-add-class-syntax 'inclass inclass-p paren-state))
	     ;; CASE 5A.5: ordinary defun open
	     (t
	      (goto-char placeholder)
	      (if (or inclass-p macro-start)
		  (c-add-syntax 'defun-open (c-point 'boi))
		;; Bogus to use bol here, but it's the legacy.
		(c-add-syntax 'defun-open (c-point 'bol)))
	      )))
	   ;; CASE 5B: first K&R arg decl or member init
	   ((c-just-after-func-arglist-p lim)
	    (cond
	     ;; CASE 5B.1: a member init
	     ((or (eq char-before-ip ?:)
		  (eq char-after-ip ?:))
	      ;; this line should be indented relative to the beginning
	      ;; of indentation for the topmost-intro line that contains
	      ;; the prototype's open paren
	      ;; TBD: is the following redundant?
	      (if (eq char-before-ip ?:)
		  (forward-char -1))
	      (c-backward-syntactic-ws lim)
	      ;; TBD: is the preceding redundant?
	      (if (eq (char-before) ?:)
		  (progn (forward-char -1)
			 (c-backward-syntactic-ws lim)))
	      (if (eq (char-before) ?\))
		  (c-backward-sexp 1))
	      (setq placeholder (point))
	      (save-excursion
		(and (c-safe (c-backward-sexp 1) t)
		     (looking-at "throw[^_]")
		     (c-safe (c-backward-sexp 1) t)
		     (setq placeholder (point))))
	      (goto-char placeholder)
	      (c-add-syntax 'member-init-intro (c-point 'boi))
	      ;; we don't need to add any class offset since this
	      ;; should be relative to the ctor's indentation
	      )
	     ;; CASE 5B.2: K&R arg decl intro
	     (c-recognize-knr-p
	      (c-beginning-of-statement-1 lim)
	      (c-add-syntax 'knr-argdecl-intro (c-point 'boi))
	      (if inclass-p
		  (c-add-class-syntax 'inclass inclass-p paren-state)))
	     ;; CASE 5B.3: Inside a member init list.
	     ((c-beginning-of-member-init-list lim)
	      (c-forward-syntactic-ws)
	      (c-add-syntax 'member-init-cont (point)))
	     ;; CASE 5B.4: Nether region after a C++ or Java func
	     ;; decl, which could include a `throws' declaration.
	     (t
	      (c-beginning-of-statement-1 lim)
	      (c-add-syntax 'func-decl-cont (c-point 'boi))
	      )))
	   ;; CASE 5C: inheritance line. could be first inheritance
	   ;; line, or continuation of a multiple inheritance
	   ((or (and (c-major-mode-is 'c++-mode)
		     (progn
		       (when (eq char-after-ip ?,)
			 (skip-chars-forward " \t")
			 (forward-char))
		       (looking-at c-opt-decl-spec-key)))
		(and (or (eq char-before-ip ?:)
			 ;; watch out for scope operator
			 (save-excursion
			   (and (eq char-after-ip ?:)
				(c-safe (forward-char 1) t)
				(not (eq (char-after) ?:))
				)))
		     (save-excursion
		       (c-backward-syntactic-ws lim)
		       (if (eq char-before-ip ?:)
			   (progn
			     (forward-char -1)
			     (c-backward-syntactic-ws lim)))
		       (back-to-indentation)
		       (looking-at c-class-key)))
		;; for Java
		(and (c-major-mode-is 'java-mode)
		     (let ((fence (save-excursion
				    (c-beginning-of-statement-1 lim)
				    (point)))
			   cont done)
		       (save-excursion
			 (while (not done)
			   (cond ((looking-at c-opt-decl-spec-key)
				  (setq injava-inher (cons cont (point))
					done t))
				 ((or (not (c-safe (c-forward-sexp -1) t))
				      (<= (point) fence))
				  (setq done t))
				 )
			   (setq cont t)))
		       injava-inher)
		     (not (c-crosses-statement-barrier-p (cdr injava-inher)
							 (point)))
		     ))
	    (cond
	     ;; CASE 5C.1: non-hanging colon on an inher intro
	     ((eq char-after-ip ?:)
	      (c-beginning-of-statement-1 lim)
	      (c-add-syntax 'inher-intro (c-point 'boi))
	      ;; don't add inclass symbol since relative point already
	      ;; contains any class offset
	      )
	     ;; CASE 5C.2: hanging colon on an inher intro
	     ((eq char-before-ip ?:)
	      (c-beginning-of-statement-1 lim)
	      (c-add-syntax 'inher-intro (c-point 'boi))
	      (if inclass-p
		  (c-add-class-syntax 'inclass inclass-p paren-state)))
	     ;; CASE 5C.3: in a Java implements/extends
	     (injava-inher
	      (let ((where (cdr injava-inher))
		    (cont (car injava-inher)))
		(goto-char where)
		(cond ((looking-at "throws\\>[^_]")
		       (c-add-syntax 'func-decl-cont
				     (progn (c-beginning-of-statement-1 lim)
					    (c-point 'boi))))
		      (cont (c-add-syntax 'inher-cont where))
		      (t (c-add-syntax 'inher-intro
				       (progn (goto-char (cdr injava-inher))
					      (c-beginning-of-statement-1 lim)
					      (point))))
		      )))
	     ;; CASE 5C.4: a continued inheritance line
	     (t
	      (c-beginning-of-inheritance-list lim)
	      (c-add-syntax 'inher-cont (point))
	      ;; don't add inclass symbol since relative point already
	      ;; contains any class offset
	      )))
	   ;; CASE 5D: this could be a top-level initialization, a
	   ;; member init list continuation, or a template argument
	   ;; list continuation.
	   ((c-with-syntax-table (if (c-major-mode-is 'c++-mode)
				     c++-template-syntax-table
				   (syntax-table))
	      (save-excursion
		;; Note: We use the fact that lim is always after any
		;; preceding brace sexp.
		(while (and (= (c-backward-token-1 1 t lim) 0)
			    (not (looking-at "[;<,=]"))))
		(or (memq (char-after) '(?, ?=))
		    (and (c-major-mode-is 'c++-mode)
			 (= (c-backward-token-1 1 nil lim) 0)
			 (eq (char-after) ?<)))))
	    (goto-char indent-point)
	    (c-beginning-of-member-init-list lim)
	    (cond
	     ;; CASE 5D.1: hanging member init colon, but watch out
	     ;; for bogus matches on access specifiers inside classes.
	     ((and (save-excursion
		     (setq placeholder (point))
		     (c-backward-token-1 1 t lim)
		     (and (eq (char-after) ?:)
			  (not (eq (char-before) ?:))))
		   (save-excursion
		     (goto-char placeholder)
		     (back-to-indentation)
		     (or
		      (/= (car (save-excursion
				 (parse-partial-sexp (point) placeholder)))
			  0)
		      (and
		       (if c-opt-access-key
			   (not (looking-at c-opt-access-key)) t)
		       (not (looking-at c-class-key))
		       (if c-opt-bitfield-key
			   (not (looking-at c-opt-bitfield-key)) t))
		      )))
	      (goto-char placeholder)
	      (c-forward-syntactic-ws)
	      (c-add-syntax 'member-init-cont (point))
	      ;; we do not need to add class offset since relative
	      ;; point is the member init above us
	      )
	     ;; CASE 5D.2: non-hanging member init colon
	     ((progn
		(c-forward-syntactic-ws indent-point)
		(eq (char-after) ?:))
	      (skip-chars-forward " \t:")
	      (c-add-syntax 'member-init-cont (point)))
	     ;; CASE 5D.3: perhaps a template list continuation?
	     ((and (c-major-mode-is 'c++-mode)
		   (save-excursion
		     (save-restriction
		       (c-with-syntax-table c++-template-syntax-table
			 (goto-char indent-point)
			 (setq placeholder (c-up-list-backward (point)))
			 (and placeholder
			      (eq (char-after placeholder) ?<))))))
	      ;; we can probably indent it just like an arglist-cont
	      (goto-char placeholder)
	      (c-beginning-of-statement-1 lim t)
	      (c-add-syntax 'template-args-cont (c-point 'boi)))
	     ;; CASE 5D.4: perhaps a multiple inheritance line?
	     ((and (c-major-mode-is 'c++-mode)
		   (save-excursion
		     (c-beginning-of-statement-1 lim)
		     (setq placeholder (point))
		     (if (looking-at "static\\>[^_]")
			 (c-forward-token-1 1 nil indent-point))
		     (and (looking-at c-class-key)
			  (= (c-forward-token-1 2 nil indent-point) 0)
			  (if (eq (char-after) ?<)
			      (c-with-syntax-table c++-template-syntax-table
				(= (c-forward-token-1 1 t indent-point) 0))
			    t)
			  (eq (char-after) ?:))))
	      (goto-char placeholder)
	      (c-add-syntax 'inher-cont (c-point 'boi)))
	     ;; CASE 5D.5: Continuation of the "expression part" of a
	     ;; top level construct.
	     (t
	      (while (and (eq (car (c-beginning-of-decl-1 containing-sexp))
			      'same)
			  (save-excursion
			    (c-backward-syntactic-ws)
			    (eq (char-before) ?}))))
	      (c-add-stmt-syntax
	       (if (eq char-before-ip ?,)
		   ;; A preceding comma at the top level means that a
		   ;; new variable declaration starts here.  Use
		   ;; topmost-intro-cont for it, for consistency with
		   ;; the first variable declaration.  C.f. case 5N.
		   'topmost-intro-cont
		 'statement-cont)
	       nil nil nil containing-sexp paren-state))
	     ))
	   ;; CASE 5E: we are looking at a access specifier
	   ((and inclass-p
		 c-opt-access-key
		 (looking-at c-opt-access-key))
	    (setq placeholder (c-add-class-syntax 'inclass inclass-p
						  paren-state))
	    ;; Append access-label with the same anchor point as inclass gets.
	    (c-append-syntax 'access-label placeholder))
	   ;; CASE 5F: extern-lang-close or namespace-close?
	   ((and inenclosing-p
		 (eq char-after-ip ?}))
	    (setq tmpsymbol (if (eq inenclosing-p 'extern)
				'extern-lang-close
			      'namespace-close))
	    (c-add-syntax tmpsymbol (aref inclass-p 0)))
	   ;; CASE 5G: we are looking at the brace which closes the
	   ;; enclosing nested class decl
	   ((and inclass-p
		 (eq char-after-ip ?})
		 (save-excursion
		   (save-restriction
		     (widen)
		     (forward-char 1)
		     (and (c-safe (c-backward-sexp 1) t)
			  (= (point) (aref inclass-p 1))
			  ))))
	    (c-add-class-syntax 'class-close inclass-p paren-state))
	   ;; CASE 5H: we could be looking at subsequent knr-argdecls
	   ((and c-recognize-knr-p
		 (not (eq char-before-ip ?}))
		 (save-excursion
		   (setq placeholder (cdr (c-beginning-of-decl-1 lim)))
		   (and placeholder
			;; Do an extra check to avoid tripping up on
			;; statements that occur in invalid contexts
			;; (e.g. in macro bodies where we don't really
			;; know the context of what we're looking at).
			(not (and c-opt-block-stmt-key
				  (looking-at c-opt-block-stmt-key)))))
		 (< placeholder indent-point))
	    (goto-char placeholder)
	    (c-add-syntax 'knr-argdecl (point)))
	   ;; CASE 5I: ObjC method definition.
	   ((and c-opt-method-key
		 (looking-at c-opt-method-key))
	    (c-beginning-of-statement-1 lim)
	    (c-add-syntax 'objc-method-intro (c-point 'boi)))
	   ;; CASE 5N: At a variable declaration that follows a class
	   ;; definition or some other block declaration that doesn't
	   ;; end at the closing '}'.  C.f. case 5D.5.
	   ((progn
	      (c-backward-syntactic-ws lim)
	      (and (eq (char-before) ?})
		   (save-excursion
		     (let ((start (point)))
		       (if paren-state
			   ;; Speed up the backward search a bit.
			   (goto-char (car (car paren-state))))
		       (c-beginning-of-decl-1 containing-sexp)
		       (setq placeholder (point))
		       (if (= start (point))
			   ;; The '}' is unbalanced.
			   nil
			 (c-end-of-decl-1)
			 (> (point) indent-point))))))
	    (goto-char placeholder)
	    (c-add-stmt-syntax 'topmost-intro-cont nil nil nil
			       containing-sexp paren-state))
	   ;; CASE 5J: we are at the topmost level, make
	   ;; sure we skip back past any access specifiers
	   ((progn
	      (while (and inclass-p
			  c-opt-access-key
			  (not (bobp))
			  (save-excursion
			    (c-safe (c-backward-sexp 1) t)
			    (looking-at c-opt-access-key)))
		(c-backward-sexp 1)
		(c-backward-syntactic-ws lim))
	      (or (bobp)
		  (memq (char-before) '(?\; ?}))
		  (and (c-major-mode-is 'objc-mode)
		       (progn
			 (c-beginning-of-statement-1 lim)
			 (eq (char-after) ?@)))))
	    ;; real beginning-of-line could be narrowed out due to
	    ;; enclosure in a class block
	    (save-restriction
	      (widen)
	      (c-add-syntax 'topmost-intro (c-point 'bol))
	      ;; Using bol instead of boi above is highly bogus, and
	      ;; it makes our lives hard to remain compatible. :P
	      (if inclass-p
		  (progn
		    (goto-char (aref inclass-p 1))
		    (or (= (point) (c-point 'boi))
			(goto-char (aref inclass-p 0)))
		    (cond
		     ((eq inenclosing-p 'extern)
		      (c-add-syntax 'inextern-lang (c-point 'boi)))
		     ((eq inenclosing-p 'namespace)
		      (c-add-syntax 'innamespace (c-point 'boi)))
		     (t (c-add-class-syntax 'inclass inclass-p paren-state)))
		    ))
	      (when (and c-syntactic-indentation-in-macros
			 macro-start
			 (/= macro-start (c-point 'boi indent-point)))
		(c-add-syntax 'cpp-define-intro)
		(setq macro-start nil))
	      ))
	   ;; CASE 5K: we are at an ObjC method definition
	   ;; continuation line.
	   ((and c-opt-method-key
		 (progn
		   (c-beginning-of-statement-1 lim)
		   (beginning-of-line)
		   (looking-at c-opt-method-key)))
	    (c-add-syntax 'objc-method-args-cont (point)))
	   ;; CASE 5L: we are at the first argument of a template
	   ;; arglist that begins on the previous line.
	   ((eq (char-before) ?<)
	    (c-beginning-of-statement-1 (c-safe-position (point) paren-state))
	    (c-add-syntax 'template-args-cont (c-point 'boi)))
	   ;; CASE 5M: we are at a topmost continuation line
	   (t
	    (c-beginning-of-statement-1 (c-safe-position (point) paren-state))
	    (c-add-syntax 'topmost-intro-cont (c-point 'boi)))
	   ))
	 ;; (CASE 6 has been removed.)
	 ;; CASE 7: line is an expression, not a statement.  Most
	 ;; likely we are either in a function prototype or a function
	 ;; call argument list
	 ((not (or (and c-special-brace-lists
			(save-excursion
			  (goto-char containing-sexp)
			  (c-looking-at-special-brace-list)))
		   (eq (char-after containing-sexp) ?{)))
	  (cond
	   ;; CASE 7A: we are looking at the arglist closing paren.
	   ;; C.f. case 7F.
	   ((memq char-after-ip '(?\) ?\]))
	    (goto-char containing-sexp)
	    (setq placeholder (c-point 'boi))
	    (if (and (c-safe (backward-up-list 1) t)
		     (> (point) placeholder))
		(progn
		  (forward-char)
		  (skip-chars-forward " \t"))
	      (goto-char placeholder))
	    (c-add-stmt-syntax 'arglist-close (list containing-sexp) t nil
			       (c-most-enclosing-brace paren-state (point))
			       (c-whack-state-after (point) paren-state)))
	   ;; CASE 7B: Looking at the opening brace of an
	   ;; in-expression block or brace list.  C.f. cases 4, 16A
	   ;; and 17E.
	   ((and (eq char-after-ip ?{)
		 (progn
		   (setq placeholder (c-inside-bracelist-p (point)
							   c-state-cache))
		   (if placeholder
		       (setq tmpsymbol '(brace-list-open . inexpr-class))
		     (setq tmpsymbol '(block-open . inexpr-statement)
			   placeholder
			   (cdr-safe (c-looking-at-inexpr-block
				      (c-safe-position containing-sexp
						       paren-state)
				      containing-sexp)))
		     ;; placeholder is nil if it's a block directly in
		     ;; a function arglist.  That makes us skip out of
		     ;; this case.
		     )))
	    (goto-char placeholder)
	    (back-to-indentation)
	    (c-add-stmt-syntax (car tmpsymbol) nil t nil
			       (c-most-enclosing-brace paren-state (point))
			       (c-whack-state-after (point) paren-state))
	    (if (/= (point) placeholder)
		(c-add-syntax (cdr tmpsymbol))))
	   ;; CASE 7C: we are looking at the first argument in an empty
	   ;; argument list. Use arglist-close if we're actually
	   ;; looking at a close paren or bracket.
	   ((memq char-before-ip '(?\( ?\[))
	    (goto-char containing-sexp)
	    (setq placeholder (c-point 'boi))
	    (when (and (c-safe (backward-up-list 1) t)
		       (> (point) placeholder))
	      (forward-char)
	      (skip-chars-forward " \t")
	      (setq placeholder (point)))
	    (c-add-syntax 'arglist-intro placeholder))
	   ;; CASE 7D: we are inside a conditional test clause. treat
	   ;; these things as statements
	   ((progn
	      (goto-char containing-sexp)
	      (and (c-safe (c-forward-sexp -1) t)
		   (looking-at "\\<for\\>[^_]")))
	    (goto-char (1+ containing-sexp))
	    (c-forward-syntactic-ws indent-point)
	    (if (eq char-before-ip ?\;)
		(c-add-syntax 'statement (point))
	      (c-add-syntax 'statement-cont (point))
	      ))
	   ;; CASE 7E: maybe a continued ObjC method call. This is the
	   ;; case when we are inside a [] bracketed exp, and what
	   ;; precede the opening bracket is not an identifier.
	   ((and c-opt-method-key
		 (eq (char-after containing-sexp) ?\[)
		 (progn
		   (goto-char (1- containing-sexp))
		   (c-backward-syntactic-ws (c-point 'bod))
		   (if (not (looking-at c-symbol-key))
		       (c-add-syntax 'objc-method-call-cont containing-sexp))
		   )))
	   ;; CASE 7F: we are looking at an arglist continuation line,
	   ;; but the preceding argument is on the same line as the
	   ;; opening paren.  This case includes multi-line
	   ;; mathematical paren groupings, but we could be on a
	   ;; for-list continuation line.  C.f. case 7A.
	   ((progn
	      (goto-char (1+ containing-sexp))
	      (skip-chars-forward " \t")
	      (and (not (eolp))
		   (not (looking-at "\\\\$"))))
	    (goto-char containing-sexp)
	    (setq placeholder (c-point 'boi))
	    (if (and (c-safe (backward-up-list 1) t)
		     (> (point) placeholder))
		(progn
		  (forward-char)
		  (skip-chars-forward " \t"))
	      (goto-char placeholder))
	    (c-add-stmt-syntax 'arglist-cont-nonempty (list containing-sexp)
			       t nil
			       (c-most-enclosing-brace c-state-cache (point))
			       (c-whack-state-after (point) paren-state)))
	   ;; CASE 7G: we are looking at just a normal arglist
	   ;; continuation line
	   (t (c-forward-syntactic-ws indent-point)
	      (c-add-syntax 'arglist-cont (c-point 'boi)))
	   ))
	 ;; CASE 8: func-local multi-inheritance line
	 ((and (c-major-mode-is 'c++-mode)
	       (save-excursion
		 (goto-char indent-point)
		 (skip-chars-forward " \t")
		 (looking-at c-opt-decl-spec-key)))
	  (goto-char indent-point)
	  (skip-chars-forward " \t")
	  (cond
	   ;; CASE 8A: non-hanging colon on an inher intro
	   ((eq char-after-ip ?:)
	    (c-backward-syntactic-ws lim)
	    (c-add-syntax 'inher-intro (c-point 'boi)))
	   ;; CASE 8B: hanging colon on an inher intro
	   ((eq char-before-ip ?:)
	    (c-add-syntax 'inher-intro (c-point 'boi)))
	   ;; CASE 8C: a continued inheritance line
	   (t
	    (c-beginning-of-inheritance-list lim)
	    (c-add-syntax 'inher-cont (point))
	    )))
	 ;; CASE 9: we are inside a brace-list
	 ((setq special-brace-list
		(or (and c-special-brace-lists
			 (save-excursion
			   (goto-char containing-sexp)
			   (c-looking-at-special-brace-list)))
		    (c-inside-bracelist-p containing-sexp paren-state)))
	  (cond
	   ;; CASE 9A: In the middle of a special brace list opener.
	   ((and (consp special-brace-list)
		 (save-excursion
		   (goto-char containing-sexp)
		   (eq (char-after) ?\())
		 (eq char-after-ip (car (cdr special-brace-list))))
	    (goto-char (car (car special-brace-list)))
	    (skip-chars-backward " \t")
	    (if (and (bolp)
		     (assoc 'statement-cont
			    (setq placeholder (c-guess-basic-syntax))))
		(setq c-syntactic-context placeholder)
	      (c-beginning-of-statement-1
	       (c-safe-position (1- containing-sexp) paren-state))
	      (c-forward-token-1 0)
	      (if (looking-at "typedef\\>[^_]") (c-forward-token-1 1))
	      (c-add-syntax 'brace-list-open (c-point 'boi))))
	   ;; CASE 9B: brace-list-close brace
	   ((if (consp special-brace-list)
		;; Check special brace list closer.
		(progn
		  (goto-char (car (car special-brace-list)))
		  (save-excursion
		    (goto-char indent-point)
		    (back-to-indentation)
		    (or
		     ;; We were between the special close char and the `)'.
		     (and (eq (char-after) ?\))
			  (eq (1+ (point)) (cdr (car special-brace-list))))
		     ;; We were before the special close char.
		     (and (eq (char-after) (cdr (cdr special-brace-list)))
			  (= (c-forward-token-1) 0)
			  (eq (1+ (point)) (cdr (car special-brace-list)))))))
	      ;; Normal brace list check.
	      (and (eq char-after-ip ?})
		   (c-safe (goto-char (c-up-list-backward (point))) t)
		   (= (point) containing-sexp)))
	    (if (eq (point) (c-point 'boi))
		(c-add-syntax 'brace-list-close (point))
	      (setq lim (c-most-enclosing-brace c-state-cache (point)))
	      (c-beginning-of-statement-1 lim)
	      (c-add-stmt-syntax 'brace-list-close nil t t lim
				 (c-whack-state-after (point) paren-state))))
	   (t
	    ;; Prepare for the rest of the cases below by going to the
	    ;; token following the opening brace
	    (if (consp special-brace-list)
		(progn
		  (goto-char (car (car special-brace-list)))
		  (c-forward-token-1 1 nil indent-point))
	      (goto-char containing-sexp))
	    (forward-char)
	    (let ((start (point)))
	      (c-forward-syntactic-ws indent-point)
	      (goto-char (max start (c-point 'bol))))
	    (c-skip-ws-forward indent-point)
	    (cond
	     ;; CASE 9C: we're looking at the first line in a brace-list
	     ((= (point) indent-point)
	      (if (consp special-brace-list)
		  (goto-char (car (car special-brace-list)))
		(goto-char containing-sexp))
	      (if (eq (point) (c-point 'boi))
		  (c-add-syntax 'brace-list-intro (point))
		(setq lim (c-most-enclosing-brace c-state-cache (point)))
		(c-beginning-of-statement-1 lim)
		(c-add-stmt-syntax 'brace-list-intro nil t t lim
				   (c-whack-state-after (point) paren-state))))
	     ;; CASE 9D: this is just a later brace-list-entry or
	     ;; brace-entry-open
	     (t (if (or (eq char-after-ip ?{)
			(and c-special-brace-lists
			     (save-excursion
			       (goto-char indent-point)
			       (c-forward-syntactic-ws (c-point 'eol))
			       (c-looking-at-special-brace-list (point)))))
		    (c-add-syntax 'brace-entry-open (point))
		  (c-add-syntax 'brace-list-entry (point))
		  ))
	     ))))
	 ;; CASE 10: A continued statement or top level construct.
	 ((and (not (memq char-before-ip '(?\; ?:)))
	       (or (not (eq char-before-ip ?}))
		   (c-looking-at-inexpr-block-backward c-state-cache))
	       (> (point)
		  (save-excursion
		    (c-beginning-of-statement-1 containing-sexp)
		    (setq placeholder (point))))
	       (/= placeholder containing-sexp))
	  ;; This is shared with case 18.
	  (c-guess-continued-construct indent-point
				       char-after-ip
				       placeholder
				       containing-sexp
				       paren-state))
	 ;; CASE 14: A case or default label
	 ((looking-at c-label-kwds-regexp)
	  (goto-char containing-sexp)
	  (setq lim (c-most-enclosing-brace c-state-cache containing-sexp))
	  (c-backward-to-block-anchor lim)
	  (c-add-stmt-syntax 'case-label nil t nil
			     lim paren-state))
	 ;; CASE 15: any other label
	 ((looking-at c-label-key)
	  (goto-char containing-sexp)
	  (setq lim (c-most-enclosing-brace c-state-cache containing-sexp))
	  (save-excursion
	    (setq tmpsymbol
		  (if (and (eq (c-beginning-of-statement-1 lim) 'up)
			   (looking-at "switch\\>[^_]"))
		      ;; If the surrounding statement is a switch then
		      ;; let's analyze all labels as switch labels, so
		      ;; that they get lined up consistently.
		      'case-label
		    'label)))
	  (c-backward-to-block-anchor lim)
	  (c-add-stmt-syntax tmpsymbol nil t nil
			     lim paren-state))
	 ;; CASE 16: block close brace, possibly closing the defun or
	 ;; the class
	 ((eq char-after-ip ?})
	  ;; From here on we have the next containing sexp in lim.
	  (setq lim (c-most-enclosing-brace paren-state))
	  (goto-char containing-sexp)
	    (cond
	     ;; CASE 16E: Closing a statement block?  This catches
	     ;; cases where it's preceded by a statement keyword,
	     ;; which works even when used in an "invalid" context,
	     ;; e.g. a macro argument.
	     ((c-after-conditional)
	      (c-backward-to-block-anchor lim)
	      (c-add-stmt-syntax 'block-close nil t nil
				 lim paren-state))
	     ;; CASE 16A: closing a lambda defun or an in-expression
	     ;; block?  C.f. cases 4, 7B and 17E.
	     ((setq placeholder (c-looking-at-inexpr-block
				 (c-safe-position containing-sexp paren-state)
				 nil))
	      (setq tmpsymbol (if (eq (car placeholder) 'inlambda)
				  'inline-close
				'block-close))
	      (goto-char containing-sexp)
	      (back-to-indentation)
	      (if (= containing-sexp (point))
		  (c-add-syntax tmpsymbol (point))
		(goto-char (cdr placeholder))
		(back-to-indentation)
		(c-add-stmt-syntax tmpsymbol nil t nil
				   (c-most-enclosing-brace paren-state (point))
				   (c-whack-state-after (point) paren-state))
		(if (/= (point) (cdr placeholder))
		    (c-add-syntax (car placeholder)))))
	     ;; CASE 16B: does this close an inline or a function in
	     ;; an extern block or namespace?
	     ((setq placeholder (c-search-uplist-for-classkey paren-state))
	      (c-backward-to-decl-anchor lim)
	      (back-to-indentation)
	      (if (save-excursion
		    (goto-char (aref placeholder 0))
		    (looking-at c-other-decl-block-key))
		  (c-add-syntax 'defun-close (point))
		(c-add-syntax 'inline-close (point))))
	     ;; CASE 16F: Can be a defun-close of a function declared
	     ;; in a statement block, e.g. in Pike or when using gcc
	     ;; extensions.  Might also trigger it with some macros
	     ;; followed by blocks, and this gives sane indentation
	     ;; then too.  Let it through to be handled below.
	     ;; C.f. cases B.3 and 17G.
	     ((and (not inenclosing-p)
		   lim
		   (save-excursion
		     (and (not (c-looking-at-bos))
			  (eq (c-beginning-of-statement-1 lim nil nil t) 'same)
			  (setq placeholder (point)))))
	      (back-to-indentation)
	      (if (/= (point) containing-sexp)
		  (goto-char placeholder))
	      (c-add-stmt-syntax 'defun-close nil t nil
				 lim paren-state))
	     ;; CASE 16C: if there an enclosing brace that hasn't
	     ;; been narrowed out by a class, then this is a
	     ;; block-close.  C.f. case 17H.
	     ((and (not inenclosing-p) lim)
	      ;; If the block is preceded by a case/switch label on
	      ;; the same line, we anchor at the first preceding label
	      ;; at boi.  The default handling in c-add-stmt-syntax is
	      ;; really fixes it better, but we do like this to keep
	      ;; the indentation compatible with version 5.28 and
	      ;; earlier.
	      (while (and (/= (setq placeholder (point)) (c-point 'boi))
			  (eq (c-beginning-of-statement-1 lim) 'label)))
	      (goto-char placeholder)
	      (if (looking-at c-label-kwds-regexp)
		  (c-add-syntax 'block-close (point))
		(goto-char containing-sexp)
		;; c-backward-to-block-anchor not necessary here; those
		;; situations are handled in case 16E above.
		(c-add-stmt-syntax 'block-close nil t nil
				   lim paren-state)))
	     ;; CASE 16D: find out whether we're closing a top-level
	     ;; class or a defun
	     (t
	      (save-restriction
		(narrow-to-region (point-min) indent-point)
		(let ((decl (c-search-uplist-for-classkey (c-parse-state))))
		  (if decl
		      (c-add-class-syntax 'class-close decl paren-state)
		    (goto-char containing-sexp)
		    (c-backward-to-decl-anchor lim)
		    (back-to-indentation)
		    (c-add-syntax 'defun-close (point)))))
	      )))
	 ;; CASE 17: Statement or defun catchall.
	 (t
	  (goto-char indent-point)
	  ;; Back up statements until we find one that starts at boi.
	  (while (let* ((prev-point (point))
			(last-step-type (c-beginning-of-statement-1
					 containing-sexp)))
		   (if (= (point) prev-point)
		       (progn
			 (setq step-type (or step-type last-step-type))
			 nil)
		     (setq step-type last-step-type)
		     (/= (point) (c-point 'boi)))))
	  (cond
	   ;; CASE 17B: continued statement
	   ((and (eq step-type 'same)
		 (/= (point) indent-point))
	    (c-add-stmt-syntax 'statement-cont nil nil nil
			       containing-sexp paren-state))
	   ;; CASE 17A: After a case/default label?
	   ((progn
	      (while (and (eq step-type 'label)
			  (not (looking-at c-label-kwds-regexp)))
		(setq step-type
		      (c-beginning-of-statement-1 containing-sexp)))
	      (eq step-type 'label))
	    (c-add-stmt-syntax (if (eq char-after-ip ?{)
				   'statement-case-open
				 'statement-case-intro)
			       nil t nil containing-sexp paren-state))
	   ;; CASE 17D: any old statement
	   ((progn
	      (while (eq step-type 'label)
		(setq step-type
		      (c-beginning-of-statement-1 containing-sexp)))
	      (eq step-type 'previous))
	    (c-add-stmt-syntax 'statement nil t nil
			       containing-sexp paren-state)
	    (if (eq char-after-ip ?{)
		(c-add-syntax 'block-open)))
	   ;; CASE 17I: Inside a substatement block.
	   ((progn
	      ;; The following tests are all based on containing-sexp.
	      (goto-char containing-sexp)
	      ;; From here on we have the next containing sexp in lim.
	      (setq lim (c-most-enclosing-brace paren-state containing-sexp))
	      (c-after-conditional))
	    (c-backward-to-block-anchor lim)
	    (c-add-stmt-syntax 'statement-block-intro nil t nil
			       lim paren-state)
	    (if (eq char-after-ip ?{)
		(c-add-syntax 'block-open)))
	   ;; CASE 17E: first statement in an in-expression block.
	   ;; C.f. cases 4, 7B and 16A.
	   ((setq placeholder (c-looking-at-inexpr-block
			       (c-safe-position containing-sexp paren-state)
			       nil))
	    (setq tmpsymbol (if (eq (car placeholder) 'inlambda)
				'defun-block-intro
			      'statement-block-intro))
	    (back-to-indentation)
	    (if (= containing-sexp (point))
		(c-add-syntax tmpsymbol (point))
	      (goto-char (cdr placeholder))
	      (back-to-indentation)
	      (c-add-stmt-syntax tmpsymbol nil t nil
				 (c-most-enclosing-brace c-state-cache (point))
				 (c-whack-state-after (point) paren-state))
	      (if (/= (point) (cdr placeholder))
		  (c-add-syntax (car placeholder))))
	    (if (eq char-after-ip ?{)
		(c-add-syntax 'block-open)))
	   ;; CASE 17F: first statement in an inline, or first
	   ;; statement in a top-level defun. we can tell this is it
	   ;; if there are no enclosing braces that haven't been
	   ;; narrowed out by a class (i.e. don't use bod here).
	   ;; However, we first check for statements that we can
	   ;; recognize by keywords.  That increases the robustness in
	   ;; cases where statements are used on the top level,
	   ;; e.g. in macro definitions.
	   ((save-excursion
	      (save-restriction
		(widen)
		(c-narrow-out-enclosing-class paren-state containing-sexp)
		(not (c-most-enclosing-brace paren-state))))
	    (c-backward-to-decl-anchor lim)
	    (back-to-indentation)
	    (c-add-syntax 'defun-block-intro (point)))
	   ;; CASE 17G: First statement in a function declared inside
	   ;; a normal block.  This can occur in Pike and with
	   ;; e.g. the gcc extensions.  Might also trigger it with
	   ;; some macros followed by blocks, and this gives sane
	   ;; indentation then too.  C.f. cases B.3 and 16F.
	   ((save-excursion
	      (and (not (c-looking-at-bos))
		   (eq (c-beginning-of-statement-1 lim nil nil t) 'same)
		   (setq placeholder (point))))
	    (back-to-indentation)
	    (if (/= (point) containing-sexp)
		(goto-char placeholder))
	    (c-add-stmt-syntax 'defun-block-intro nil t nil
			       lim paren-state))
	   ;; CASE 17H: First statement in a block.  C.f. case 16C.
	   (t
	    ;; If the block is preceded by a case/switch label on the
	    ;; same line, we anchor at the first preceding label at
	    ;; boi.  The default handling in c-add-stmt-syntax is
	    ;; really fixes it better, but we do like this to keep the
	    ;; indentation compatible with version 5.28 and earlier.
	    (while (and (/= (setq placeholder (point)) (c-point 'boi))
			(eq (c-beginning-of-statement-1 lim) 'label)))
	    (goto-char placeholder)
	    (if (looking-at c-label-kwds-regexp)
		(c-add-syntax 'statement-block-intro (point))
	      (goto-char containing-sexp)
	      ;; c-backward-to-block-anchor not necessary here; those
	      ;; situations are handled in case 17I above.
	      (c-add-stmt-syntax 'statement-block-intro nil t nil
				 lim paren-state))
	    (if (eq char-after-ip ?{)
		(c-add-syntax 'block-open)))
	   ))
	 )
	;; now we need to look at any modifiers
	(goto-char indent-point)
	(skip-chars-forward " \t")
	;; are we looking at a comment only line?
	(when (and (looking-at c-comment-start-regexp)
		   (/= (c-forward-token-1 0 nil (c-point 'eol)) 0))
	  (c-append-syntax 'comment-intro))
	;; we might want to give additional offset to friends (in C++).
	(when (and c-opt-friend-key
		   (looking-at c-opt-friend-key))
	  (c-append-syntax 'friend))

	;; Set syntactic-relpos.
	(let ((p c-syntactic-context))
	  (while (and p
		      (if (integerp (car-safe (cdr-safe (car p))))
			  (progn
			    (setq syntactic-relpos (car (cdr (car p))))
			    nil)
			t))
	    (setq p (cdr p))))

	;; Start of or a continuation of a preprocessor directive?
	(if (and macro-start
		 (eq macro-start (c-point 'boi))
		 (not (and (c-major-mode-is 'pike-mode)
			   (eq (char-after (1+ macro-start)) ?\"))))
	    (c-append-syntax 'cpp-macro)
	  (when (and c-syntactic-indentation-in-macros macro-start)
	    (if in-macro-expr
		(when (or
		       (< syntactic-relpos macro-start)
		       (not (or
			     (assq 'arglist-intro c-syntactic-context)
			     (assq 'arglist-cont c-syntactic-context)
			     (assq 'arglist-cont-nonempty c-syntactic-context)
			     (assq 'arglist-close c-syntactic-context))))
		  ;; If inside a cpp expression, i.e. anywhere in a
		  ;; cpp directive except a #define body, we only let
		  ;; through the syntactic analysis that is internal
		  ;; in the expression.  That means the arglist
		  ;; elements, if they are anchored inside the cpp
		  ;; expression.
		  (setq c-syntactic-context nil)
		  (c-add-syntax 'cpp-macro-cont macro-start))
	      (when (and (eq macro-start syntactic-relpos)
			 (not (assq 'cpp-define-intro c-syntactic-context))
			 (save-excursion
			   (goto-char macro-start)
			   (or (not (c-forward-to-cpp-define-body))
			       (<= (point) (c-point 'boi indent-point)))))
		;; Inside a #define body and the syntactic analysis is
		;; anchored on the start of the #define.  In this case
		;; we add cpp-define-intro to get the extra
		;; indentation of the #define body.
		(c-add-syntax 'cpp-define-intro)))))
	;; return the syntax
	c-syntactic-context))))


(defun c-echo-parsing-error (&optional quiet)
  (when (and c-report-syntactic-errors c-parsing-error (not quiet))
    (c-benign-error "%s" c-parsing-error))
  c-parsing-error)

(defun c-evaluate-offset (offset langelem symbol)
  ;; offset can be a number, a function, a variable, a list, or one of
  ;; the symbols + or -
  (cond
   ((eq offset '+)         c-basic-offset)
   ((eq offset '-)         (- c-basic-offset))
   ((eq offset '++)        (* 2 c-basic-offset))
   ((eq offset '--)        (* 2 (- c-basic-offset)))
   ((eq offset '*)         (/ c-basic-offset 2))
   ((eq offset '/)         (/ (- c-basic-offset) 2))
   ((numberp offset)       offset)
   ((functionp offset)     (c-evaluate-offset
			    (funcall offset
				     (cons (car langelem)
					   (car-safe (cdr langelem))))
			    langelem symbol))
   ((vectorp offset)       offset)
   ((null offset)          nil)
   ((listp offset)
    (let (done)
      (while (and (not done) offset)
	(setq done (c-evaluate-offset (car offset) langelem symbol)
	      offset (cdr offset)))
      (if (and c-strict-syntax-p (not done))
	  (c-benign-error "No offset found for syntactic symbol %s" symbol))
      done))
   (t (symbol-value offset))
   ))

(defun c-calc-offset (langelem)
  ;; Get offset from LANGELEM which is a list beginning with the
  ;; syntactic symbol and followed by any analysis data it provides.
  ;; That data may be zero or more elements, but if at least one is
  ;; given then the first is the relpos (or nil).  The symbol is
  ;; matched against `c-offsets-alist' and the offset calculated from
  ;; that is returned.
  (let* ((symbol (car langelem))
	 (match  (assq symbol c-offsets-alist))
	 (offset (cdr-safe match)))
    (if match
	(setq offset (c-evaluate-offset offset langelem symbol))
      (if c-strict-syntax-p
	  (c-benign-error "No offset found for syntactic symbol %s" symbol))
      (setq offset 0))
    (if (vectorp offset)
	offset
      (or (and (numberp offset) offset)
	  (and (symbolp offset) (symbol-value offset))
	  0))
    ))

(defun c-get-offset (langelem)
  ;; This is a compatibility wrapper for `c-calc-offset' in case
  ;; someone is calling it directly.  It takes an old style syntactic
  ;; element on the form (SYMBOL . RELPOS) and converts it to the new
  ;; list form.
  (if (cdr langelem)
      (c-calc-offset (list (car langelem) (cdr langelem)))
    (c-calc-offset langelem)))

(defun c-get-syntactic-indentation (langelems)
  ;; Calculate the syntactic indentation from a syntactic description
  ;; as returned by `c-guess-syntax'.
  ;;
  ;; Note that topmost-intro always has a relpos at bol, for
  ;; historical reasons.  It's often used together with other symbols
  ;; that has more sane positions.  Since we always use the first
  ;; found relpos, we rely on that these other symbols always precede
  ;; topmost-intro in the LANGELEMS list.
  (let ((indent 0) anchor)

    (while langelems
      (let* ((c-syntactic-element (car langelems))
	     (res (c-calc-offset c-syntactic-element)))

	(if (vectorp res)
	    ;; Got an absolute column that overrides any indentation
	    ;; we've collected so far, but not the relative
	    ;; indentation we might get for the nested structures
	    ;; further down the langelems list.
	    (setq indent (elt res 0)
		  anchor (point-min))	; A position at column 0.

	  ;; Got a relative change of the current calculated
	  ;; indentation.
	  (setq indent (+ indent res))

	  ;; Use the anchor position from the first syntactic
	  ;; element with one.
	  (unless anchor
	    (let ((relpos (car-safe (cdr (car langelems)))))
	      (if relpos
		  (setq anchor relpos)))))

	(setq langelems (cdr langelems))))

    (if anchor
	(+ indent (save-excursion
		    (goto-char anchor)
		    (current-column)))
      indent)))


(cc-provide 'cc-engine)

;;; cc-engine.el ends here
