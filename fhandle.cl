;; -*- mode: common-lisp -*-
;;
;; Copyright (C) 2001 Franz Inc, Berkeley, CA.  All rights reserved.
;;
;; This code is free software; you can redistribute it and/or
;; modify it under the terms of the version 2.1 of
;; the GNU Lesser General Public License as published by 
;; the Free Software Foundation, as clarified by the Franz
;; preamble to the LGPL found in
;; http://opensource.franz.com/preamble.html.
;;
;; This code is distributed in the hope that it will be useful,
;; but without any warranty; without even the implied warranty of
;; merchantability or fitness for a particular purpose.  See the GNU
;; Lesser General Public License for more details.
;;
;; Version 2.1 of the GNU Lesser General Public License can be
;; found at http://opensource.franz.com/license.html.
;; If it is not present, you can access it from
;; http://www.gnu.org/copyleft/lesser.txt (until superseded by a newer
;; version) or write to the Free Software Foundation, Inc., 59 Temple
;; Place, Suite 330, Boston, MA  02111-1307  USA
;;
;; $Id: fhandle.cl,v 1.14 2005/04/05 03:11:36 dancy Exp $

;; file handle stuff


(in-package :user)

(eval-when (compile)
  (declaim (optimize (speed 3))))

;; Far too large for our needs.  
(defconstant *fhsize2* 32)
(defconstant *fhsizewords2* (/ *fhsize2* 4))
;; NFSv3 allows for a variable length file handle of up to 64 bytes.
;; We only use as much as needed to hold a fixnum (rounded to a 4 byte
;; boundary)
(defconstant *fhsize3* 
    (/ (floor (roundup (log (1+ most-positive-fixnum) 2) 32)) 8))
(defconstant *fhsizewords3* (/ *fhsize3* 4))

;; Maps file handle ids to file handles
(defparameter *fhandles* (make-hash-table))
;; Maps export paths to fhandles
(defparameter *export-roots* (make-hash-table :test #'equalp))

(defstruct fh
  pathname
  id
  export
  parent ;; nil if root
  children) ;; hash of basenames of directory children. values are fh's


(defun add-filename-to-dirname (dir filename)
  (if (char= (schar dir (1- (length dir))) #\\)
      (concatenate 'string dir filename)
    (concatenate 'string dir "\\" filename)))

;; File handle ids are chosen randomly to prevent
;; the search from taking linearly-increasing time.
;; caller should use without-interrupts.
(defun make-fhandle (dirfh filename &key root-export)
  (let ((id (random #.most-positive-fixnum)))
    (while (gethash id *fhandles*)
      (setf id (random #.most-positive-fixnum)))

    ;; special case for root of exports
    (if* root-export
       then
	    (make-fh :pathname filename
		     :id id
		     :export root-export)
       else
	    (make-fh :pathname (add-filename-to-dirname (fh-pathname dirfh)
							filename)
		     :id id
		     :export (fh-export dirfh)
		     :parent dirfh))))


;; Used by mountd
(defun get-export-fhandle (exp)
  ;; See if it has already been assigned.
  (let* ((path (nfs-export-path exp))
	 (fh (gethash path *export-roots*)))
    (if* fh
       then
	    fh
       else
	    ;; first use.
	    (setf fh (make-fhandle nil path :root-export exp))
	    (setf (gethash (fh-id fh) *fhandles*) fh)
	    (setf (gethash path *export-roots*) fh))))

(define-condition illegal-filename-error () ())

(defun sanity-check-filename (filename &key allow-dotnames)
  (if (or 
       ;; check 1
       (or (position #\\ filename)
	   (position #\/ filename)
	   (position #\: filename))
       ;; check 2
       (and (or (string= filename ".") (string= filename ".."))
	    (not allow-dotnames)) )
      (error 'illegal-filename-error 
	     :format-control "Illegal filename: ~S" 
	     :format-arguments (list filename))))

;; Put a fhandle into the hash.. and make sure the 
;; parent has a child entry.
(defun insert-fhandle (fh filename)
  (setf (gethash (fh-id fh) *fhandles*) fh)
  (let ((parent (fh-parent fh)))
    (if (null parent)
	(error "insert-fhandle: ~S has no parent" fh))
    ;; Create a fresh entry
    (if (not (fh-children parent))
	(setf (fh-children parent) (make-hash-table :test #'equalp)))
    (setf (gethash filename (fh-children parent)) fh)))
      


(defun lookup-fh-in-dir (dirfh filename &key create allow-dotnames)
  (block nil
    (without-interrupts 
      ;; will error out if filename is not acceptable.
      (sanity-check-filename filename :allow-dotnames allow-dotnames)
      ;; special cases:
      ;;  . is the same as dirfh 
      ;;  .. is the parent of dirfh
      ;; The allow-dotnames check was done in sanity-check-filename.. so
      ;; if we got this far, it's okay to have . or ..
      (if (string= filename ".")
	  (return dirfh))
      (if (string= filename "..")
	  (let ((parent (fh-parent dirfh)))
	    (return (if parent parent dirfh)))) ;; parent of root is root
      
      ;; See if an entry exists.
      (when (fh-children dirfh)
	(let ((fh (gethash filename (fh-children dirfh))))
	  (if fh
	      (return fh))))
      
      ;; no hash table or no entry
      (if (not create)
	  (return nil))
      
      ;; Create a fresh entry
      (insert-fhandle (make-fhandle dirfh filename) filename))))


(defun xdr-fhandle (xdr vers &optional fh)
  (declare ;;(optimize (speed 3) (safety 0))
	   (type fixnum vers))
  (check-type xdr xdr)
  (check-type vers number)
  (ecase (xdr-direction xdr)
    (:build
     (if (null fh)
	 (error "xdr-fhandle: 'fh' parameter is required when building"))
     (let ((value (fh-id fh))
	   words)
       (declare (type fixnum value words))
       (ecase vers
	 (2
	  (setf words *fhsizewords2*))
	 (3 
	  (setf words *fhsizewords3*)
	  (xdr-int xdr *fhsize3*)))
       (dotimes (i words)
	 (declare (type fixnum i))
	 (xdr-unsigned-int xdr (logand value #xffffffff))
	 (setf value (ash value -32)))))
        
    (:extract
     (let ((id 0)
	   (shift 0)
	   words)
       ;; Can't trust client not to fool with the file handle
       ;; so can't declare this.
       ;;(declare (type fixnum id))   
       (ecase vers
	 (2
	  (setf words *fhsizewords2*))
	 (3 
	  (setf words (/ (xdr-unsigned-int xdr) 4))
	  ;; sanity check.
	  (if (/= words *fhsizewords3*)
	      (error "xdr-fhandle: Invalid file handle size (~D words)" words))))
       (dotimes (i words)
	 (declare (type fixnum words shift i))
	 (setf id (logior id (ash (xdr-unsigned-int xdr) shift)))
	 (incf shift 32))
       (if (not (fixnump id))
	   (error "xdr-fhandle: Invalid id (non-fixnum) ~D" id))
       (without-interrupts
	 (gethash id *fhandles*))))))

;; To be used with file deletion (or deletion as a side effect
;; of renaming onto an existing file).
(defun remove-fhandle (fh filename)
  (without-interrupts
    (remhash (fh-id fh) *fhandles*)
    ;; remove entry from parent directory.
    (let ((parent (fh-parent fh)))
      (if (null parent)
	  (error "remove-fhandle: ~S has no parent" fh))
      (remhash filename (fh-children parent)))))

;; Caller is expected to remove todir/tofilename beforehand.
;; Updates the pathname slot of the fhandle.
(defun rename-fhandle (fh fromfilename todir tofilename)
  (without-interrupts
    ;; remove from current parent.
    (let ((parent (fh-parent fh)))
      (if (null parent)
	  (error "rename-fhandle: ~S has no parent" fh))
      (remhash fromfilename (fh-children parent)))
    ;; update parent
    (setf (fh-parent fh) todir)
    ;; add to destination parent.
    (insert-fhandle fh tofilename)
    ;; change pathname
    (setf (fh-pathname fh) 
      (add-filename-to-dirname (fh-pathname todir) tofilename))))

;; If body runs to completion, the filehandle will be saved,
;; otherwise, it will be removed.
(defmacro with-potential-fhandle ((fhvar dirfh filename &key allow-dotnames) 
				  &body body)
  (let ((successvar (gensym))
	(dirfhvar (gensym))
	(filenamevar (gensym))
	(allow-dotnamesvar (gensym)))
    `(let* ((,dirfhvar ,dirfh)
	    (,filenamevar ,filename)
	    (,allow-dotnamesvar ,allow-dotnames)
	    (,fhvar (lookup-fh-in-dir ,dirfhvar ,filenamevar :create t 
				      :allow-dotnames ,allow-dotnamesvar))
	    (,successvar nil))
       (unwind-protect 
	   (multiple-value-prog1 (progn ,@body) (setf ,successvar t))
	 (when (not ,successvar)
	   (remove-fhandle ,fhvar ,filenamevar))))))

(defun invalidate-fhandles (fh)
  (remhash (fh-id fh) *fhandles*)
  (let ((children (fh-children fh)))
    (when children
      (maphash #'(lambda (key value) 
		   (declare (ignore key))
		   (invalidate-fhandles value))
	       children))))

(defun invalidate-export-fhandles (exp)
  (let ((fh (get-export-fhandle exp)))
    (invalidate-fhandles fh)
    (remhash (nfs-export-path exp) *export-roots*)))
