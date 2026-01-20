# Valancer Clarity Contract

DAO/keeper-controlled rebalancer for a 50/50 STX and sBTC portfolio. The contract tracks a price feed updated by a trusted oracle signer, checks staleness, and executes swaps via a DEX trait when the portfolio drifts beyond a threshold.

## Traits and Interfaces

- `ft-trait`: SIP-010-compatible token interface used for sBTC balance checks.
- `dex-trait`: DEX interface with `swap-stx-for-token` and `swap-token-for-stx`.

## Roles and State

- `dao`: admin principal that can set DAO, keeper, and oracle signer.
- `keeper`: optional principal allowed to call `rebalance`.
- `oracle-signer`: optional principal allowed to call `update-price`.
- `last-price`: latest oracle price (uint, STX/BTC scaled by `PRICE-SCALE`).
- `last-updated`: burn block height when the last price was updated.

## Public Functions

- `set-dao(new-dao)`: sets the DAO principal (one-time initializer or DAO-only update).
- `set-keeper(new-keeper)`: DAO-only setter for keeper role.
- `set-oracle-signer(new-oracle)`: DAO-only setter for oracle signer role.
- `update-price(new-price)`: DAO or oracle signer updates `last-price` and `last-updated`.
- `rebalance(oracle-price, dex-contract, sbtc-contract)`: checks price freshness, computes the STX/sBTC ratio, and swaps via the DEX when deviation exceeds the threshold.

## Rebalance Logic (High Level)

- Uses `last-price` and compares it to `oracle-price` provided in the call.
- Rejects stale data based on `burn-block-height` and `MAX-PRICE-AGE`.
- Computes STX value in BTC units using `PRICE-SCALE`.
- If STX ratio is above/below bounds, swaps to restore target ratio.
- Enforces `MIN-TRADE-BTC` and slippage bounds via `SLIPPAGE-BPS`.

## Return Values

`rebalance` returns a tuple with:

- `action`: `ACTION_NONE`, `ACTION_SELL_STX`, or `ACTION_BUY_STX`.
- `amount-in`, `min-out`, `expected-out`, `amount-out`.
- `price`, `stx-ratio-bps`, `target-bps`.

## Errors

The contract uses explicit error codes for authorization, price checks, balance checks, and trade constraints (see constants in `contracts/valancer.clar`).
