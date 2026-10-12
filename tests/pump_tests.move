#[test_only]
module haneul_pump::pump_tests;

use haneul_pump::curves;
use haneul_pump::pump::{Self, Configuration, ThresholdConfig};
use haneul::clock;
use haneul::coin::{Self, Coin};
use haneul::coin_registry;
use haneul::haneul::HANEUL;
use haneul::test_scenario as ts;
use haneul::test_utils;
use std::unit_test::destroy;

/// One-time witness for the test coin.
public struct PUMP_TESTS has drop {}

const DEPLOYER: address = @0xDE;
const OPS_WALLET: address = @0x0b5;
const USER: address = @0xA11CE;

// init() defaults
const VIRTUAL_HANEUL: u64 = 3_000_000_000_000;
const VIRTUAL_TOKEN: u64 = 10_000_000_000_000_000;
const REMAIN_TOKEN: u64 = 2_000_000_000_000_000;
const FEE_BPS: u64 = 50;

const TEN_PERCENT: u64 = 1_000_000_000_000_000;
// cost of 10% of the supply from the init curve: 3000 * 10/9 - 3000, floored, +1
const COST: u64 = 333_333_333_334;

fun s(b: vector<u8>): std::ascii::String { std::ascii::string(b) }

/// Publishes the module, points graduation at OPS_WALLET, lists the test coin,
/// and leaves the scenario at the next tx of `USER`.
fun setup(): ts::Scenario {
    let mut sc = ts::begin(DEPLOYER);
    pump::init_for_testing(sc.ctx());
    sc.next_tx(DEPLOYER);
    {
        let mut config = sc.take_shared<Configuration>();
        let clock = clock::create_for_testing(sc.ctx());
        assert!(pump::admin(&config) == DEPLOYER);
        pump::update_migration_wallet(&mut config, OPS_WALLET, &clock, sc.ctx());
        // Same path the launched memecoin modules take: metadata lives in the
        // CoinRegistry (`Currency<T>`), the launchpad only needs the TreasuryCap.
        let (init, cap) = coin_registry::new_currency_with_otw(
            test_utils::create_one_time_witness<PUMP_TESTS>(),
            6, b"TST".to_string(), b"Test".to_string(), b"".to_string(), b"".to_string(), sc.ctx(),
        );
        let (currency, metadata_cap) = init.finalize_unwrap_for_testing(sc.ctx());
        destroy(currency);
        destroy(metadata_cap);
        pump::create<PUMP_TESTS>(
            &mut config, cap, &clock,
            s(b"Test"), s(b"TST"), s(b"ipfs://x"), s(b"desc"), s(b""), s(b""), s(b""),
            sc.ctx(),
        );
        assert!(pump::check_pool_exist<PUMP_TESTS>(&config));
        assert!(!pump::is_pool_completed<PUMP_TESTS>(&config));
        clock.destroy_for_testing();
        ts::return_shared(config);
    };
    sc.next_tx(USER);
    sc
}

#[test]
fun curve_math_matches_closed_form() {
    let cost = curves::calculate_add_liquidity_cost(VIRTUAL_HANEUL, VIRTUAL_TOKEN, TEN_PERCENT);
    assert!(cost == COST - 1);
    let expected = ((VIRTUAL_HANEUL as u128) * (VIRTUAL_TOKEN as u128) / ((VIRTUAL_TOKEN - TEN_PERCENT) as u128)) as u64 - VIRTUAL_HANEUL;
    assert!(cost == expected);
    // Selling straight back rounds 1 geunhwa in the seller's favour, which the +1 in buy cancels.
    let back = curves::calculate_remove_liquidity_return(VIRTUAL_TOKEN - TEN_PERCENT, VIRTUAL_HANEUL + cost, TEN_PERCENT);
    assert!(back == cost + 1);
    let tokens = curves::calculate_token_amount_received(VIRTUAL_HANEUL, VIRTUAL_TOKEN, cost);
    assert!(tokens == 999_999_999_999_100);
}

#[test]
fun buy_then_sell_round_trip() {
    let mut sc = setup();
    let fee = COST * FEE_BPS / 10_000;
    {
        let mut config = sc.take_shared<Configuration>();
        let clock = clock::create_for_testing(sc.ctx());
        let payment = coin::mint_for_testing<HANEUL>(400_000_000_000, sc.ctx());
        let (change, tokens) = pump::buy_returns<PUMP_TESTS>(&mut config, payment, TEN_PERCENT, &clock, sc.ctx());
        assert!(tokens.value() == TEN_PERCENT);
        assert!(change.value() == 400_000_000_000 - COST - fee);
        let (real_haneul, real_token, remain, vhaneul, vtoken) = pump::pool_reserves<PUMP_TESTS>(&config);
        assert!(real_haneul == COST);
        assert!(real_token == VIRTUAL_TOKEN - REMAIN_TOKEN - TEN_PERCENT);
        assert!(remain == REMAIN_TOKEN);
        assert!(vhaneul == VIRTUAL_HANEUL + COST);
        assert!(vtoken == VIRTUAL_TOKEN - TEN_PERCENT);
        transfer::public_transfer(change, USER);
        transfer::public_transfer(tokens, USER);
        clock.destroy_for_testing();
        ts::return_shared(config);
    };
    // Platform fee landed with the admin.
    sc.next_tx(DEPLOYER);
    {
        let fee_coin = sc.take_from_sender<Coin<HANEUL>>();
        assert!(fee_coin.value() == fee);
        sc.return_to_sender(fee_coin);
    };
    sc.next_tx(USER);
    {
        let mut config = sc.take_shared<Configuration>();
        let clock = clock::create_for_testing(sc.ctx());
        let tokens = sc.take_from_sender<Coin<PUMP_TESTS>>();
        let (quote, _) = pump::estimate_amount_out<PUMP_TESTS>(&config, 0, TEN_PERCENT);
        let (haneul, dust) = pump::sell_returns<PUMP_TESTS>(&mut config, tokens, 0, &clock, sc.ctx());
        // Curve is symmetric: the gross return equals the gross cost paid.
        assert!(haneul.value() == COST - COST * FEE_BPS / 10_000);
        assert!(haneul.value() == quote);
        assert!(dust.value() == 0);
        let (real_haneul, _, _, vhaneul, vtoken) = pump::pool_reserves<PUMP_TESTS>(&config);
        assert!(real_haneul == 0);
        assert!(vhaneul == VIRTUAL_HANEUL);
        assert!(vtoken == VIRTUAL_TOKEN);
        transfer::public_transfer(haneul, USER);
        dust.destroy_zero();
        clock.destroy_for_testing();
        ts::return_shared(config);
    };
    sc.end();
}

#[test]
fun selling_out_graduates_pool_to_migration_wallet() {
    let mut sc = setup();
    let sellable = VIRTUAL_TOKEN - REMAIN_TOKEN;
    {
        let mut config = sc.take_shared<Configuration>();
        let clock = clock::create_for_testing(sc.ctx());
        // 3000 * (10/2) - 3000 = 12000 HANEUL drains the curve.
        let payment = coin::mint_for_testing<HANEUL>(13_000_000_000_000, sc.ctx());
        pump::buy<PUMP_TESTS>(&mut config, payment, sellable, &clock, sc.ctx());
        pump::assert_pool_completed<PUMP_TESTS>(&config);
        let (real_haneul, real_token, remain, _, _) = pump::pool_reserves<PUMP_TESTS>(&config);
        assert!(real_haneul == 0 && real_token == 0 && remain == 0);
        clock.destroy_for_testing();
        ts::return_shared(config);
    };
    sc.next_tx(OPS_WALLET);
    {
        let haneul = sc.take_from_sender<Coin<HANEUL>>();
        assert!(haneul.value() == 12_000_000_000_001);
        let tokens = sc.take_from_sender<Coin<PUMP_TESTS>>();
        assert!(tokens.value() == REMAIN_TOKEN);
        sc.return_to_sender(haneul);
        sc.return_to_sender(tokens);
    };
    sc.end();
}

#[test]
fun haneul_threshold_graduates_with_leftover_tokens() {
    let mut sc = setup();
    sc.next_tx(DEPLOYER);
    {
        let config = sc.take_shared<Configuration>();
        pump::create_threshold_config(&config, 1_000_000_000_000, sc.ctx());
        ts::return_shared(config);
    };
    sc.next_tx(USER);
    {
        let mut config = sc.take_shared<Configuration>();
        let threshold = sc.take_shared<ThresholdConfig>();
        let clock = clock::create_for_testing(sc.ctx());
        // 3000 * 10/7 - 3000 = 1285.7 HANEUL > 1000 HANEUL threshold, so buying 30% graduates.
        let payment = coin::mint_for_testing<HANEUL>(1_400_000_000_000, sc.ctx());
        pump::buy_v2<PUMP_TESTS>(&mut config, &threshold, payment, 3 * TEN_PERCENT, &clock, sc.ctx());
        assert!(pump::is_pool_completed<PUMP_TESTS>(&config));
        clock.destroy_for_testing();
        ts::return_shared(threshold);
        ts::return_shared(config);
    };
    sc.next_tx(OPS_WALLET);
    {
        let haneul = sc.take_from_sender<Coin<HANEUL>>();
        assert!(haneul.value() == 1_285_714_285_715);
        // unsold 50% + held-back 20%
        let tokens = sc.take_from_sender<Coin<PUMP_TESTS>>();
        assert!(tokens.value() == VIRTUAL_TOKEN - 3 * TEN_PERCENT);
        sc.return_to_sender(haneul);
        sc.return_to_sender(tokens);
    };
    sc.end();
}

#[test, expected_failure(abort_code = pump::EPoolCompleted)]
fun buy_after_graduation_aborts() {
    let mut sc = setup();
    let sellable = VIRTUAL_TOKEN - REMAIN_TOKEN;
    let mut config = sc.take_shared<Configuration>();
    let clock = clock::create_for_testing(sc.ctx());
    let payment = coin::mint_for_testing<HANEUL>(13_000_000_000_000, sc.ctx());
    pump::buy<PUMP_TESTS>(&mut config, payment, sellable, &clock, sc.ctx());
    let payment = coin::mint_for_testing<HANEUL>(1_000_000_000, sc.ctx());
    pump::buy<PUMP_TESTS>(&mut config, payment, 1, &clock, sc.ctx());
    abort 0
}

#[test, expected_failure(abort_code = pump::EWrongVersion)]
fun stale_version_halts_trading() {
    let mut sc = setup();
    sc.next_tx(DEPLOYER);
    let mut config = sc.take_shared<Configuration>();
    pump::migrate_version(&mut config, 99, sc.ctx());
    let clock = clock::create_for_testing(sc.ctx());
    let payment = coin::mint_for_testing<HANEUL>(1_000_000_000, sc.ctx());
    pump::buy<PUMP_TESTS>(&mut config, payment, 1, &clock, sc.ctx());
    abort 0
}

#[test, expected_failure(abort_code = pump::ENotAuthorized)]
fun non_admin_cannot_change_migration_wallet() {
    let mut sc = setup();
    let mut config = sc.take_shared<Configuration>();
    let clock = clock::create_for_testing(sc.ctx());
    pump::update_migration_wallet(&mut config, USER, &clock, sc.ctx());
    abort 0
}

#[test, expected_failure(abort_code = pump::EInvalidArgument)]
fun sell_respects_min_out() {
    let mut sc = setup();
    let mut config = sc.take_shared<Configuration>();
    let clock = clock::create_for_testing(sc.ctx());
    let payment = coin::mint_for_testing<HANEUL>(400_000_000_000, sc.ctx());
    let (change, tokens) = pump::buy_returns<PUMP_TESTS>(&mut config, payment, TEN_PERCENT, &clock, sc.ctx());
    change.burn_for_testing();
    let (haneul, dust) = pump::sell_returns<PUMP_TESTS>(&mut config, tokens, COST, &clock, sc.ctx());
    haneul.burn_for_testing();
    dust.destroy_zero();
    abort 0
}

#[test]
fun overpaying_with_a_huge_coin_returns_change() {
    let mut sc = setup();
    let mut config = sc.take_shared<Configuration>();
    let clock = clock::create_for_testing(sc.ctx());
    // A coin 10x the virtual reserve for a 10% buy: change exceeds the reserve.
    let payment = coin::mint_for_testing<HANEUL>(10 * VIRTUAL_HANEUL, sc.ctx());
    let (change, tokens) = pump::buy_returns<PUMP_TESTS>(&mut config, payment, TEN_PERCENT, &clock, sc.ctx());
    let fee = COST * FEE_BPS / 10_000;
    assert!(change.value() == 10 * VIRTUAL_HANEUL - COST - fee);
    assert!(tokens.value() == TEN_PERCENT);
    let (_, _, _, vhaneul, _) = pump::pool_reserves<PUMP_TESTS>(&config);
    assert!(vhaneul == VIRTUAL_HANEUL + COST);
    change.burn_for_testing();
    tokens.burn_for_testing();
    clock.destroy_for_testing();
    ts::return_shared(config);
    sc.end();
}
