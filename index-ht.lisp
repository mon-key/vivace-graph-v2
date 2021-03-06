(in-package #:vivace-graph-v2)

(defstruct index-cursor                 ; make-index-cursor
  index                                 ; index-cursor-index
  vector                                ; index-cursor-vector
  pointer)                              ; index-cursor-pointer

(defgeneric idx-equal (a b)
  (:method ((a string) (b string)) 
    (string= a b))
  (:method ((a number) (b number))
    (= a b))
  (:method ((a symbol) (b symbol))
    (eq a b))
  ;; :NOTE Prior to evaluting `cl:every' for vectors A and B
  ;; It may be useful to first test: 
  ;;  `cl:array-element-type' and `cl:upgraded-array-element-type'   -- MON
  (:method ((a vector) (b vector))
    (when (= (length a) (length b))
      (every #'idx-equal a b)))
  ;; lets be explicit about it
  ;; :WAS (:method (a b) (equal a b))
  (:method ((a t) (b t))
    (equal a b)))

(defun sxhash-idx (item) 
  (sxhash item))

;; :WAS 
;; (sb-ext:define-hash-table-test idx-equal sxhash-idx)
(vg-define-hash-table-test idx-equal sxhash-idx)

;(defun make-idx-table (&key synchronized)
;  (vg-make-hash-table :test 'idx-equal :synchronized synchronized))

(defun cursor-value (cursor &key (transform-fn #'identity))
  (handler-case
      (funcall transform-fn
	       (aref (index-cursor-vector cursor) (index-cursor-pointer cursor)))
    ;; :TODO Factor this out, its basically a type-error -- MON
    (sb-int:invalid-array-index-error (condition)
      (declare (ignore condition))
      nil)))

(defun cursor-next (cursor &key (transform-fn #'identity))
  (handler-case
      (funcall transform-fn
	       (aref (index-cursor-vector cursor) 
		     (incf (index-cursor-pointer cursor))))
    ;; :TODO Factor this out, its basically a type-error -- MON
    (sb-int:invalid-array-index-error (condition)
      (declare (ignore condition))
      (decf (index-cursor-pointer cursor))
      nil)))

(defun cursor-prev (cursor &key (transform-fn #'identity))
  (handler-case
      (funcall transform-fn 
	       (aref (index-cursor-vector cursor) 
		     (decf (index-cursor-pointer cursor))))
    ;; :TODO Factor this out, its basically a type-error -- MON
    (sb-int:invalid-array-index-error (condition)
      (declare (ignore condition))
      (incf (index-cursor-pointer cursor))
      nil)))

(defun cursor-close (cursor)
  (setf (index-cursor-index   cursor) nil
	(index-cursor-vector  cursor) nil
	(index-cursor-pointer cursor) nil))

(defun map-cursor (fn cursor &key collect?)
  (setf (index-cursor-pointer cursor) 0)
  (let ((result ()))
    (loop 
       for i from 0 to (1- (length (index-cursor-vector cursor)))
       do (if collect?
              (push (funcall fn (aref (index-cursor-vector cursor) i)) result)
              (funcall fn (aref (index-cursor-vector cursor) i))))
    (nreverse result)))
  
(defstruct index                        ; make-index
  name                                  ; index-name
  table                                 ; index-table
  test                                  ; index-test
  locks)                                ; index-locks

;;(defun make-hierarchical-index (&key name (test 'idx-equal))
(defun make-hierarchical-index (&key name (test 'eql))
  (make-index :name name
	      :test test
	      :table (vg-make-hash-table :test test :synchronized t)
	      :locks (vg-make-hash-table :synchronized t :test 'equal)))

(defun hash-table-keys (ht)
  (let ((keys nil))
    ;; (hcl:with-hash-table-locked (ht)
    (sb-ext:with-locked-hash-table (ht)
      (maphash #'(lambda (k v) 
                   (declare (ignore v))
                   (push k keys))
               ht))
    keys))

(defun fetch-all-leaves (ht)
  (let ((leaves (make-array 0 :adjustable t :fill-pointer t)))
    (labels ((fetch-all (ht1)
               ;; (hcl:with-hash-table-locked (ht)
	       (sb-ext:with-locked-hash-table (ht)
		 (maphash #'(lambda (k v)
			      (declare (ignore k))
			      (typecase v
				(hash-table (fetch-all v))
				(list       (dolist (leaf v)
                                              (vector-push-extend leaf leaves)))
				(t          (vector-push-extend v leaves))))
			  ht1))))
      (fetch-all ht))
    (if (> (length leaves) 0)
	leaves
	nil)))

;; :NOTE This is already using `cl:labels' so why not make dedicated wrappers
;; for the anonymous functions in `cl:maphash' wouldn't SBCL be able to optimize
;; these better?
;; Also, why not just lock the entire INDEX with `sb-ext:with-locked-hash-table' instead?
;; Also, consider using `sb-thread:with-recursive-lock' 
(defun delete-index-path (index path &key return-values?)
  (let ((vals nil))
    (labels ((descend (ht keys)
	       (if (eq (first keys) '*)
                   ;; (hcl:with-hash-table-locked (ht)
		   (sb-ext:with-locked-hash-table (ht)
		     (maphash #'(lambda (k v) 
				  (declare (ignore k)) 
				  (descend v (rest keys))) ht))
		   (multiple-value-bind (value found?) (gethash (first keys) ht)
		     (when found?
		       (if (hash-table-p value)
			   (if (null (rest keys))
			       (progn
				 (when return-values?
                                   ;; LispWorks hcl:with-hash-table-locked hash-table &body body => results
				   (sb-ext:with-locked-hash-table (value)
				     (maphash #'(lambda (k v) 
						  (declare (ignore k)) 
						  (push v vals)) 
					      value)))
				 (remhash (first keys) ht))
			       (descend value (rest keys)))
			   (remhash (first keys) ht)))))))
      (descend index path))
    vals))

(defun descend-ht (ht keys)
  (assert (not (null keys)) nil "keys must be non-null.")
  (if (eq (first keys) '*)
      ;; (hcl:with-hash-table-locked (ht)
      (sb-ext:with-locked-hash-table (ht)
	(maphash #'(lambda (k v) 
		     (declare (ignore k)) 
		     (if (hash-table-p v)
			 (descend-ht v (rest keys))
			 ()))
		 ht))
      (multiple-value-bind (value found?) (gethash (first keys) ht)
	(if found?
	    (if (hash-table-p value)
		(if (null (rest keys))
		    (fetch-all-leaves value)
		    (descend-ht value (rest keys)))
		(if (null (rest keys))
		    (values (make-array 1 :initial-element value) t)))
	    (values nil nil)))))

;; :NOTE Shouldn't the `make-index-cursor' when local var RESULT is null be: 
;;   (make-array 0 :fill-pointer 0) instead of #()?
;; (type-of #()) => (simple-vector 0)
;; (type-of (make-array 0 :fill-pointer 0)) => (and (vector t 0) (not simple-array))
;; (vector-push-extend 'bubba #()) => error
;; (vector-push-extend 'bubba (make-array 0 :fill-pointer 0)) => 0
(defun get-from-index (index &rest keys)
  (let ((result (descend-ht (index-table index) keys)))
    (cond ((null result)
           (make-index-cursor :index index :vector #() :pointer 0))
	  ((vectorp result)
           (make-index-cursor :index index :vector result :pointer 0))
	  (t
           result))))

(defun find-or-create-ht (ht keys create-fn &optional (d 0))
  (assert (not (null keys)) nil "keys must be non-null.")
  ;; (hcl:with-hash-table-locked (ht)
  (sb-ext:with-locked-hash-table (ht)
    (multiple-value-bind (value found?) (gethash (first keys) ht)
      (unless (and found? (typep value 'hash-table))
	(setf (gethash (first keys) ht) (funcall create-fn)))))
  (cond ((null (rest keys))
	 (values ht (first keys)))
	((= 1 (length (rest keys)))
	 (values (gethash (first keys) ht) (first (rest keys))))
	(t
	 (find-or-create-ht (gethash (first keys) ht)
                            (rest keys)
                            create-fn
                            (1+ d)))))

(defun add-to-index (index value &rest keys)
  (let ((ht (find-or-create-ht (index-table index) 
			       keys 
			       #'(lambda () 
				   (vg-make-hash-table :synchronized t 
                                                       :test (index-test index))))))
    (setf (gethash (car (last keys)) ht) value)))

(defun delete-from-index (index value &rest keys)
  ;; FIXME: implement
  (declare (ignore index value keys)))

(defun check-index ()
  (maphash #'(lambda (k v)
               (declare ingore v)
               (format t "~A: ~A~%" k (type-of k))) 
	   (gethash :posgi-idx (vivace-graph-v2::index-table (main-idx *store*)))))

(defun get-table-to-lock (idx &rest keys)
  (find-or-create-ht (index-table idx)
		     keys 
		     #'(lambda ()
			 (vg-make-hash-table :synchronized t 
                                             :test (index-test idx)))))

(defmacro with-locked-index ((idx &rest keys) &body body)
  (if keys
      (with-gensyms (sub-idx last-key)
	`(multiple-value-bind (,sub-idx ,last-key) (get-table-to-lock ,idx ,@keys)
           ;; `(hcl:with-hash-table-locked (,sub-idx))
	   (sb-ext:with-locked-hash-table (,sub-idx)
	     ;;(format t "Locked ht ~A / ~A~%" ,last-key ,sub-idx)
	     ,@body)))
      ;; `(hcl:with-hash-table-locked ((index-table ,idx))
      `(sb-ext:with-locked-hash-table ((index-table ,idx))
	 ,@body)))

(defun test-index ()
  (let ((index (make-hierarchical-index :test 'equal)))
    (add-to-index index "abc" "a" "b" "c")
    (add-to-index index "abd" "a" "b" "d")
    (add-to-index index "abe" "a" "b" "e")
    (add-to-index index "abz" "a" "b" "z")
    (add-to-index index "abx" "a" "b" "x")
    (add-to-index index "aby" "a" "b" "y")
    (add-to-index index "acy" "a" "c" "y")
    (add-to-index index "bcy" "b" "c" "y")
    ;; (get-from-index index "b" "c")
    (get-from-index index "a" "b")))
