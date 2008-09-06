;;;; Lysiane Bouchard - Vincent St-Amour
;;;; icmp.scm

;; ICMP constants
(define icmp-ip-header-bad '#u8(12 0))
(define icmp-port-unreachable '#u8(3 3))
(define icmp-protocol-unreachable '#u8(3 2))
(define icmp-time-exceeded '#u8(11 0))
(define icmp-parameter-problem  '#u8(12 0))
(define icmp-echo-request '#u8(8 0))
(define icmp-echo-reply '#u8(0 0))
(define icmp-address-mask-request '#u8(17 0))
(define icmp-address-mask-reply '#u8(18 0))
(define icmp-host-precedence-violation '#u8(3 14))

(define icmp-hdr-len 8) ;; TODO do the same for other protocols ?


;; called when an icmp datagram is received
(define (icmp-pkt-in) ;; TODO we do have a pattern for protocols, do some checks, then dispatch to an upper level function. the generic reception functions were a pita, maybe try a macro ?
  (if (valid-checksum? (compute-icmp-checksum))
      (let ((op (u8vector-ref-field pkt icmp-type 2)))
        (cond ((equal? op icmp-echo-request) ;; TODO do comparison with numbers and define op with a pkt-ref-2, then compare with =, or use equal-case like eth
               (icmp-send-echo-reply))
              ((equal? op icmp-address-mask-request)
               (icmp-send-address-mask-reply))
              (else #f))))) ;; TODO remove ?
;; TODO maybe have some better error handling
;; TODO do we accept any other requests ?
;; TODO send error cases to applications, as special tokens when they do the next operation

(define (compute-icmp-checksum)
  (pkt-checksum icmp-header
                (+ ip-header (pkt-ref-2 ip-length)) ;; TODO known statically ? no options
                0))


;; ICMP SUPPORTED OPERATIONS

(define (icmp-send-address-mask-reply)
  (u8vector-copy! my-address-mask 0 pkt icmp-data 4)
  (icmp-encapsulation icmp-address-mask-reply 4))

(define (icmp-send-echo-reply)
  (icmp-encapsulation icmp-echo-reply (- (pkt-ref-2 ip-length)
                                         (get-ip-hdr-len)
                                         icmp-hdr-len)))
;; TODO if we have a pkt-len var, we wouldn't have to calculate the length like this, it would simply remain unchanged

(define (icmp-send-ip-header-bad-error) ; TODO wasn't checked, and I can't see it in the rfc
  (copy-ip-hdr)
  (icmp-encapsulation icmp-ip-header-bad 20))

(define (icmp-send-protocol-unreachable-error)
  (icmp-unreachable icmp-protocol-unreachable))
(define (icmp-send-port-unreachable-error)
  (icmp-unreachable icmp-port-unreachable))
(define (icmp-send-time-exceed-error)
  (icmp-unreachable icmp-time-exceeded)) ;; TODO test it
;; TODO implement the other unreachables from the rfc ?

;; sets up the packet in case of "unreachable" error, or for a time-exceeded,
;; since it has the same structure
(define (icmp-unreachable type)
  ;; copy IP headers first 20 bytes, and first 8 bytes of data
  (u8vector-copy! pkt udp-header pkt (+ icmp-data 20) 8)
  (copy-ip-hdr)
  (integer->pkt 0 icmp-options 4) ; set the 4 optional bytes to 0
  (icmp-encapsulation type (+ 20 8)))

;; we don't copy the options, just the 20 first bytes
(define (copy-ip-hdr) (u8vector-copy! pkt ip-header pkt icmp-data 20)) ;; TODO can this replace something else in here ?


;; TODO clean this up, should end up calling ip-encapsulation, which sould in turn call eth-encapsulation
;; data-amount is excluding icmp header
(define (icmp-encapsulation key data-amount)
  (u8vector-copy! key 0 pkt icmp-type 2)
  (integer->pkt 0 icmp-checksum 2)
  (integer->pkt (reverse-checksum (compute-icmp-checksum) 2) ; TODO do we always have to reverse when we send ? if so, why not make it the deafult ? then we could make validchecksum check if it's 0, no ?
		  icmp-checksum) ; TODO is ICMP checksum correctly calculated ? we use the old IP info, maybe we should use the new ? it uses the old IP-length to calculate the end of the message, I doubt this is correct
  (u8vector-copy! pkt ip-src-IP pkt ip-dst-IP 4) ;; TODO abstract that
  (u8vector-copy! my-IP 0 pkt ip-src-IP 4)
  (integer->pkt 0 ip-checksum 2)
  (u8vector-set! pkt ip-protocol ip-protocol-ICMP) ;; TODO unlike other protocols, this change is necessary, since ICMP packets can be sent in response to other protocols
  (u8vector-set! pkt ip-ttl 255) ;; TODO should be done in IP
  (u8vector-set! pkt ip-service 0) ; TODO fields are not set in order, reason ?
  (set-ip-frag) ;; TODO use ip encapsulation ? then we can inline this function
  (integer->pkt (ip-identification) ip-ident 2) ;; TODO shouldn't this part be done at the ip level ? then we could have ip-identification in ip and used only once ? TODO is it 2 ? I think so, but make sure
  (integer->pkt (+ (get-ip-hdr-len) data-amount icmp-hdr-len) ip-length 2)
  (integer->pkt (reverse-checksum (compute-ip-checksum)) ip-checksum 2)
  (ethernet-encapsulation (pkt-ref-2 ip-length)))
