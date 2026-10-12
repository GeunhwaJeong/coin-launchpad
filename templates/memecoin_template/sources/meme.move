// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Memecoin template for the Haneul launchpad.
///
/// Metadata goes into the CoinRegistry (`Currency<MEME>` is sent to 0xc by
/// `finalize`; anyone can then call `coin_registry::finalize_registration`).
/// The publisher receives the `TreasuryCap`, which `pump::create` consumes
/// (mints the whole supply, then parks the cap at 0x0), and the `MetadataCap`.
module memecoin_template::meme;

use haneul::coin_registry;

public struct MEME has drop {}

const DECIMALS: u8 = 6;

fun init(otw: MEME, ctx: &mut TxContext) {
    let (init, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        DECIMALS,
        b"MEME".to_string(),
        b"Test Meme".to_string(),
        b"Launchpad e2e coin".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = init.finalize(ctx);
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
