;;;; jyoon.lisp

(in-package #:jyoon)

;; those are used by the generator internally and should be globally unbound
(defvar *schema*)
(defvar *proto*)
(defvar *host*)
(defvar *base-path*)
(defvar *accept-header*)
(defvar *endpoint*)
(defvar *url*)
(defvar *path-params*)

(defun lisp-sym (str)
  (read-from-string (kebab:to-lisp-case str)))

(defmacro either (&rest vals)
  `(loop for val in (list ,@vals) do (if val (return val))))

(defun genparams (op urlsym hdrsym paramssym bodysym formsym)
  (let ((required '())
	(optional '())

	(code '()))
    (loop
      for param in (append *path-params* (cdr (assoc :|parameters| (cdr op))))
      do (let* ((name (cdr (assoc :|name| param)))
		(namesym (lisp-sym name))
		(namesym-p (lisp-sym (concatenate 'string name "-supplied-p")))
		(isrequired (cdr (assoc :|required| param)))
		(in (cdr (assoc :|in| param))))
	   (if isrequired
	       (push namesym required)
	       (push `(,namesym nil ,namesym-p) optional))
	   (push
	    `(if ,(if isrequired t namesym-p)
		 ,(switch (in :test #'string=)
		    ("path"
		     `(setf ,urlsym
			    (cl-ppcre:regex-replace ,(format nil "{~a}" name)
						    ,urlsym
						    (format nil "~a" ,namesym))))
		    ("query"
		     `(push (cons ,name (format nil "~a" ,namesym))
			    ,paramssym))
		    ("header"
		     `(push (cons ,name (format nil "~a" ,namesym))
			    ,hdrsym))
		    ("body"
		     `(setf ,bodysym
			    (concatenate 'string ,bodysym
					 (json:encode-json ,namesym))))
		    ("formData"
		     `(progn
			(setf ,formsym t)
			(push (cons ,name (format nil "~a" ,namesym))
			      ,paramssym)))
		    (otherwise
		     (warn "Don't know how to handle parameters in ~a." in))))
		 code)))
    (if (> (length optional) 0)
	(push '&key optional))
    (values (append required optional) code)))

(defun opmethod (op) ; FIXME is there a better way to "uppercase a symbol"?
  (read-from-string (concatenate 'string ":" (string (car op)))))

(defun ophelp (op)
  (cdr (assoc :|summary| (cdr op))))

(defun path-funcname (pathop)
  (lisp-sym (cdr (assoc :|operationId| (cdr pathop)))))

(defun genfunc (op)
  (with-gensyms (urlsym hdrsym paramssym bodysym formsym responsesym streamsym)
    (multiple-value-bind (params code) (genparams op urlsym hdrsym paramssym bodysym formsym)
      `(defun ,(path-funcname op) ,params ; FIXME
	 ,(ophelp op)
	 (let ((,urlsym ,*url*)
	       (,hdrsym '())
	       (,paramssym '())
	       (,bodysym nil)
	       (,formsym nil))
	   ,@code
	   (let ((,responsesym (drakma:http-request ,urlsym
						    :method ,(opmethod op)
						    :parameters ,paramssym
						    :additional-headers ,hdrsym
						    :form-data ,formsym
						    :content ,bodysym)))
	     (with-input-from-string (,streamsym (flexi-streams:octets-to-string ,responsesym))
	       (json:decode-json ,streamsym)))))))) ; FIXME we just assume this returns json, it might not

(defun swagger-bindings ()
  `(progn
     ,@(loop
	 for path in (cdr (assoc :|paths| *schema*))
	 append (let* ((*endpoint*    (string (car path)))
		       (*url*         (format nil "~a://~a~a~a" *proto* *host* *base-path* *endpoint*))
		       (*path-params* (cdr (assoc :|parameters| (cdr path)))))
		  (loop
		    for op in (cdr path)
		    collect (genfunc op))))))

(defun generate-bindings (jsonstream &optional proto host base-path *accept-header*)
  (let* ((cl-json:*json-identifier-name-to-lisp* (lambda (x) x))
	 (*schema*    (json:decode-json jsonstream))
	 
	 (version     (either (cdr (assoc :|swagger| *schema*)) (cdr (assoc :|openapi| *schema*))))
	 
	 (*proto*     (either proto     (cadr (assoc :|schemes| *schema*))    ))
	 (*host*      (either host      (cdr (assoc :|host| *schema*))        ))
	 (*base-path* (either base-path (cdr (assoc :|basePath| *schema*)) "/")))
    (switch (version :test #'string=)
      ("2.0" (swagger-bindings))
      (otherwise
       (error "Unsupported swagger version ~a." version)))))
  
;;; lazy and sloppy

(defmacro from-source ((name) &body body)
  `(defmacro ,(read-from-string (concatenate 'string "bindings-from-" (string name)))
       (,name &key proto host base-path (accept-header "application/json"))
     ,@body))

(defmacro bindings-from (var)
  `(generate-bindings ,var proto host base-path accept-header))

(from-source (file)
  (with-open-file (stream (eval file)) (bindings-from stream)))

(from-source (json)
  (with-input-from-string (stream (eval json)) (bindings-from stream)))

(from-source (url) ; FIXME there has to be a better way to do this
  (with-input-from-string (stream (flexi-streams:octets-to-string (drakma:http-request url)))
    (bindings-from stream)))
