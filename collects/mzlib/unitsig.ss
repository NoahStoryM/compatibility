
(module unitsig mzscheme
  (import "exstruct.ss")
  (import "unit.ss")
  (import "private/sigmatch.ss")

  (import-for-syntax "private/sigutil.ss")
  (import-for-syntax "private/sigmatch.ss")
  (import-for-syntax (lib "kerncase.ss" "syntax"))

  (define-struct/export unit/sig (unit imports exports))

  (define-syntax define-signature
    (lambda (expr)
      (syntax-case expr ()
	[(_ name sig)
	 (identifier? (syntax name))
	 (let ([sig (get-sig 'define-signature expr (syntax-e (syntax name))
			     (syntax sig))])
	   (with-syntax ([content (explode-sig sig)])
	     (syntax (define-syntax name
		       (make-sig (quote content))))))])))

  (define-syntax let-signature
    (lambda (expr)
      (syntax-case expr ()
	[(_ name sig . body)
	 (identifier? (syntax name))
	 (let ([sig (get-sig 'let-signature expr (syntax-e (syntax name))
			     (syntax sig))])
	   (with-syntax ([content (explode-sig sig)])
	     (syntax (letrec-syntax ([name (make-sig (quote content))])
		       . body))))])))
  
  (define-syntax unit/sig
    (lambda (expr)
      (syntax-case expr ()
	[(_ sig . rest)
	 (let ([sig (get-sig 'unit/sig expr #f (syntax sig))])
	  (let ([a-unit (parse-unit expr (syntax rest) sig
				    (kernel-form-identifier-list (quote-syntax here))
				    (quote-syntax define-values)
				    (quote-syntax begin))])
	    (check-signature-unit-body sig a-unit (parse-unit-renames a-unit) 'unit/sig expr)
	    (with-syntax ([imports (datum->syntax
				    (flatten-signatures (parse-unit-imports a-unit))
				    expr expr)]
			  [exports (datum->syntax
				    (map
				     (lambda (name)
				       (list (do-rename name (parse-unit-renames a-unit))
					     name))
				     (signature-vars sig))
				    expr expr)]
			  [body (reverse! (parse-unit-body a-unit))]
			  [import-sigs (explode-named-sigs (parse-unit-imports a-unit))]
			  [export-sig (explode-sig sig)])
	    (syntax
	     (make-unit/sig
	      (unit
		(import . imports)
		(export . exports)
		. body)
	      (quote import-sigs)
	      (quote export-sig))))))])))  

  (define-syntax compound-unit/sig
    (lambda (expr)
      (syntax-case expr ()
	[(_ . body)
	 (let-values ([(tags
			exprs
			exploded-link-imports
			exploded-link-exports
			flat-imports
			link-imports
			flat-exports
			exploded-imports
			exploded-exports)
		       (parse-compound-unit expr (syntax body))]
		      [(t) (lambda (l) (datum->syntax l expr expr))])
	   (with-syntax ([(tag ...) (t tags)]
			 [(uexpr ...) (t exprs)]
			 [(tagx ...) (t (map (lambda (t) (string->symbol (format "u:~a" t))) tags))]
			 [exploded-link-imports (t exploded-link-imports)]
			 [exploded-link-exports (t exploded-link-exports)]
			 [flat-imports (t flat-imports)]
			 [(link-import ...) (t link-imports)]
			 [flat-exports (t flat-exports)]
			 [exploded-imports (t exploded-imports)]
			 [exploded-exports (t exploded-exports)])
	     (syntax/loc
	      expr
	      (let ([tagx uexpr] ...)
		(verify-linkage-signature-match
		 'compound-unit/sig
		 '(tag ...)
		 (list tagx ...)
		 'exploded-link-imports
		 'exploded-link-exports)
		;; All checks done. Make the unit:
		(make-unit/sig
		 (compound-unit
		  (import . flat-imports)
		  (link [tag ((unit/sig-unit tagx)
			      . link-import)]
			...)
		  (export . flat-exports))
		 'exploded-imports
		 'exploded-exports)))))])))

  (define-syntax invoke-unit/sig
    (lambda (expr)
      (syntax-case expr ()
	[(_ u sig ...)
	 (let ([sigs (parse-invoke-vars 'invoke-unit/sig (syntax (sig ...)) expr)])
	   (with-syntax ([exploded-sigs (datum->syntax (explode-named-sigs sigs) 
						       expr expr)]
			 [flat-sigs (datum->syntax (flatten-signatures sigs) 
						   expr expr)])
	     (syntax/loc
	      expr
	      (let ([unt u])
		(verify-linkage-signature-match
		 (quote invoke-unit/sig)
		 (quote (invoke))
		 (list unt)
		 (quote (#()))
		 (quote (exploded-sigs)))
		(invoke-unit (unit/sig-unit u)
			     . flat-sigs)))))])))
  
  (define-syntax unit->unit/sig
    (lambda (expr)
      (syntax-case expr ()
	[(_ e (im-sig ...) ex-sig)
	 (let ([im-sigs (map (lambda (sig)
			       (get-sig 'unit->unit/sig expr #f sig))
			     (syntax->list (syntax (im-sig ...))))]
	       [ex-sig (get-sig 'unit->unit/sig expr #f (syntax ex-sig))])
	   (with-syntax ([exploded-imports (datum->syntax (explode-named-sigs im-sigs)
							  expr expr)]
			 [exploded-exports (datum->syntax (explode-sig ex-sig)
							  expr expr)])
	     (syntax
	      (make-unit/sig
	       e
	       (quote exploded-imports)
	      (quote exploded-exports)))))])))

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

  (define verify-linkage-signature-match
    (let ([make-exn make-exn:unit]
	  [p-suffix (lambda (pos) (case pos [(1) 'st][(2) 'nd][(3) 'rd][else 'th]))])
      (lambda (who tags units esigs isigs)
	(for-each
	 (lambda (u tag)
	   (unless (unit/sig? u)
	     (raise
	      (make-exn
	       (string->immutable-string
		(format
		 "~s: expression for \"~s\" is not a signed unit: ~e"
		 who tag u))
	       (current-continuation-marks)))))
	 units tags)
	(for-each
	 (lambda (u tag esig)
	   (verify-signature-match
	    who #f
	    (format "specified export signature for ~a" tag)
	    esig
	    (format "export signature for actual ~a sub-unit" tag)
	    (unit/sig-exports u)))
	 units tags esigs)
	(for-each
	 (lambda (u tag isig)
	   (let ([n (length (unit/sig-imports u))]
		 [c (length isig)])
	     (unless (= c n)
	       (raise
		(make-exn
		 (string->immutable-string
		  (format
		   "~s: ~a unit imports ~a units, but ~a units were provided"
		   who tag n c))
		 (current-continuation-marks))))))
	 units tags isigs)
	(for-each
	 (lambda (u tag isig)
	   (let loop ([isig isig][expecteds (unit/sig-imports u)][pos 1])
	     (unless (null? isig)
	       (let ([expected (car expecteds)]
		     [provided (car isig)])
		 (verify-signature-match
		  who #t
		  (format "~a unit's ~s~s import (which is ~a)" tag
			  pos (p-suffix pos)
			  (car expected))
		  (cdr expected)
		  (format "~a's ~s~s linkage (which is ~a)"
			  tag
			  pos (p-suffix pos)
			  (car provided))
		  (cdr provided))
		 (loop (cdr isig) (cdr expecteds) (add1 pos))))))
	 units tags isigs))))

  (define-syntax signature->symbols
    (lambda (stx)
      (syntax-case stx ()
	[(_ name)
	 (identifier? (syntax name))
	 (let ([sig (get-sig 'signature->symbols stx #f (syntax name))])
	   (with-syntax ([e (explode-sig sig)])
	     (syntax 'e)))])))

  ;; Internal:
  (define-syntax do-define-values/invoke-unit/sig
    (lambda (stx)
      (syntax-case stx ()
	[(_ global? signame unite prefix imports orig)
	 (let* ([formname (if (syntax-e (syntax global?))
			      'global-define-values/invoke-unit/sig
			      'define-values/invoke-unit/sig)]
		[badsyntax (lambda (s why)
			     (raise-syntax-error
			      formname
			      (format "bad syntax (~a)" why)
			      (syntax orig)
			      s))])
	   (unless (or (not (syntax-e (syntax prefix)))
		       (identifier? (syntax prefix)))
	     (badsyntax (syntax prefix) "prefix is not an identifier"))
	   (let ([ex-sig (get-sig formname (syntax orig) #f (syntax signame))])
	     (let ([ex-exploded (explode-sig ex-sig)]
		   [ex-flattened (flatten-signature #f ex-sig)])
	       (let ([im-sigs
		      (map
		       (lambda (s)
			 (get-sig formname (syntax orig) #f s))
		       (syntax->list (syntax imports)))])
		 (let ([im-explodeds (explode-named-sigs im-sigs)]
		       [im-flattened (apply append (map (lambda (x) (flatten-signature #f x)) im-sigs))]
		       [d->s (lambda (x) (datum->syntax x (syntax orig) (syntax orig)))])
		   (with-syntax ([dv/iu (if (syntax-e (syntax global?))
					    (quote-syntax global-define-values/invoke-unit)
					    (quote-syntax define-values/invoke-unit))]
				 [ex-flattened (d->s ex-flattened)]
				 [ex-exploded (d->s ex-exploded)]
				 [im-explodeds (d->s im-explodeds)]
				 [im-flattened (d->s im-flattened)]
				 [formname formname])
		     (syntax
		      (dv/iu
		       ex-flattened
		       (let ([unit-var unite])
			 (verify-linkage-signature-match
			  'formname
			  '(invoke)
			  (list unit-var)
			  '(ex-exploded)
			  '(im-explodeds))
			 (unit/sig-unit unit-var))
		       prefix
		       . im-flattened))))))))])))
  
  (define-syntax define-values/invoke-unit/sig
    (lambda (stx)
      (with-syntax ([orig stx])
	(syntax-case stx ()
	  [(_ signame unit prefix . imports)
	   (syntax (do-define-values/invoke-unit/sig #f signame unit prefix imports orig))]
	  [(_ signame unit)
	   (syntax (do-define-values/invoke-unit/sig #f signame unit #f () orig))]))))

  (define-syntax global-define-values/invoke-unit/sig
    (lambda (stx)
      (with-syntax ([orig stx])
	(syntax-case stx ()
	  [(_ signame unit prefix . imports)
	   (syntax (do-define-values/invoke-unit/sig #t signame unit prefix imports orig))]
	  [(_ signame unit)
	   (syntax (do-define-values/invoke-unit/sig #t signame unit #f () orig))]))))

  (define-syntax export-signature-elements
    (lambda (stx)
      (with-syntax ([orig stx])
	(syntax-case stx ()
	  [(_ signame)
	   (let ([sig (get-sig 'export-signature-elements stx #f (syntax signame))])
	     (let ([flattened (flatten-signature #f sig)])
	       (with-syntax ([flattened (map (lambda (x) (datum->syntax x #f (syntax signame)))
					     flattened)])
		 (syntax
		  (export . flattened)))))]))))
  
  (export-indirect verify-linkage-signature-match)

  (export define-signature
	  let-signature
          unit/sig
          compound-unit/sig
	  invoke-unit/sig
	  unit->unit/sig
	  signature->symbols
	  
	  define-values/invoke-unit/sig
	  global-define-values/invoke-unit/sig
	  export-signature-elements))
