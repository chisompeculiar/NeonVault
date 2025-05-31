;; NeonVault: Next-Generation Bitcoin-Backed Lending Protocol
;; A cutting-edge decentralized lending platform for Bitcoin collateralized loans

;; System Constants
(define-constant PROTOCOL-ADMIN tx-sender)
(define-constant VAULT-INSUFFICIENT-BALANCE (err u200))
(define-constant VAULT-ACCESS-DENIED (err u201))
(define-constant VAULT-NOT-FOUND (err u202))
(define-constant VAULT-ALREADY-ACTIVE (err u203))
(define-constant VAULT-PAYMENT-FAILURE (err u204))
(define-constant VAULT-LIQUIDATION-BLOCKED (err u205))
(define-constant VAULT-INVALID-INPUT (err u206))
(define-constant VAULT-UNDERCOLLATERALIZED (err u207))
(define-constant VAULT-TRANSFER-ERROR (err u208))

;; Protocol Limits
(define-constant MAX-APR-BASIS-POINTS u10000) ;; 100.00% maximum APR
(define-constant MAX-VAULT-DURATION u52560) ;; ~1 year in blocks
(define-constant SYSTEM-MAX-UINT u340282366920938463463374607431768211455)
(define-constant MIN-COLLATERAL-RATIO u150) ;; 150% minimum collateralization
(define-constant LIQUIDATION-THRESHOLD u120) ;; 120% liquidation threshold

;; Core Data Structures
(define-map active-vaults 
  {
    vault-id: uint,
    vault-owner: principal
  }
  {
    btc-collateral: uint,
    borrowed-amount: uint,
    annual-rate: uint,
    creation-block: uint,
    term-duration: uint,
    vault-status: bool
  }
)

(define-map payment-history
  {
    vault-id: uint,
    vault-owner: principal
  }
  {
    amount-settled: uint
  }
)

(define-map vault-metrics
  {
    vault-id: uint
  }
  {
    health-factor: uint,
    last-update: uint
  }
)

;; System State
(define-data-var vault-counter uint u0)
(define-data-var protocol-fees uint u0)

;; Internal Validation Functions
(define-private (validate-vault-params 
    (btc-collateral uint)
    (borrowed-amount uint)
    (annual-rate uint)
    (term-duration uint)
  )
  (and
    (> btc-collateral u0)
    (<= btc-collateral SYSTEM-MAX-UINT)
    (> borrowed-amount u0)
    (<= borrowed-amount SYSTEM-MAX-UINT)
    (<= annual-rate MAX-APR-BASIS-POINTS)
    (> term-duration u0)
    (<= term-duration MAX-VAULT-DURATION)
  )
)

;; Verify vault ownership and existence
(define-private (verify-vault-access (vault-id uint))
  (is-some 
    (map-get? active-vaults {
      vault-id: vault-id, 
      vault-owner: tx-sender
    })
  )
)

;; Calculate minimum BTC collateral required
(define-private (compute-min-collateral (borrowed-amount uint))
  (/ (* borrowed-amount MIN-COLLATERAL-RATIO) u100)
)

;; Calculate vault health factor
(define-private (calculate-health-factor (btc-collateral uint) (borrowed-amount uint))
  (if (> borrowed-amount u0)
    (/ (* btc-collateral u100) borrowed-amount)
    u0
  )
)

;; Read-Only Query Functions
(define-read-only (get-vault-info (vault-id uint) (vault-owner principal))
  (map-get? active-vaults {vault-id: vault-id, vault-owner: vault-owner})
)

(define-read-only (get-payment-info (vault-id uint) (vault-owner principal))
  (map-get? payment-history {vault-id: vault-id, vault-owner: vault-owner})
)

(define-read-only (get-vault-health (vault-id uint))
  (map-get? vault-metrics {vault-id: vault-id})
)

(define-read-only (get-protocol-stats)
  {
    total-vaults: (var-get vault-counter),
    protocol-fees: (var-get protocol-fees)
  }
)

;; Core Protocol Functions
(define-public (open-vault 
    (btc-collateral uint)
    (borrowed-amount uint)
    (annual-rate uint)
    (term-duration uint)
  )
  (let 
    (
      (current-vault-id (var-get vault-counter))
      (new-vault-id (+ current-vault-id u1))
      (health-factor (calculate-health-factor btc-collateral borrowed-amount))
    )
    ;; Validate input parameters
    (asserts! 
      (validate-vault-params 
        btc-collateral 
        borrowed-amount 
        annual-rate 
        term-duration
      ) 
      VAULT-INVALID-INPUT
    )
    
    ;; Check vault doesn't already exist
    (asserts! 
      (is-none 
        (map-get? active-vaults {vault-id: new-vault-id, vault-owner: tx-sender})
      ) 
      VAULT-ALREADY-ACTIVE
    )
    
    ;; Ensure sufficient collateralization
    (asserts! 
      (>= btc-collateral (compute-min-collateral borrowed-amount)) 
      VAULT-UNDERCOLLATERALIZED
    )
    
    ;; Create new vault
    (map-set active-vaults 
      {vault-id: new-vault-id, vault-owner: tx-sender}
      {
        btc-collateral: btc-collateral,
        borrowed-amount: borrowed-amount,
        annual-rate: annual-rate,
        creation-block: block-height,
        term-duration: term-duration,
        vault-status: true
      }
    )
    
    ;; Initialize vault metrics
    (map-set vault-metrics
      {vault-id: new-vault-id}
      {
        health-factor: health-factor,
        last-update: block-height
      }
    )
    
    ;; Update system counter
    (var-set vault-counter new-vault-id)
    
    ;; Return new vault ID
    (ok new-vault-id)
  )
)

(define-public (boost-collateral (vault-id uint) (additional-btc uint))
  (let
    (
      ;; Verify vault access
      (vault-check (asserts! 
        (verify-vault-access vault-id) 
        VAULT-ACCESS-DENIED
      ))
      
      (vault-data (unwrap! 
        (map-get? active-vaults {vault-id: vault-id, vault-owner: tx-sender}) 
        VAULT-NOT-FOUND
      ))
    )
    ;; Ensure vault is active
    (asserts! (get vault-status vault-data) VAULT-ACCESS-DENIED)
    
    ;; Validate additional collateral
    (asserts! (> additional-btc u0) VAULT-INVALID-INPUT)
    
    ;; Calculate new totals
    (let
      (
        (new-btc-total (+ (get btc-collateral vault-data) additional-btc))
        (new-health-factor (calculate-health-factor new-btc-total (get borrowed-amount vault-data)))
      )
      (asserts! (<= new-btc-total SYSTEM-MAX-UINT) VAULT-INVALID-INPUT)
      
      ;; Update vault collateral
      (map-set active-vaults 
        {vault-id: vault-id, vault-owner: tx-sender}
        (merge vault-data {btc-collateral: new-btc-total})
      )
      
      ;; Update vault metrics
      (map-set vault-metrics
        {vault-id: vault-id}
        {
          health-factor: new-health-factor,
          last-update: block-height
        }
      )
      
      (ok new-btc-total)
    )
  )
)

(define-public (reduce-collateral (vault-id uint) (withdraw-btc uint))
  (let
    (
      ;; Verify vault access
      (vault-check (asserts! 
        (verify-vault-access vault-id) 
        VAULT-ACCESS-DENIED
      ))
      
      (vault-data (unwrap! 
        (map-get? active-vaults {vault-id: vault-id, vault-owner: tx-sender}) 
        VAULT-NOT-FOUND
      ))
    )
    ;; Validate vault is active
    (asserts! (get vault-status vault-data) VAULT-ACCESS-DENIED)
    
    ;; Validate withdrawal amount
    (asserts! (> withdraw-btc u0) VAULT-INVALID-INPUT)
    (asserts! (<= withdraw-btc (get btc-collateral vault-data)) VAULT-INSUFFICIENT-BALANCE)
    
    ;; Calculate remaining collateral
    (let
      (
        (remaining-btc (- (get btc-collateral vault-data) withdraw-btc))
        (min-required-btc (compute-min-collateral (get borrowed-amount vault-data)))
        (new-health-factor (calculate-health-factor remaining-btc (get borrowed-amount vault-data)))
      )
      ;; Ensure minimum collateral is maintained
      (asserts! (>= remaining-btc min-required-btc) VAULT-UNDERCOLLATERALIZED)
      
      ;; Update vault with reduced collateral
      (map-set active-vaults 
        {vault-id: vault-id, vault-owner: tx-sender}
        (merge vault-data {btc-collateral: remaining-btc})
      )
      
      ;; Update vault metrics
      (map-set vault-metrics
        {vault-id: vault-id}
        {
          health-factor: new-health-factor,
          last-update: block-height
        }
      )
      
      (ok withdraw-btc)
    )
  )
)

(define-public (settle-vault (vault-id uint))
  (let 
    (
      ;; Verify vault access
      (vault-check (asserts! 
        (verify-vault-access vault-id) 
        VAULT-ACCESS-DENIED
      ))
      
      (vault-data (unwrap! 
        (map-get? active-vaults {vault-id: vault-id, vault-owner: tx-sender}) 
        VAULT-NOT-FOUND
      ))
      (existing-payments (default-to 
        {amount-settled: u0} 
        (map-get? payment-history {vault-id: vault-id, vault-owner: tx-sender})
      ))
    )
    ;; Validate vault is active
    (asserts! (get vault-status vault-data) VAULT-ACCESS-DENIED)
    
    ;; Calculate total settlement amount with interest
    (let 
      (
        (total-settlement (+ 
          (get borrowed-amount vault-data)
          (/ (* (get borrowed-amount vault-data) (get annual-rate vault-data)) u100)
        ))
        (protocol-fee (/ total-settlement u100)) ;; 1% protocol fee
      )
      ;; Validate settlement amount doesn't overflow
      (asserts! (<= total-settlement SYSTEM-MAX-UINT) VAULT-PAYMENT-FAILURE)
      
      ;; Close vault
      (map-set active-vaults 
        {vault-id: vault-id, vault-owner: tx-sender}
        (merge vault-data {vault-status: false})
      )
      
      ;; Record payment
      (map-set payment-history
        {vault-id: vault-id, vault-owner: tx-sender}
        {amount-settled: total-settlement}
      )
      
      ;; Update protocol fees
      (var-set protocol-fees (+ (var-get protocol-fees) protocol-fee))
      
      (ok total-settlement)
    )
  )
)

(define-public (trigger-liquidation (vault-id uint))
  (let 
    (
      ;; Verify vault access
      (vault-check (asserts! 
        (verify-vault-access vault-id) 
        VAULT-ACCESS-DENIED
      ))
      
      (vault-data (unwrap! 
        (map-get? active-vaults {vault-id: vault-id, vault-owner: tx-sender}) 
        VAULT-NOT-FOUND
      ))
      (vault-health (unwrap!
        (map-get? vault-metrics {vault-id: vault-id})
        VAULT-NOT-FOUND
      ))
    )
    ;; Validate vault is active
    (asserts! (get vault-status vault-data) VAULT-ACCESS-DENIED)
    
    ;; Check liquidation conditions (either expired or undercollateralized)
    (asserts! 
      (or
        (> (- block-height (get creation-block vault-data)) 
           (get term-duration vault-data))
        (< (get health-factor vault-health) LIQUIDATION-THRESHOLD)
      )
      VAULT-LIQUIDATION-BLOCKED
    )
    
    ;; Execute liquidation
    (map-set active-vaults 
      {vault-id: vault-id, vault-owner: tx-sender}
      (merge vault-data {vault-status: false})
    )
    
    (ok true)
  )
)

;; New Function: Emergency Pause for Admin
(define-public (emergency-pause-vault (vault-id uint) (target-owner principal))
  (let
    (
      (vault-data (unwrap! 
        (map-get? active-vaults {vault-id: vault-id, vault-owner: target-owner}) 
        VAULT-NOT-FOUND
      ))
    )
    ;; Only protocol admin can pause vaults
    (asserts! (is-eq tx-sender PROTOCOL-ADMIN) VAULT-ACCESS-DENIED)
    
    ;; Pause the vault
    (map-set active-vaults 
      {vault-id: vault-id, vault-owner: target-owner}
      (merge vault-data {vault-status: false})
    )
    
    (ok vault-id)
  )
)