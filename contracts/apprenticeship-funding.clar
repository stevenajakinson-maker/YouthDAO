;; Apprenticeship Funding Contract
;; Manages apprenticeship programs, milestone-based payments, and mentor rewards

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_NOT_FOUND (err u201))
(define-constant ERR_ALREADY_EXISTS (err u202))
(define-constant ERR_INVALID_AMOUNT (err u203))
(define-constant ERR_PROGRAM_INACTIVE (err u204))
(define-constant ERR_MILESTONE_COMPLETED (err u205))
(define-constant ERR_INSUFFICIENT_FUNDS (err u206))
(define-constant ERR_INVALID_MILESTONE (err u207))
(define-constant MIN_PROGRAM_DURATION u4320) ;; ~30 days in blocks
(define-constant MAX_MILESTONES u10) ;; Maximum milestones per program
(define-constant MENTOR_REWARD_PERCENTAGE u15) ;; 15% of milestone payment to mentor

;; Data Variables
(define-data-var program-counter uint u0)
(define-data-var total-apprentices uint u0)
(define-data-var total-mentors uint u0)
(define-data-var total-funded-amount uint u0)

;; Data Maps
(define-map apprenticeship-programs uint {
    program-name: (string-ascii 100),
    description: (string-ascii 500),
    apprentice: principal,
    mentor: principal,
    total-funding: uint,
    funding-released: uint,
    milestones-total: uint,
    milestones-completed: uint,
    start-block: uint,
    end-block: uint,
    is-active: bool,
    created-by: principal
})

(define-map program-milestones {program-id: uint, milestone-id: uint} {
    title: (string-ascii 100),
    description: (string-ascii 300),
    funding-amount: uint,
    due-block: uint,
    completed: bool,
    completed-block: uint,
    verified-by: (optional principal),
    apprentice-submission: (optional (string-ascii 500))
})

(define-map apprentice-profiles principal {
    name: (string-ascii 50),
    skills: (string-ascii 200),
    programs-completed: uint,
    total-earned: uint,
    reputation-score: uint,
    is-active: bool,
    joined-block: uint
})

(define-map mentor-profiles principal {
    name: (string-ascii 50),
    expertise: (string-ascii 200),
    programs-mentored: uint,
    total-earned: uint,
    reputation-score: uint,
    is-active: bool,
    joined-block: uint
})

(define-map program-funding-pool uint uint) ;; program-id -> available funding

;; Public Functions

;; Register as an apprentice
(define-public (register-apprentice (name (string-ascii 50)) (skills (string-ascii 200)))
    (let ((existing-profile (map-get? apprentice-profiles tx-sender)))
        (if (is-some existing-profile)
            ERR_ALREADY_EXISTS
            (begin
                (map-set apprentice-profiles tx-sender {
                    name: name,
                    skills: skills,
                    programs-completed: u0,
                    total-earned: u0,
                    reputation-score: u100, ;; Starting reputation
                    is-active: true,
                    joined-block: stacks-block-height
                })
                (var-set total-apprentices (+ (var-get total-apprentices) u1))
                (ok true)
            )
        )
    )
)

;; Register as a mentor
(define-public (register-mentor (name (string-ascii 50)) (expertise (string-ascii 200)))
    (let ((existing-profile (map-get? mentor-profiles tx-sender)))
        (if (is-some existing-profile)
            ERR_ALREADY_EXISTS
            (begin
                (map-set mentor-profiles tx-sender {
                    name: name,
                    expertise: expertise,
                    programs-mentored: u0,
                    total-earned: u0,
                    reputation-score: u100, ;; Starting reputation
                    is-active: true,
                    joined-block: stacks-block-height
                })
                (var-set total-mentors (+ (var-get total-mentors) u1))
                (ok true)
            )
        )
    )
)

;; Create a new apprenticeship program
(define-public (create-program (program-name (string-ascii 100)) (description (string-ascii 500))
                              (apprentice principal) (mentor principal) (total-funding uint)
                              (duration-blocks uint))
    (let ((program-id (+ (var-get program-counter) u1))
          (apprentice-profile (unwrap! (map-get? apprentice-profiles apprentice) ERR_NOT_FOUND))
          (mentor-profile (unwrap! (map-get? mentor-profiles mentor) ERR_NOT_FOUND)))
        (if (and (get is-active apprentice-profile)
                 (get is-active mentor-profile)
                 (> total-funding u0)
                 (>= duration-blocks MIN_PROGRAM_DURATION))
            (begin
                (map-set apprenticeship-programs program-id {
                    program-name: program-name,
                    description: description,
                    apprentice: apprentice,
                    mentor: mentor,
                    total-funding: total-funding,
                    funding-released: u0,
                    milestones-total: u0,
                    milestones-completed: u0,
                    start-block: stacks-block-height,
                    end-block: (+ stacks-block-height duration-blocks),
                    is-active: true,
                    created-by: tx-sender
                })
                (map-set program-funding-pool program-id u0)
                (var-set program-counter program-id)
                (ok program-id)
            )
            ERR_INVALID_AMOUNT
        )
    )
)

;; Add a milestone to a program
(define-public (add-milestone (program-id uint) (title (string-ascii 100))
                             (description (string-ascii 300)) (funding-amount uint)
                             (due-blocks-from-now uint))
    (let ((program-data (unwrap! (map-get? apprenticeship-programs program-id) ERR_NOT_FOUND))
          (milestone-id (+ (get milestones-total program-data) u1)))
        (if (and (get is-active program-data)
                 (< (get milestones-total program-data) MAX_MILESTONES)
                 (> funding-amount u0))
            (begin
                (map-set program-milestones {program-id: program-id, milestone-id: milestone-id} {
                    title: title,
                    description: description,
                    funding-amount: funding-amount,
                    due-block: (+ stacks-block-height due-blocks-from-now),
                    completed: false,
                    completed-block: u0,
                    verified-by: none,
                    apprentice-submission: none
                })
                (map-set apprenticeship-programs program-id
                    (merge program-data {milestones-total: milestone-id})
                )
                (ok milestone-id)
            )
            ERR_PROGRAM_INACTIVE
        )
    )
)

;; Fund a program
(define-public (fund-program (program-id uint) (amount uint))
    (let ((program-data (unwrap! (map-get? apprenticeship-programs program-id) ERR_NOT_FOUND))
          (current-pool (default-to u0 (map-get? program-funding-pool program-id))))
        (if (and (get is-active program-data) (> amount u0))
            (begin
                (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
                (map-set program-funding-pool program-id (+ current-pool amount))
                (var-set total-funded-amount (+ (var-get total-funded-amount) amount))
                (ok true)
            )
            ERR_INVALID_AMOUNT
        )
    )
)

;; Submit milestone completion (apprentice only)
(define-public (submit-milestone (program-id uint) (milestone-id uint) (submission (string-ascii 500)))
    (let ((program-data (unwrap! (map-get? apprenticeship-programs program-id) ERR_NOT_FOUND))
          (milestone-data (unwrap! (map-get? program-milestones {program-id: program-id, milestone-id: milestone-id}) ERR_NOT_FOUND)))
        (if (and (is-eq tx-sender (get apprentice program-data))
                 (get is-active program-data)
                 (not (get completed milestone-data)))
            (begin
                (map-set program-milestones {program-id: program-id, milestone-id: milestone-id}
                    (merge milestone-data {apprentice-submission: (some submission)})
                )
                (ok true)
            )
            ERR_UNAUTHORIZED
        )
    )
)

;; Verify and complete milestone (mentor only)
(define-public (complete-milestone (program-id uint) (milestone-id uint))
    (let ((program-data (unwrap! (map-get? apprenticeship-programs program-id) ERR_NOT_FOUND))
          (milestone-data (unwrap! (map-get? program-milestones {program-id: program-id, milestone-id: milestone-id}) ERR_NOT_FOUND))
          (available-funding (default-to u0 (map-get? program-funding-pool program-id))))
        (if (and (is-eq tx-sender (get mentor program-data))
                 (get is-active program-data)
                 (not (get completed milestone-data))
                 (is-some (get apprentice-submission milestone-data))
                 (>= available-funding (get funding-amount milestone-data)))
            (begin
                ;; Mark milestone as completed
                (map-set program-milestones {program-id: program-id, milestone-id: milestone-id}
                    (merge milestone-data {
                        completed: true,
                        completed-block: stacks-block-height,
                        verified-by: (some tx-sender)
                    })
                )
                ;; Update program data
                (map-set apprenticeship-programs program-id
                    (merge program-data {
                        milestones-completed: (+ (get milestones-completed program-data) u1),
                        funding-released: (+ (get funding-released program-data) (get funding-amount milestone-data))
                    })
                )
                ;; Release payments
                (try! (release-milestone-payment program-id milestone-id))
                (ok true)
            )
            ERR_UNAUTHORIZED
        )
    )
)

;; Read Only Functions

(define-read-only (get-program-info (program-id uint))
    (map-get? apprenticeship-programs program-id)
)

(define-read-only (get-milestone-info (program-id uint) (milestone-id uint))
    (map-get? program-milestones {program-id: program-id, milestone-id: milestone-id})
)

(define-read-only (get-apprentice-profile (apprentice principal))
    (map-get? apprentice-profiles apprentice)
)

(define-read-only (get-mentor-profile (mentor principal))
    (map-get? mentor-profiles mentor)
)

(define-read-only (get-program-funding (program-id uint))
    (default-to u0 (map-get? program-funding-pool program-id))
)

(define-read-only (get-total-programs)
    (var-get program-counter)
)

(define-read-only (get-total-apprentices)
    (var-get total-apprentices)
)

(define-read-only (get-total-mentors)
    (var-get total-mentors)
)

(define-read-only (get-total-funded)
    (var-get total-funded-amount)
)

;; Private Functions

(define-private (release-milestone-payment (program-id uint) (milestone-id uint))
    (let ((program-data (unwrap! (map-get? apprenticeship-programs program-id) ERR_NOT_FOUND))
          (milestone-data (unwrap! (map-get? program-milestones {program-id: program-id, milestone-id: milestone-id}) ERR_NOT_FOUND))
          (payment-amount (get funding-amount milestone-data))
          (mentor-reward (/ (* payment-amount MENTOR_REWARD_PERCENTAGE) u100))
          (apprentice-payment (- payment-amount mentor-reward))
          (current-pool (default-to u0 (map-get? program-funding-pool program-id))))
        (if (>= current-pool payment-amount)
            (begin
                ;; Pay apprentice
                (try! (as-contract (stx-transfer? apprentice-payment tx-sender (get apprentice program-data))))
                ;; Pay mentor
                (try! (as-contract (stx-transfer? mentor-reward tx-sender (get mentor program-data))))
                ;; Update funding pool
                (map-set program-funding-pool program-id (- current-pool payment-amount))
                ;; Update profiles
                (try! (update-apprentice-earnings (get apprentice program-data) apprentice-payment))
                (try! (update-mentor-earnings (get mentor program-data) mentor-reward))
                (ok true)
            )
            ERR_INSUFFICIENT_FUNDS
        )
    )
)

(define-private (update-apprentice-earnings (apprentice principal) (amount uint))
    (let ((profile (unwrap! (map-get? apprentice-profiles apprentice) ERR_NOT_FOUND)))
        (map-set apprentice-profiles apprentice
            (merge profile {
                total-earned: (+ (get total-earned profile) amount),
                reputation-score: (+ (get reputation-score profile) u10) ;; Increase reputation
            })
        )
        (ok true)
    )
)

(define-private (update-mentor-earnings (mentor principal) (amount uint))
    (let ((profile (unwrap! (map-get? mentor-profiles mentor) ERR_NOT_FOUND)))
        (map-set mentor-profiles mentor
            (merge profile {
                total-earned: (+ (get total-earned profile) amount),
                reputation-score: (+ (get reputation-score profile) u10) ;; Increase reputation
            })
        )
        (ok true)
    )
)

