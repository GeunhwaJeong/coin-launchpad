# coin-launchpad

Bonding-curve memecoin launchpad for the Haneul network, written in Move.

Anyone can list a fresh coin, trade it against a constant-product curve, and
let it graduate to a DEX pool once the curve sells out or reaches a HANEUL
threshold. No admin function can take funds out of a live curve.

- Package `haneul_pump`: `pump` (launchpad), `curves` (curve math), `utils` (u256 helpers)
- Unit tests: `haneul move test --build-env mainnet` (9 tests)
- Localnet end-to-end: `e2e/localnet_e2e.py` (31 checks)

## How it works

| Step | What happens |
|---|---|
| List | `create*` mints the entire supply into a `Pool<T>` stored as a dynamic object field of the shared `Configuration`, keyed by the coin's package address (one package, one pool). The `TreasuryCap` is sent to `0x0`, so the supply is frozen forever. |
| Trade | `buy*` / `sell*` price against virtual reserves (x * y = k). Buy cost is rounded up by 1 geunhwa in the pool's favour. Every trade pays `platform_fee` (basis points) to `Configuration.admin`. |
| Graduate | Inside `buy*`, when every sellable token is gone or the real HANEUL reserve reaches the threshold, `transfer_pool` sends all HANEUL and all remaining tokens (unsold plus the held-back share) to `migration_wallet`, which seeds the DEX pool. `PoolCompletedEvent` is emitted. |
| Version gate | Every user entry point requires `Configuration.version == VERSION`. After a package upgrade the admin must call `migrate_version`, otherwise trading halts. This is also a freeze switch; operators should say so to users. |

Roles: `Configuration.admin` (the deployer) is the only privileged account. It
can change fees, curve defaults, the migration wallet and the version, and
share a `ThresholdConfig` used by the `*_v2` entry points. It cannot withdraw
from a pool.

### Entry points

| Function | Notes |
|---|---|
| `create<T>(config, treasury_cap, clock, name, symbol, uri, description, twitter, telegram, website)` | Lists a coin whose supply is still zero |
| `create_and_first_buy<T>(..., payment, token_amount, ...)` | Same plus a dev buy in the same transaction (6000 HANEUL threshold) |
| `buy<T>` / `buy_returns<T>` | 3000 HANEUL graduation threshold; `_returns` hands coins back for PTB composition |
| `buy_v2<T>` / `buy_returns_v2<T>` | Threshold taken from a shared `ThresholdConfig` |
| `sell<T>` / `sell_returns<T>` | `min_haneul_out` slippage guard |
| `estimate_amount_out<T>(config, haneul_in, token_in)` | Quote after fee; pass exactly one non-zero amount |
| `check_pool_exist<T>`, `is_pool_completed<T>`, `assert_pool_completed<T>`, `pool_reserves<T>` | Views |

Events: `CreatedEvent`, `TradedEvent`, `PoolCompletedEvent`,
`ConfigChangedEvent`, `OwnershipTransferredEvent`, `MigrationWalletChangedEvent`.

## Parameters to decide before deploying

`init()` defaults are placeholders. Set them with `update_config` before the
first listing; pools keep the values that were current when they were created.

| Field | Default | Meaning |
|---|---|---|
| `initial_virtual_haneul_reserves` | 3,000 HANEUL | Sets the starting market cap |
| `initial_virtual_token_reserves` | 10,000,000,000 × 10^6 | Total supply (6 decimals) |
| `remain_token_reserves` | 20% | Share held back for the DEX pool |
| `platform_fee` | 50 bps | Trade fee to `admin` |
| `LEGACY_GRADUATION_HANEUL` | 3,000 / 6,000 HANEUL | v1 entry points; `*_v2` use `ThresholdConfig` |
| `token_decimals` | 6 | Not enforced on `create` yet |

## Launching a coin

Move cannot define a new coin type inside a transaction, so every memecoin is
its own small package. `templates/memecoin_template` is the module to publish
per coin: its `init` registers metadata in the `CoinRegistry`
(`coin_registry::new_currency_with_otw`, then anyone calls
`finalize_registration`) and hands the `TreasuryCap` to the publisher, who
then calls `pump::create`.

## Localnet end-to-end

```
haneul start --force-regenesis --with-faucet          # separate terminal
# client.yaml whose active env is the localnet, with two funded addresses aliased
# `deployer` (active) and `ops`
HANEUL=<haneul binary> HANEUL_CLIENT_CONFIG=<client.yaml> python3 e2e/localnet_e2e.py
```

The script refuses to run unless the active env points at 127.0.0.1 and the
chain identifier is not mainnet. It publishes the launchpad and the template,
registers the coin, tunes the config (30 virtual HANEUL, 1% fee), creates a
pool, buys 10%, sells it back, checks the slippage guard, sells the curve out
to graduate it, verifies the ops wallet received the HANEUL and the held-back
tokens, and checks that buying a completed pool aborts. `test-publish` records
(`Pub.*.toml`) are removed at the end.

## Layout

```
Move.toml
sources/pump.move                launchpad
sources/curves.move              bonding-curve formulas
sources/utils.move               u256 emulation used by curves
tests/pump_tests.move            unit tests
e2e/localnet_e2e.py              localnet end-to-end
templates/memecoin_template/     coin module to publish per memecoin
deps/haneul-framework/           vendored Haneul framework (see SOURCE_REV.txt)
```

## Roadmap

1. On-chain graduation: create the Haneul CLAMM pool inside `transfer_pool`
   and burn the LP instead of handing funds to `migration_wallet`.
2. Backend that publishes the coin module and calls `create` in one flow.
3. Keep the `TreasuryCap` inside the `CoinRegistry` (`make_supply_fixed_init`)
   so wallets display the supply as fixed.
