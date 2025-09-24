;; Youth DAO Core Contract
;; Handles governance, membership management, and proposal lifecycle for the Youth Employment DAO

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_NOT_FOUND (err u101))
(define-constant ERR_ALREADY_EXISTS (err u102))
(define-constant ERR_INVALID_AMOUNT (err u103))
(define-constant ERR_PROPOSAL_CLOSED (err u104))
(define-constant ERR_ALREADY_VOTED (err u105))
(define-constant ERR_INSUFFICIENT_VOTES (err u106))
(define-constant MIN_PROPOSAL_DURATION u1008) ;; ~1 week in blocks
(define-constant VOTING_THRESHOLD u100) ;; 100 STX minimum to vote
(define-constant QUORUM_PERCENTAGE u20) ;; 20% quorum required

;; Data Variables
(define-data-var total-members uint u0)
(define-data-var proposal-counter uint u0)
(define-data-var treasury-balance uint u0)
(define-data-var governance-token-supply uint u1000000) ;; 1M initial governance tokens

;; Data Maps
(define-map members principal {
    member-since: uint,
    voting-power: uint,
    proposals-created: uint,
    total-votes-cast: uint,
    is-active: bool
})

(define-map proposals uint {
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    funding-amount: uint,
    recipient: principal,
    votes-for: uint,
    votes-against: uint,
    start-block: uint,
    end-block: uint,
    executed: bool,
    proposal-type: (string-ascii 20) ;; "funding", "governance", "membership"
})

(define-map member-votes {proposal-id: uint, voter: principal} {
    vote-cast: bool,
    vote-for: bool,
    voting-power-used: uint
})

(define-map governance-tokens principal uint)

;; Public Functions

;; Register as a DAO member
(define-public (register-member)
    (let ((current-member (map-get? members tx-sender)))
        (if (is-some current-member)
            ERR_ALREADY_EXISTS
            (begin
                (map-set members tx-sender {
                    member-since: stacks-block-height,
                    voting-power: u100, ;; Initial voting power
                    proposals-created: u0,
                    total-votes-cast: u0,
                    is-active: true
                })
                (map-set governance-tokens tx-sender u1000) ;; Initial governance tokens
                (var-set total-members (+ (var-get total-members) u1))
                (ok true)
            )
        )
    )
)

;; Create a new proposal
(define-public (create-proposal (title (string-ascii 100)) (description (string-ascii 500)) 
                               (funding-amount uint) (recipient principal) (proposal-type (string-ascii 20)))
    (let ((member-data (unwrap! (map-get? members tx-sender) ERR_UNAUTHORIZED))
          (proposal-id (+ (var-get proposal-counter) u1)))
        (if (get is-active member-data)
            (begin
                (map-set proposals proposal-id {
                    proposer: tx-sender,
                    title: title,
                    description: description,
                    funding-amount: funding-amount,
                    recipient: recipient,
                    votes-for: u0,
                    votes-against: u0,
                    start-block: stacks-block-height,
                    end-block: (+ stacks-block-height MIN_PROPOSAL_DURATION),
                    executed: false,
                    proposal-type: proposal-type
                })
                (map-set members tx-sender 
                    (merge member-data {proposals-created: (+ (get proposals-created member-data) u1)})
                )
                (var-set proposal-counter proposal-id)
                (ok proposal-id)
            )
            ERR_UNAUTHORIZED
        )
    )
)

;; Vote on a proposal
(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
    (let ((proposal-data (unwrap! (map-get? proposals proposal-id) ERR_NOT_FOUND))
          (member-data (unwrap! (map-get? members tx-sender) ERR_UNAUTHORIZED))
          (existing-vote (map-get? member-votes {proposal-id: proposal-id, voter: tx-sender}))
          (voting-power (get voting-power member-data)))
        (if (and (is-none existing-vote)
                 (get is-active member-data)
                 (<= stacks-block-height (get end-block proposal-data))
                 (>= voting-power VOTING_THRESHOLD))
            (begin
                (map-set member-votes {proposal-id: proposal-id, voter: tx-sender} {
                    vote-cast: true,
                    vote-for: vote-for,
                    voting-power-used: voting-power
                })
                (map-set proposals proposal-id
                    (if vote-for
                        (merge proposal-data {votes-for: (+ (get votes-for proposal-data) voting-power)})
                        (merge proposal-data {votes-against: (+ (get votes-against proposal-data) voting-power)})
                    )
                )
                (map-set members tx-sender
                    (merge member-data {total-votes-cast: (+ (get total-votes-cast member-data) u1)})
                )
                (ok true)
            )
            (if (is-some existing-vote) ERR_ALREADY_VOTED ERR_UNAUTHORIZED)
        )
    )
)

;; Execute a successful proposal
(define-public (execute-proposal (proposal-id uint))
    (let ((proposal-data (unwrap! (map-get? proposals proposal-id) ERR_NOT_FOUND))
          (total-votes (+ (get votes-for proposal-data) (get votes-against proposal-data)))
          (required-quorum (/ (* (var-get total-members) QUORUM_PERCENTAGE) u100)))
        (if (and (> stacks-block-height (get end-block proposal-data))
                 (not (get executed proposal-data))
                 (> (get votes-for proposal-data) (get votes-against proposal-data))
                 (>= total-votes required-quorum))
            (begin
                (map-set proposals proposal-id
                    (merge proposal-data {executed: true})
                )
                ;; Execute based on proposal type
                (if (is-eq (get proposal-type proposal-data) "funding")
                    (transfer-from-treasury (get funding-amount proposal-data) (get recipient proposal-data))
                    (ok true)
                )
            )
            ERR_INSUFFICIENT_VOTES
        )
    )
)

;; Deposit STX to treasury
(define-public (deposit-to-treasury (amount uint))
    (if (> amount u0)
        (begin
            (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
            (var-set treasury-balance (+ (var-get treasury-balance) amount))
            (ok true)
        )
        ERR_INVALID_AMOUNT
    )
)

;; Read Only Functions

(define-read-only (get-member-info (member principal))
    (map-get? members member)
)

(define-read-only (get-proposal-info (proposal-id uint))
    (map-get? proposals proposal-id)
)

(define-read-only (get-vote-info (proposal-id uint) (voter principal))
    (map-get? member-votes {proposal-id: proposal-id, voter: voter})
)

(define-read-only (get-total-members)
    (var-get total-members)
)

(define-read-only (get-proposal-count)
    (var-get proposal-counter)
)

(define-read-only (get-treasury-balance)
    (var-get treasury-balance)
)

(define-read-only (get-governance-tokens (holder principal))
    (default-to u0 (map-get? governance-tokens holder))
)

;; Private Functions

(define-private (transfer-from-treasury (amount uint) (recipient principal))
    (if (<= amount (var-get treasury-balance))
        (begin
            (try! (as-contract (stx-transfer? amount tx-sender recipient)))
            (var-set treasury-balance (- (var-get treasury-balance) amount))
            (ok true)
        )
        ERR_INVALID_AMOUNT
    )
)

