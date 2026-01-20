
;; Assumes sBTC is a SIP-010 token
(define-trait ft-trait
  (
    (get-balance (principal) (response uint uint))
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
  )
)

(define-trait dex-trait
  (
    (swap-stx-for-token (uint uint) (response uint uint))
    (swap-token-for-stx (uint uint) (response uint uint))
  )
)

(define-constant TARGET-RATIO u50) ;; 50% STX / 50% sBTC
(define-constant RATIO-SCALE-BPS u10000)
(define-constant TARGET-RATIO-BPS (* TARGET-RATIO u100))
(define-constant REBALANCE-THRESHOLD-BPS u500) ;; 5%
(define-constant PRICE-SCALE u1000000)
(define-constant SLIPPAGE-SCALE u10000)
(define-constant SLIPPAGE-BPS u50) ;; 0.50%
(define-constant MIN-TRADE-BTC u1)
(define-constant MAX-PRICE-AGE u144)

(define-constant ACTION_NONE u0)
(define-constant ACTION_SELL_STX u1)
(define-constant ACTION_BUY_STX u2)

(define-constant ERR_UNAUTHORIZED u100)
(define-constant ERR_PRICE_INVALID u104)
(define-constant ERR_PRICE_STALE u105)
(define-constant ERR_PRICE_MISMATCH u106)
(define-constant ERR_SBTC_BALANCE u107)
(define-constant ERR_NO_BALANCE u108)
(define-constant ERR_MIN_TRADE u109)
(define-constant ERR_INSUFFICIENT_BALANCE u110)
(define-data-var dao (optional principal) none)
(define-data-var keeper (optional principal) none)
(define-data-var oracle-signer (optional principal) none)
(define-data-var last-price uint u0)
(define-data-var last-updated uint u0)

(define-private (is-dao (sender principal))
  (match (var-get dao)
    dao-principal (is-eq sender dao-principal)
    false
  )
)

(define-private (is-authorized (sender principal))
  (or
    (is-dao sender)
    (match (var-get keeper)
      keeper-principal (is-eq sender keeper-principal)
      false
    )
  )
)

(define-private (is-oracle (sender principal))
  (match (var-get oracle-signer)
    oracle-principal (is-eq sender oracle-principal)
    false
  )
)

(define-public (set-dao (new-dao principal))
  (match (var-get dao)
    current-dao
      (if (is-eq tx-sender current-dao)
        (begin (var-set dao (some new-dao)) (ok true))
        (err ERR_UNAUTHORIZED)
      )
    (begin (var-set dao (some new-dao)) (ok true))
  )
)

(define-public (set-keeper (new-keeper (optional principal)))
  (begin
    (asserts! (is-dao tx-sender) (err ERR_UNAUTHORIZED))
    (var-set keeper new-keeper)
    (ok true)
  )
)

(define-public (set-oracle-signer (new-oracle (optional principal)))
  (begin
    (asserts! (is-dao tx-sender) (err ERR_UNAUTHORIZED))
    (var-set oracle-signer new-oracle)
    (ok true)
  )
)

(define-public (update-price (new-price uint))
  (begin
    (asserts! (or (is-dao tx-sender) (is-oracle tx-sender)) (err ERR_UNAUTHORIZED))
    (asserts! (> new-price u0) (err ERR_PRICE_INVALID))
    (var-set last-price new-price)
    (var-set last-updated burn-block-height)
    (ok true)
  )
)

(define-public (rebalance (oracle-price uint) (dex-contract <dex-trait>) (sbtc-contract <ft-trait>))
  (begin
    (asserts! (is-authorized tx-sender) (err ERR_UNAUTHORIZED))
    (let (
      (onchain-price (var-get last-price))
      (price-updated (var-get last-updated))
    )
      (begin
        (asserts! (> onchain-price u0) (err ERR_PRICE_INVALID))
        (asserts! (is-eq oracle-price onchain-price) (err ERR_PRICE_MISMATCH))
        (asserts! (>= burn-block-height price-updated) (err ERR_PRICE_INVALID))
        (asserts! (<= (- burn-block-height price-updated) MAX-PRICE-AGE) (err ERR_PRICE_STALE))
        (let (
          (self (as-contract tx-sender))
          (stx-bal (stx-get-balance self))
          (sbtc-bal (unwrap! (contract-call? sbtc-contract get-balance self) (err ERR_SBTC_BALANCE)))
          (stx-btc-value (/ (* stx-bal PRICE-SCALE) onchain-price))
          (total-btc (+ sbtc-bal stx-btc-value))
        )
          (if (is-eq total-btc u0)
            (err ERR_NO_BALANCE)
            (let (
              (stx-ratio-bps (/ (* stx-btc-value RATIO-SCALE-BPS) total-btc))
              (target-bps TARGET-RATIO-BPS)
              (upper-bound (+ target-bps REBALANCE-THRESHOLD-BPS))
              (lower-bound (if (> target-bps REBALANCE-THRESHOLD-BPS)
                (- target-bps REBALANCE-THRESHOLD-BPS)
                u0
              ))
            )
              (if (> stx-ratio-bps upper-bound)
                (let (
                  (target-stx-btc (/ (* total-btc target-bps) RATIO-SCALE-BPS))
                  (excess-btc (- stx-btc-value target-stx-btc))
                )
                  (if (< excess-btc MIN-TRADE-BTC)
                    (err ERR_MIN_TRADE)
                    (let (
                      (stx-to-sell (/ (* excess-btc onchain-price) PRICE-SCALE))
                      (min-out (/ (* excess-btc (- SLIPPAGE-SCALE SLIPPAGE-BPS)) SLIPPAGE-SCALE))
                    )
                      (begin
                        (asserts! (<= stx-to-sell stx-bal) (err ERR_INSUFFICIENT_BALANCE))
                        (match (contract-call? dex-contract swap-stx-for-token stx-to-sell min-out)
                          amount-out
                            (ok (tuple
                              (action ACTION_SELL_STX)
                              (amount-in stx-to-sell)
                              (min-out min-out)
                              (expected-out excess-btc)
                              (amount-out amount-out)
                              (price onchain-price)
                              (stx-ratio-bps stx-ratio-bps)
                              (target-bps target-bps)
                            ))
                          err-code (err err-code)
                        )
                      )
                    )
                  )
                )
                (if (< stx-ratio-bps lower-bound)
                  (let (
                    (target-stx-btc (/ (* total-btc target-bps) RATIO-SCALE-BPS))
                    (deficit-btc (- target-stx-btc stx-btc-value))
                  )
                    (if (< deficit-btc MIN-TRADE-BTC)
                      (err ERR_MIN_TRADE)
                      (let (
                        (expected-out (/ (* deficit-btc onchain-price) PRICE-SCALE))
                        (min-out (/ (* expected-out (- SLIPPAGE-SCALE SLIPPAGE-BPS)) SLIPPAGE-SCALE))
                      )
                        (begin
                          (asserts! (<= deficit-btc sbtc-bal) (err ERR_INSUFFICIENT_BALANCE))
                          (match (contract-call? dex-contract swap-token-for-stx deficit-btc min-out)
                            amount-out
                              (ok (tuple
                                (action ACTION_BUY_STX)
                                (amount-in deficit-btc)
                                (min-out min-out)
                                (expected-out expected-out)
                                (amount-out amount-out)
                                (price onchain-price)
                                (stx-ratio-bps stx-ratio-bps)
                                (target-bps target-bps)
                              ))
                            err-code (err err-code)
                          )
                        )
                      )
                    )
                  )
                  (ok (tuple
                    (action ACTION_NONE)
                    (amount-in u0)
                    (min-out u0)
                    (expected-out u0)
                    (amount-out u0)
                    (price onchain-price)
                    (stx-ratio-bps stx-ratio-bps)
                    (target-bps target-bps)
                  ))
                )
              )
            )
          )
        )
      )
    )
  )
)
