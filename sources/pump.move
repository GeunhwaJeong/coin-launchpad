// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Bonding-curve memecoin launchpad for Haneul.
///
/// Design notes
/// - `Configuration.admin` (the deployer) is the only privileged role and the
///   graduation destination is a configurable `migration_wallet`.
/// - No admin function can pull funds out of a live curve.
/// - `assert_pool_completed` aborts unless the pool has graduated.
///
/// How it works
/// - `create*` mints the whole supply into a `Pool<T>` stored as a dynamic
///   object field of the shared `Configuration`, keyed by the coin's package
///   address, and sends the `TreasuryCap` to 0x0 (supply is frozen).
/// - `buy*` / `sell*` price against virtual reserves (x * y = k) and send the
///   platform fee (bps / 10_000) to `Configuration.admin`.
/// - Graduation happens inside `buy*` when every sellable token is gone or the
///   real HANEUL reserve reaches the threshold; `transfer_pool` then hands all HANEUL
///   and all remaining tokens to `migration_wallet`, which seeds the DEX pool.
#[allow(lint(self_transfer, public_entry))]
module haneul_pump::pump;

use std::ascii::{Self, String};
use std::type_name;
use haneul_pump::curves;
use haneul::balance::{Self, Balance};
use haneul::clock::Clock;
use haneul::coin::{Self, Coin, TreasuryCap};
use haneul::dynamic_object_field as dof;
use haneul::event;
use haneul::haneul::HANEUL;

/// Every user entry point asserts `Configuration.version == VERSION`, so after
/// an upgrade the admin must call `migrate_version` or trading halts.
const VERSION: u64 = 13;
const FEE_DENOMINATOR: u64 = 10_000;

/// Real-HANEUL graduation thresholds of the v1 entry points (geunhwa). The v2 entry
/// points read the threshold from `ThresholdConfig` instead.
const LEGACY_GRADUATION_HANEUL: u64 = 3_000_000_000_000;
const LEGACY_FIRST_BUY_GRADUATION_HANEUL: u64 = 6_000_000_000_000;

const MAX_URI_LENGTH: u64 = 300;
const MAX_DESCRIPTION_LENGTH: u64 = 1000;
const MAX_LINK_LENGTH: u64 = 500;

const ENotAuthorized: u64 = 1;
const EInvalidArgument: u64 = 2;
const EWrongVersion: u64 = 4;
const EPoolCompleted: u64 = 5;
const EInsufficientHaneul: u64 = 6;
const ESupplyNotZero: u64 = 7;
const EPoolNotCompleted: u64 = 9;

// ===== Objects =====

public struct Configuration has key, store {
    id: UID,
    version: u64,
    admin: address,
    /// Receives graduated pools (all HANEUL + all remaining tokens).
    migration_wallet: address,
    /// Basis points of every trade, sent to `admin` (mainnet ran 100 = 1%).
    platform_fee: u64,
    /// Kept for event/schema parity; not read anywhere (mainnet: 150 HANEUL).
    graduated_fee: u64,
    /// Mainnet ran 500 HANEUL (init default 3000 HANEUL).
    initial_virtual_haneul_reserves: u64,
    /// Mainnet: 10_000_000_000 * 10^6.
    initial_virtual_token_reserves: u64,
    /// Share of supply held back for the DEX listing (mainnet: 20%).
    remain_token_reserves: u64,
    token_decimals: u8,
}

/// Graduation threshold for the `*_v2` entry points.
public struct ThresholdConfig has key, store {
    id: UID,
    threshold: u64,
}

public struct Pool<phantom T> has key, store {
    id: UID,
    real_haneul_reserves: Balance<HANEUL>,
    real_token_reserves: Balance<T>,
    virtual_token_reserves: u64,
    virtual_haneul_reserves: u64,
    remain_token_reserves: Balance<T>,
    is_completed: bool,
}

// ===== Events =====

public struct ConfigChangedEvent has copy, drop, store {
    old_platform_fee: u64,
    new_platform_fee: u64,
    old_graduated_fee: u64,
    new_graduated_fee: u64,
    old_initial_virtual_haneul_reserves: u64,
    new_initial_virtual_haneul_reserves: u64,
    old_initial_virtual_token_reserves: u64,
    new_initial_virtual_token_reserves: u64,
    old_remain_token_reserves: u64,
    new_remain_token_reserves: u64,
    old_token_decimals: u8,
    new_token_decimals: u8,
    ts: u64,
}

public struct CreatedEvent has copy, drop, store {
    name: String,
    symbol: String,
    uri: String,
    description: String,
    twitter: String,
    telegram: String,
    website: String,
    token_address: String,
    bonding_curve: String,
    pool_id: ID,
    created_by: address,
    virtual_haneul_reserves: u64,
    virtual_token_reserves: u64,
    ts: u64,
}

public struct OwnershipTransferredEvent has copy, drop, store {
    old_admin: address,
    new_admin: address,
    ts: u64,
}

public struct MigrationWalletChangedEvent has copy, drop, store {
    old_wallet: address,
    new_wallet: address,
    ts: u64,
}

public struct PoolCompletedEvent has copy, drop, store {
    token_address: String,
    /// "0x0" until the DEX pool is created off-chain (kept for indexer parity).
    lp: String,
    ts: u64,
}

public struct TradedEvent has copy, drop, store {
    is_buy: bool,
    user: address,
    token_address: String,
    haneul_amount: u64,
    token_amount: u64,
    virtual_haneul_reserves: u64,
    virtual_token_reserves: u64,
    pool_id: ID,
    ts: u64,
}

// ===== Init =====

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

/// Deployer becomes admin and the initial migration wallet. Defaults are the
/// deployed v1 values; mainnet later moved to 500 virtual HANEUL and 1% fee via
/// `update_config`.
fun init(ctx: &mut TxContext) {
    transfer::public_share_object(Configuration {
        id: object::new(ctx),
        version: VERSION,
        admin: ctx.sender(),
        migration_wallet: ctx.sender(),
        platform_fee: 50,
        graduated_fee: 300_000_000_000,
        initial_virtual_haneul_reserves: 3_000_000_000_000,
        initial_virtual_token_reserves: 10_000_000_000_000_000,
        remain_token_reserves: 2_000_000_000_000_000,
        token_decimals: 6,
    });
}

// ===== Internal helpers =====

/// Pools are keyed by the coin package address, so one package = one pool.
fun pool_key<T>(): String {
    type_name::with_defining_ids<T>().address_string()
}

fun borrow_pool<T>(config: &Configuration): &Pool<T> {
    dof::borrow(&config.id, pool_key<T>())
}

fun borrow_pool_mut<T>(config: &mut Configuration): &mut Pool<T> {
    dof::borrow_mut(&mut config.id, pool_key<T>())
}

fun assert_admin(config: &Configuration, ctx: &TxContext) {
    assert!(config.admin == ctx.sender(), ENotAuthorized);
}

fun fee_of(amount: u64, fee_bps: u64): u64 {
    ((amount as u128) * (fee_bps as u128) / (FEE_DENOMINATOR as u128)) as u64
}

fun assert_version(version: u64) {
    assert!(version == VERSION, EWrongVersion);
}

fun assert_lp_value_is_increased_or_not_changed(old_token: u64, old_haneul: u64, new_token: u64, new_haneul: u64) {
    assert!((old_token as u128) * (old_haneul as u128) <= (new_token as u128) * (new_haneul as u128), EInvalidArgument);
}

/// Moves coins through the pool. Virtual reserves are updated by the caller's
/// convention: the side that pays in has its *output* subtracted here, the
/// caller subtracts the other side afterwards.
fun swap<T>(
    pool: &mut Pool<T>,
    token_in: Coin<T>,
    haneul_in: Coin<HANEUL>,
    token_out: u64,
    haneul_out: u64,
    ctx: &mut TxContext,
): (Coin<T>, Coin<HANEUL>) {
    assert!(token_in.value() > 0 || haneul_in.value() > 0, EInvalidArgument);
    let old_token = pool.virtual_token_reserves;
    let old_haneul = pool.virtual_haneul_reserves;
    // Add the inputs before subtracting the outputs: subtracting first
    // underflows when a buyer's change exceeds the virtual HANEUL
    // reserve (paying with a coin larger than the reserve for a small buy).
    // The resulting reserves are identical.
    pool.virtual_token_reserves = pool.virtual_token_reserves + token_in.value();
    pool.virtual_haneul_reserves = pool.virtual_haneul_reserves + haneul_in.value();
    if (token_in.value() > 0) {
        pool.virtual_token_reserves = pool.virtual_token_reserves - token_out;
    };
    if (haneul_in.value() > 0) {
        pool.virtual_haneul_reserves = pool.virtual_haneul_reserves - haneul_out;
    };
    assert_lp_value_is_increased_or_not_changed(
        old_token,
        old_haneul,
        pool.virtual_token_reserves,
        pool.virtual_haneul_reserves,
    );
    pool.real_token_reserves.join(token_in.into_balance());
    pool.real_haneul_reserves.join(haneul_in.into_balance());
    (
        coin::take(&mut pool.real_token_reserves, token_out, ctx),
        coin::take(&mut pool.real_haneul_reserves, haneul_out, ctx),
    )
}

/// Graduation (v13 semantics): every HANEUL and every token still in the pool,
/// unsold plus the held-back 20%, go to `migration_wallet`.
fun transfer_pool<T>(pool: &mut Pool<T>, migration_wallet: address, clock: &Clock, ctx: &mut TxContext) {
    pool.is_completed = true;
    let token_amount = pool.real_token_reserves.value();
    let mut tokens = coin::take(&mut pool.real_token_reserves, token_amount, ctx);
    let remain_amount = pool.remain_token_reserves.value();
    tokens.join(coin::take(&mut pool.remain_token_reserves, remain_amount, ctx));
    let haneul_amount = pool.real_haneul_reserves.value();
    transfer::public_transfer(coin::take(&mut pool.real_haneul_reserves, haneul_amount, ctx), migration_wallet);
    transfer::public_transfer(tokens, migration_wallet);
    event::emit(PoolCompletedEvent {
        token_address: type_name::with_defining_ids<T>().into_string(),
        lp: ascii::string(b"0x0"),
        ts: clock.timestamp_ms(),
    });
}

/// Shared body of every buy entry point. `threshold` is the real-HANEUL reserve
/// at which the pool graduates.
fun buy_internal<T>(
    pool: &mut Pool<T>,
    mut payment: Coin<HANEUL>,
    token_amount: u64,
    fee_bps: u64,
    fee_recipient: address,
    migration_wallet: address,
    threshold: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<HANEUL>, Coin<T>) {
    assert!(!pool.is_completed, EPoolCompleted);
    assert!(token_amount > 0, EInvalidArgument);
    let paid = payment.value();
    let sellable = pool.virtual_token_reserves - pool.remain_token_reserves.value();
    let tokens_out = token_amount.min(sellable);
    // +1 rounds the cost up in the pool's favour.
    let cost = curves::calculate_add_liquidity_cost(
        pool.virtual_haneul_reserves,
        pool.virtual_token_reserves,
        tokens_out,
    ) + 1;
    let fee = fee_of(cost, fee_bps);
    assert!(paid >= cost + fee, EInsufficientHaneul);
    let fee_coin = payment.split(fee, ctx);
    let (tokens, change) = swap(pool, coin::zero<T>(ctx), payment, tokens_out, paid - cost - fee, ctx);
    pool.virtual_token_reserves = pool.virtual_token_reserves - tokens.value();
    transfer::public_transfer(fee_coin, fee_recipient);
    if (sellable == tokens_out || pool.real_haneul_reserves.value() >= threshold) {
        transfer_pool(pool, migration_wallet, clock, ctx);
    };
    event::emit(TradedEvent {
        is_buy: true,
        user: ctx.sender(),
        token_address: type_name::with_defining_ids<T>().into_string(),
        haneul_amount: cost,
        token_amount: tokens_out,
        virtual_haneul_reserves: pool.virtual_haneul_reserves,
        virtual_token_reserves: pool.virtual_token_reserves,
        pool_id: object::id(pool),
        ts: clock.timestamp_ms(),
    });
    (change, tokens)
}

/// Shared body of `sell` / `sell_returns`. Returns the HANEUL after fee and the
/// (always zero-valued) token coin, kept for PTB composition.
fun sell_internal<T>(
    pool: &mut Pool<T>,
    tokens: Coin<T>,
    min_haneul_out: u64,
    fee_bps: u64,
    fee_recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<HANEUL>, Coin<T>) {
    assert!(!pool.is_completed, EPoolCompleted);
    let token_amount = tokens.value();
    assert!(token_amount > 0, EInvalidArgument);
    let haneul_out = curves::calculate_remove_liquidity_return(
        pool.virtual_token_reserves,
        pool.virtual_haneul_reserves,
        token_amount,
    );
    let fee = fee_of(haneul_out, fee_bps);
    assert!(haneul_out - fee >= min_haneul_out, EInvalidArgument);
    let (token_dust, mut haneul) = swap(pool, tokens, coin::zero<HANEUL>(ctx), 0, haneul_out, ctx);
    pool.virtual_haneul_reserves = pool.virtual_haneul_reserves - haneul.value();
    transfer::public_transfer(haneul.split(fee, ctx), fee_recipient);
    event::emit(TradedEvent {
        is_buy: false,
        user: ctx.sender(),
        token_address: type_name::with_defining_ids<T>().into_string(),
        haneul_amount: haneul_out,
        token_amount,
        virtual_haneul_reserves: pool.virtual_haneul_reserves,
        virtual_token_reserves: pool.virtual_token_reserves,
        pool_id: object::id(pool),
        ts: clock.timestamp_ms(),
    });
    (haneul, token_dust)
}

fun new_pool<T>(config: &Configuration, cap: &mut TreasuryCap<T>, ctx: &mut TxContext): Pool<T> {
    Pool {
        id: object::new(ctx),
        real_haneul_reserves: balance::zero(),
        real_token_reserves: cap.mint_balance(
            config.initial_virtual_token_reserves - config.remain_token_reserves,
        ),
        virtual_token_reserves: config.initial_virtual_token_reserves,
        virtual_haneul_reserves: config.initial_virtual_haneul_reserves,
        remain_token_reserves: cap.mint_balance(config.remain_token_reserves),
        is_completed: false,
    }
}

fun assert_metadata_lengths(uri: &String, description: &String, twitter: &String, telegram: &String, website: &String) {
    assert!(uri.length() <= MAX_URI_LENGTH, EInvalidArgument);
    assert!(description.length() <= MAX_DESCRIPTION_LENGTH, EInvalidArgument);
    assert!(twitter.length() <= MAX_LINK_LENGTH, EInvalidArgument);
    assert!(telegram.length() <= MAX_LINK_LENGTH, EInvalidArgument);
    assert!(website.length() <= MAX_LINK_LENGTH, EInvalidArgument);
}

fun emit_created<T>(
    config: &Configuration,
    pool: &Pool<T>,
    name: String,
    symbol: String,
    uri: String,
    description: String,
    twitter: String,
    telegram: String,
    website: String,
    clock: &Clock,
    ctx: &TxContext,
) {
    event::emit(CreatedEvent {
        name,
        symbol,
        uri,
        description,
        twitter,
        telegram,
        website,
        token_address: type_name::with_defining_ids<T>().into_string(),
        bonding_curve: type_name::with_defining_ids<Pool<T>>().module_string(),
        pool_id: object::id(pool),
        created_by: ctx.sender(),
        virtual_haneul_reserves: config.initial_virtual_haneul_reserves,
        virtual_token_reserves: config.initial_virtual_token_reserves,
        ts: clock.timestamp_ms(),
    });
}

// ===== Create =====

/// Lists a fresh coin. The caller must pass a `TreasuryCap` with zero supply;
/// it is minted once and then sent to 0x0.
public entry fun create<T>(
    config: &mut Configuration,
    mut treasury_cap: TreasuryCap<T>,
    clock: &Clock,
    name: String,
    symbol: String,
    uri: String,
    description: String,
    twitter: String,
    telegram: String,
    website: String,
    ctx: &mut TxContext,
) {
    assert_metadata_lengths(&uri, &description, &twitter, &telegram, &website);
    assert_version(config.version);
    assert!(treasury_cap.total_supply() == 0, ESupplyNotZero);
    let pool = new_pool(config, &mut treasury_cap, ctx);
    transfer::public_transfer(treasury_cap, @0x0);
    emit_created(config, &pool, name, symbol, uri, description, twitter, telegram, website, clock, ctx);
    dof::add(&mut config.id, pool_key<T>(), pool);
}

/// `create` plus an immediate dev buy in the same transaction (6000 HANEUL
/// legacy graduation threshold).
public entry fun create_and_first_buy<T>(
    config: &mut Configuration,
    mut treasury_cap: TreasuryCap<T>,
    payment: Coin<HANEUL>,
    token_amount: u64,
    clock: &Clock,
    name: String,
    symbol: String,
    uri: String,
    description: String,
    twitter: String,
    telegram: String,
    website: String,
    ctx: &mut TxContext,
) {
    assert_metadata_lengths(&uri, &description, &twitter, &telegram, &website);
    assert_version(config.version);
    assert!(treasury_cap.total_supply() == 0, ESupplyNotZero);
    let mut pool = new_pool(config, &mut treasury_cap, ctx);
    transfer::public_transfer(treasury_cap, @0x0);
    if (payment.value() > 0) {
        let (change, tokens) = buy_internal(
            &mut pool,
            payment,
            token_amount,
            config.platform_fee,
            config.admin,
            config.migration_wallet,
            LEGACY_FIRST_BUY_GRADUATION_HANEUL,
            clock,
            ctx,
        );
        transfer::public_transfer(change, ctx.sender());
        transfer::public_transfer(tokens, ctx.sender());
    } else {
        payment.destroy_zero();
    };
    emit_created(config, &pool, name, symbol, uri, description, twitter, telegram, website, clock, ctx);
    dof::add(&mut config.id, pool_key<T>(), pool);
}

// ===== Buy =====

/// Legacy buy (3000 HANEUL threshold). Coins go straight to the sender.
public entry fun buy<T>(
    config: &mut Configuration,
    payment: Coin<HANEUL>,
    token_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (change, tokens) = buy_returns<T>(config, payment, token_amount, clock, ctx);
    transfer::public_transfer(change, ctx.sender());
    transfer::public_transfer(tokens, ctx.sender());
}

/// Legacy buy for PTB composition: returns (change, tokens).
public fun buy_returns<T>(
    config: &mut Configuration,
    payment: Coin<HANEUL>,
    token_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<HANEUL>, Coin<T>) {
    assert_version(config.version);
    let fee_bps = config.platform_fee;
    let admin = config.admin;
    let migration_wallet = config.migration_wallet;
    let pool = borrow_pool_mut<T>(config);
    buy_internal(pool, payment, token_amount, fee_bps, admin, migration_wallet, LEGACY_GRADUATION_HANEUL, clock, ctx)
}

/// Buy with the configurable `ThresholdConfig` threshold.
public entry fun buy_v2<T>(
    config: &mut Configuration,
    threshold_config: &ThresholdConfig,
    payment: Coin<HANEUL>,
    token_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (change, tokens) = buy_returns_v2<T>(config, threshold_config, payment, token_amount, clock, ctx);
    transfer::public_transfer(change, ctx.sender());
    transfer::public_transfer(tokens, ctx.sender());
}

public fun buy_returns_v2<T>(
    config: &mut Configuration,
    threshold_config: &ThresholdConfig,
    payment: Coin<HANEUL>,
    token_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<HANEUL>, Coin<T>) {
    assert_version(config.version);
    let fee_bps = config.platform_fee;
    let admin = config.admin;
    let migration_wallet = config.migration_wallet;
    let pool = borrow_pool_mut<T>(config);
    buy_internal(pool, payment, token_amount, fee_bps, admin, migration_wallet, threshold_config.threshold, clock, ctx)
}

// ===== Sell =====

public entry fun sell<T>(
    config: &mut Configuration,
    tokens: Coin<T>,
    min_haneul_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (haneul, token_dust) = sell_returns<T>(config, tokens, min_haneul_out, clock, ctx);
    transfer::public_transfer(haneul, ctx.sender());
    token_dust.destroy_zero();
}

/// Sell for PTB composition: returns (HANEUL after fee, zero token coin).
public fun sell_returns<T>(
    config: &mut Configuration,
    tokens: Coin<T>,
    min_haneul_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<HANEUL>, Coin<T>) {
    assert_version(config.version);
    let fee_bps = config.platform_fee;
    let admin = config.admin;
    let pool = borrow_pool_mut<T>(config);
    sell_internal(pool, tokens, min_haneul_out, fee_bps, admin, clock, ctx)
}

// ===== Views =====

/// Quote. Pass exactly one non-zero amount; returns (haneul_out, token_out)
/// after the platform fee.
public fun estimate_amount_out<T>(config: &Configuration, haneul_in: u64, token_in: u64): (u64, u64) {
    let pool = borrow_pool<T>(config);
    if (haneul_in > 0 && token_in == 0) {
        let haneul_after_fee = haneul_in - fee_of(haneul_in, config.platform_fee);
        (0, curves::calculate_token_amount_received(pool.virtual_haneul_reserves, pool.virtual_token_reserves, haneul_after_fee))
    } else if (haneul_in == 0 && token_in > 0) {
        let haneul_out = curves::calculate_remove_liquidity_return(pool.virtual_token_reserves, pool.virtual_haneul_reserves, token_in);
        (haneul_out - fee_of(haneul_out, config.platform_fee), 0)
    } else {
        (0, 0)
    }
}

public fun check_pool_exist<T>(config: &Configuration): bool {
    dof::exists(&config.id, pool_key<T>())
}

public fun is_pool_completed<T>(config: &Configuration): bool {
    borrow_pool<T>(config).is_completed
}

/// Aborts unless the pool has graduated (was `asert_pool_not_completed`).
public fun assert_pool_completed<T>(config: &Configuration) {
    assert!(is_pool_completed<T>(config), EPoolNotCompleted);
}

/// (real HANEUL, real tokens, held-back tokens, virtual HANEUL, virtual tokens)
public fun pool_reserves<T>(config: &Configuration): (u64, u64, u64, u64, u64) {
    let pool = borrow_pool<T>(config);
    (
        pool.real_haneul_reserves.value(),
        pool.real_token_reserves.value(),
        pool.remain_token_reserves.value(),
        pool.virtual_haneul_reserves,
        pool.virtual_token_reserves,
    )
}

public fun admin(config: &Configuration): address { config.admin }
public fun migration_wallet(config: &Configuration): address { config.migration_wallet }
public fun platform_fee(config: &Configuration): u64 { config.platform_fee }

// ===== Admin =====

public entry fun migrate_version(config: &mut Configuration, new_version: u64, ctx: &mut TxContext) {
    assert_admin(config, ctx);
    config.version = new_version;
}

public entry fun transfer_admin(config: &mut Configuration, new_admin: address, clock: &Clock, ctx: &mut TxContext) {
    assert_admin(config, ctx);
    let old_admin = config.admin;
    config.admin = new_admin;
    event::emit(OwnershipTransferredEvent { old_admin, new_admin, ts: clock.timestamp_ms() });
}

public entry fun update_migration_wallet(config: &mut Configuration, new_wallet: address, clock: &Clock, ctx: &mut TxContext) {
    assert_admin(config, ctx);
    let old_wallet = config.migration_wallet;
    config.migration_wallet = new_wallet;
    event::emit(MigrationWalletChangedEvent { old_wallet, new_wallet, ts: clock.timestamp_ms() });
}

public entry fun update_config(
    config: &mut Configuration,
    platform_fee: u64,
    graduated_fee: u64,
    initial_virtual_haneul_reserves: u64,
    initial_virtual_token_reserves: u64,
    remain_token_reserves: u64,
    token_decimals: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_admin(config, ctx);
    assert!(platform_fee <= FEE_DENOMINATOR, EInvalidArgument);
    assert!(remain_token_reserves < initial_virtual_token_reserves, EInvalidArgument);
    let old_platform_fee = config.platform_fee;
    let old_graduated_fee = config.graduated_fee;
    let old_initial_virtual_haneul_reserves = config.initial_virtual_haneul_reserves;
    let old_initial_virtual_token_reserves = config.initial_virtual_token_reserves;
    let old_remain_token_reserves = config.remain_token_reserves;
    let old_token_decimals = config.token_decimals;
    config.platform_fee = platform_fee;
    config.graduated_fee = graduated_fee;
    config.initial_virtual_haneul_reserves = initial_virtual_haneul_reserves;
    config.initial_virtual_token_reserves = initial_virtual_token_reserves;
    config.remain_token_reserves = remain_token_reserves;
    config.token_decimals = token_decimals;
    event::emit(ConfigChangedEvent {
        old_platform_fee,
        new_platform_fee: platform_fee,
        old_graduated_fee,
        new_graduated_fee: graduated_fee,
        old_initial_virtual_haneul_reserves,
        new_initial_virtual_haneul_reserves: initial_virtual_haneul_reserves,
        old_initial_virtual_token_reserves,
        new_initial_virtual_token_reserves: initial_virtual_token_reserves,
        old_remain_token_reserves,
        new_remain_token_reserves: remain_token_reserves,
        old_token_decimals,
        new_token_decimals: token_decimals,
        ts: clock.timestamp_ms(),
    });
}

/// Shares a new `ThresholdConfig` for the `*_v2` entry points.
public entry fun create_threshold_config(config: &Configuration, threshold: u64, ctx: &mut TxContext) {
    assert_admin(config, ctx);
    transfer::public_share_object(ThresholdConfig { id: object::new(ctx), threshold });
}

public entry fun update_threshold_config(
    config: &Configuration,
    threshold_config: &mut ThresholdConfig,
    threshold: u64,
    ctx: &mut TxContext,
) {
    assert_admin(config, ctx);
    threshold_config.threshold = threshold;
}
