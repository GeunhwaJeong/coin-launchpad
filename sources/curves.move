// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Constant-product bonding-curve math (x * y = k over virtual reserves).
///
/// All arithmetic goes through `utils::U256`; `utils::sub` aborts with 2 on
/// underflow and `utils::as_u64` aborts with 0 when the result does not fit,
/// which is the only overflow protection the curve has.
module haneul_pump::curves;

use haneul_pump::utils;

const ENoTokensLeft: u64 = 100;

fun u(x: u64): utils::U256 { utils::from_u64(x) }

/// HANEUL needed to take `token_out` tokens out of the curve:
/// `virtual_haneul * virtual_token / (virtual_token - token_out) - virtual_haneul`.
public fun calculate_add_liquidity_cost(virtual_haneul: u64, virtual_token: u64, token_out: u64): u64 {
    let new_virtual_token = utils::as_u64(utils::sub(u(virtual_token), u(token_out)));
    assert!(new_virtual_token > 0, ENoTokensLeft);
    let new_virtual_haneul = utils::as_u64(utils::div(utils::mul(u(virtual_haneul), u(virtual_token)), u(new_virtual_token)));
    utils::as_u64(utils::sub(u(new_virtual_haneul), u(virtual_haneul)))
}

/// HANEUL returned for selling `token_in` tokens into the curve:
/// `virtual_haneul - virtual_token * virtual_haneul / (virtual_token + token_in)`.
public fun calculate_remove_liquidity_return(virtual_token: u64, virtual_haneul: u64, token_in: u64): u64 {
    let new_virtual_token = utils::as_u64(utils::add(u(virtual_token), u(token_in)));
    let new_virtual_haneul = utils::as_u64(utils::div(utils::mul(u(virtual_token), u(virtual_haneul)), u(new_virtual_token)));
    utils::as_u64(utils::sub(u(virtual_haneul), u(new_virtual_haneul)))
}

/// Tokens received for `haneul_in` HANEUL (quote only, used by `estimate_amount_out`):
/// `virtual_token - virtual_haneul * virtual_token / (virtual_haneul + haneul_in)`.
public fun calculate_token_amount_received(virtual_haneul: u64, virtual_token: u64, haneul_in: u64): u64 {
    let new_virtual_haneul = utils::as_u64(utils::add(u(virtual_haneul), u(haneul_in)));
    let new_virtual_token = utils::as_u64(utils::div(utils::mul(u(virtual_haneul), u(virtual_token)), u(new_virtual_haneul)));
    utils::as_u64(utils::sub(u(virtual_token), u(new_virtual_token)))
}
