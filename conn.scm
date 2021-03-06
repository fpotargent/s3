;;;; Lysiane Bouchard - Vincent St-Amour
;;;; conn.scm

;; TODO what really is in there
;;;  - connection structure and related operations
;;;  - operations on the current connection
;;;  - external operations on a connection

;;; Note : connections are used only with tcp
;; TODO merge all this with tcp ? it's only used with tcp. would result in a huge file, though

;; connection structures are represented as vectors :
;; FORMAT: 6 fields:
;; -0: informations (u8vector)
;;     contains:
;;     - which of the stack's IP addresses uses the connection
;;     - peer's IP address
;;     - peer's source port number
;;     - peer's MAC address
;;     - whether the connection is active or not
;;     - the acknoledgement number at which the stack is for this connection
;;     - number of self-ack units TODO what's that ?
;;     - the acknoledgement number at which our peer is
;;     - number of attemps so far TODO make sure it's so far
;;     Note : storing our port number in the connection structure is unecessary
;; -1: timestamp (integer) TODO which unit ?
;; -2: input buffer (u8vector)
;; -3: output buffer (u8vector)
;; -4: state function (function)
;;     defines the connection's behaviour at a given time.
(define conn-info           0)
(define conn-timestamp      1)
(define conn-input          2)
(define conn-output         3)
(define conn-state-function 4)

;; informations
(define conn-self-ip       0)
(define conn-peer-ip       4) ;; TODO see if it's necessary or if a simple swap can do the job
(define conn-peer-portnum  8) ;; TODO same here
(define conn-peer-mac      10) ;; TODO same here
(define conn-active?       16) ; boolean ;: TODO find a way to do without
(define tcp-self-seqnum    17)
(define tcp-self-ack-units 21) ;; TODO what's that ?
(define tcp-peer-seqnum    22) ;; TODO add conn- before ?
(define tcp-attempts-count 26)
(define tcp-infos-size     27)


;; general operations
;; TODO have conn-ref and offsets, just like pkt, so we save the getters / setters
(define (conn-info-ref conn i) (u8vector-ref (vector-ref conn conn-info) i)) ;; TODO get rid ?
(define (conn-info-set! conn i val) (u8vector-set! (vector-ref conn conn-info) i val))
(define (set-timestamp!) (vector-set! curr-conn conn-timestamp (get-current-time))) ;; TODO add curr to name ?
(define (get-curr-elapsed-time) (get-elapsed-time (vector-ref curr-conn conn-timestamp)))

(define (=conn-info-pkt? pkt-idx c c-idx n)
  (u8vector-equal-field? pkt pkt-idx (vector-ref c conn-info) c-idx n))


;; creates a new connection with the info in the incoming packet
;; it becomes the current connection
(define (new-conn) ;; TODO used only once
  ;; TODO clean this up a bit, are some operations redundant ? are all necessary ?
  (set! curr-conn (vector (make-u8vector tcp-infos-size 0)
			  #f
			  (vector 0 0 (make-u8vector tcp-input-size 0))
			  (vector 0 0 (make-u8vector tcp-output-size 0))
			  tcp-syn-recv))
  (add-conn-to-curr-port curr-conn) ;; TODO is it always the curr-conn ? if so, simplify
  (copy-pkt->curr-conn-info ip-destination-ip conn-self-ip 4) ;; TODO useful ?
  (copy-pkt->curr-conn-info tcp-source-portnum conn-peer-portnum 2)
  (copy-pkt->curr-conn-info ip-source-ip conn-peer-ip 4) ;; TODO why these 2 ? we can probably just swap when we create the response, no ?
  (copy-pkt->curr-conn-info ethernet-source-mac conn-peer-mac 6) ;; TODO do we need this ? we can simply answer to the sender
  (set-timestamp!)
  (u8vector-copy! (tcp-isn) 0 pkt tcp-self-seqnum 4)
  (copy-pkt->curr-conn-info tcp-seqnum tcp-peer-seqnum 4))


;; an input/output buffers is represented as a vector
;; -0: amount of bytes stored in the buffer (integer)
;; -1: pointer to the next free space in the buffer (integer)
;; -2: the buffer itself (u8vector)
;;     the length is found in conf.scm and can be different for input and
;;     output buffers, with a maximum of 256 bytes
;; TODO this is all broken, we'd need 2 pointers.
;;  for output buffer, one to show where to add the next data, and another to show the 1st unsent (or not acked)
;; for input, one for the stack to see where it can add, and the other that shows where the app reads
;; FIX THIS NOTHING CAN WORK WITHOUT (perhaps it does by subtrating amount, but it's disgusting)
;; TODO for efficiency reasons, maybe keep the free space along with the amount, so we don't calculate it every time

(define (buf-size buf) (u8vector-length (vector-ref 2 buf)))
;; TODO would be faster to look at the conf for a user, we can't since we don't know if it's an input or output buffer, maybe store a flag for this ? would not really be faster than getting the length, since picobit stores it with the vector
;; TODO maybe we can see which of the connection buffers is used

(define (curr-buf-get-amount) (vector-ref (vector-ref curr-conn conn-output) 0))
;; TODO change name so we see it's for an output buffer
;; TODO only used once, and in a debatable way
(define (buf-inc-amount buf n) (vector-set! buf 0 (+ (vector-ref buf 0) n)))
;; TODO not really inc/dec since it's not 1 but n
(define (buf-dec-amount buf n) (vector-set! buf 0 (- (vector-ref buf 0) n)))
(define (buf-inc-pointer buf n)
  (vector-set! buf 1 (modulo (+ (vector-ref buf 1) n) (buf-size buf))))

(define (buf-free-space buf) (- (buf-size buf) (vector-ref buf 0)))
;; TODO this might be used for redundant checks, if so, fix

;; consumes n bytes of data from the buffer, so it can be overwritten
(define (buf-consume buf n) ;; TODO name ? and used only once, maybe will be more in the future
  (if (>= n (vector-ref buf 0))
      (begin (vector-set! buf 0 0) ; set amount and pointer to 0
             (vector-set! buf 1 0))
      (begin (buf-dec-amount buf n)
             (buf-inc-pointer buf n))))

;; TODO move with other info functions
(define (copy-pkt->curr-conn-info pkt-idx conn-idx n) ;; TODO standardise name
  (u8vector-copy! pkt pkt-idx (vector-ref curr-conn conn-info) conn-idx n))
(define (copy-curr-conn-info->pkt pkt-idx conn-idx n) ;; TODO standardise name
  (u8vector-copy! (vector-ref curr-conn conn-info) conn-idx pkt pkt-idx n))


;; TODO we're still doomed if offset if more than 24 bits
;; add offset to the field of n bytes that begins at idx
;; TODO is this used often enough to be worth it ?
;; TODO not really an increment
(define (increment-curr-conn-info! idx n offset)
  (u8vector-increment! (vector-ref curr-conn conn-info) idx n offset))

;; Links the current connection with the corresponding application
;; sends the connection to the application, which can then access it at
;; any time
(define (link-to-app) ((conf-ref curr-port conf-reception) curr-conn)) ;; TODO used only once, in tcp INLINE


;; detach the current connection from the current port
(define (detach-curr-conn) ;; TODO put with ports ?
  (detach-curr-conn-loop curr-port))
(define (detach-curr-conn-loop lst) ;; TODO have a ! in the name
  (if (pair? (cdr lst)) ;; TODO have an accessor for conf and conns ? but this is not really a conn
      (if (eq? (cadr lst) curr-conn)
	  (set-cdr! lst (cddr lst))
	  (detach-curr-conn-loop (cdr lst)))))


;; copy n bytes from a circular buffer to a byte vector
;; this consumes the data from the buffer, it cannot be read again
;; we are guaranteed that n cannot be greater than the number of bytes that can
;; actually be read
(define (copy-buffer->u8vector! buf vec i-vec n)
  ;; the copy starts at the current location in the buffer
  (let ((i-buf (vector-ref buf 1))
	(size (buf-size buf))
	(buf-data (vector-ref buf 2)))
    (if (<= (+ i-buf n) size) ; wraparound
	(let ((n1 (- size i-buf 1)))
	  (u8vector-copy! buf-data i-buf vec i-vec n1)
	  (u8vector-copy! buf-data 0 vec (+ i-vec n1) (- n n1)))
	(u8vector-copy! buf-data i-buf vec i-vec n))
    (buf-inc-pointer buf n)))
;; TODO put with other buffer functions

;; TODO does this obsolete other functions ?
;; copy n bytes of data from a vector to a circular buffer
;; once again, we are guaranteed that the copy is valid, that the buffer has
;; enough room for the new data
;; TODO a lot in common with the previous, find a way to merge ?
;; returns the offset of the next empty space in the buffer. TODO really ?
;; if the buffer is full, returns #f
(define (copy-u8vector->buffer! vec i-vec buf n)
  (let ((i-buf (vector-ref buf 1))
	(size (buf-size buf))
	(buf-data (vector-ref buf 2)))
    (if (<= (+ i-buf n) size) ; wraparound
	(let ((n1 (- size i-buf 1))) ;; TODO off-by-one ?
	  (u8vector-copy! vec i-vec buf-data i-buf n1)
	  (u8vector-copy! vec (+ i-vec n1) buf-data 0 (- n n1)))
	(u8vector-copy! vec i-vec buf i-buf n))
    (buf-inc-amount buf n)))



;;; TCP API

;; read n input bytes from the connection c, if n is omitted, read all
;; TODO the changes were not tested
(define (tcp-read c . n) ;; TODO quite ugly
  (set! curr-conn c)
  ;; TODO visit the connection ? maybe not needed, we have received data, and there is nothing to de really
  (let* ((buf (vector-ref c conn-input))
	 (available (vector-ref buf 0)) ; amount of data in the buffer
	 (amount (if (null? n)
		     available
		     (min available (car n)))))
    (cond ((> amount 0)
	   (let ((data (make-u8vector amount 0)) (i 0))
	     (copy-buffer->u8vector! buf data 0 amount)
	     data)) ; TODO change one of the 2 pointers
	  ((not (conn-info-ref c conn-active?)) 'end-of-input)
	  (else #f))))

;; write bytes (in a u8vector) to c, returns the number of bytes written
(define (tcp-write c data)
  (set! curr-conn c)
  (if (conn-info-ref c conn-active?)
      (let* ((buf (vector-ref c conn-output))
	     (amount (min (buf-free-space buf) (u8vector-length data))))
	(if (> amount 0)
	    (begin ;; TODO change one of the 2 pointers, once we have them
	      (copy-u8vector->buffer! data 0 buf amount)
	      amount)
	    #f))
      'connection-closed)) ; error, we try to write to a closed connection 
;; TODO after that, visit the connection


;; API function to terminate a connection
(define (tcp-close conn . abort?)
  (set! curr-conn conn)
  (conn-info-set! conn conn-active? #f)
  (if abort? (tcp-abort) (detach-curr-conn)))
