#!/usr/bin/env python3
# Copyright (c) 2026 Geunhwa Jeong
# SPDX-License-Identifier: Apache-2.0
"""Localnet end-to-end test for haneul_pump.

Flow: publish launchpad + memecoin template -> tune config -> create pool ->
buy 10% -> sell it back -> buy everything (graduation) -> ops wallet receives
HANEUL + reserve tokens -> buy after graduation aborts.

Prereqs (all outside this repo):
    haneul start --force-regenesis --with-faucet
    a client config whose active env is the localnet, two funded addresses
    aliased `deployer` (active) and `ops`.

    HANEUL=/path/to/haneul HANEUL_CLIENT_CONFIG=/path/to/client.yaml python3 e2e/localnet_e2e.py
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HANEUL = os.environ.get("HANEUL", "haneul")
CLIENT_CONFIG = os.environ.get("HANEUL_CLIENT_CONFIG")
PUBFILE = Path(os.environ.get("HANEUL_PUBFILE", ROOT / "e2e/Pub.localnet.toml"))
MAINNET_CHAIN_ID = "a0053d9e"
GAS_BUDGET = 2_000_000_000
CLOCK = "@0x6"
COIN_REGISTRY = "@0xc"

# Pool parameters set through update_config before listing (small so the faucet covers graduation).
VIRTUAL_HANEUL = 30_000_000_000  # 30 HANEUL
VIRTUAL_TOKEN = 10_000_000_000_000_000  # 10B tokens, 6 decimals
REMAIN_TOKEN = 2_000_000_000_000_000  # 20%
FEE_BPS = 100  # 1%
TEN_PERCENT = 1_000_000_000_000_000
SELLABLE = VIRTUAL_TOKEN - REMAIN_TOKEN


class E2EError(Exception):
    pass


def cli(*args):
    cfg = ["--client.config", CLIENT_CONFIG] if CLIENT_CONFIG else []
    return subprocess.run([HANEUL, "client", *cfg, *args], capture_output=True, text=True, cwd=ROOT)


def u64(n):
    return f"{n}u64"


def s(text):
    return f'"{text}"'


def call(target, type_args, *args):
    cmd = ["--move-call", target]
    if type_args:
        cmd.append("<" + ",".join(type_args) + ">")
    return cmd + list(args)


ABORT_RE = re.compile(
    r"aborted within function '0x[0-9a-f]+::(\w+)::(\w+)' at "
    r"(?:instruction \d+ with code|line \d+\. Aborted with error code) (\d+)"
)

RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond)))
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f"  ({detail})" if detail else ""))


def eq(name, got, want):
    check(name, got == want, f"{got}" if got == want else f"got {got}, want {want}")


def section(title):
    print(f"\n== {title}")


def ptb(label, cmds, expect_abort=None):
    p = cli("ptb", *cmds, "--gas-budget", str(GAS_BUDGET), "--json")
    out = p.stdout + p.stderr
    if expect_abort is not None:
        m = ABORT_RE.search(out)
        got = (m.group(1), int(m.group(3))) if m else None
        ok = got == expect_abort
        check(f"{label}: aborts with {expect_abort[0]}::{expect_abort[1]}", ok, "" if ok else out[-500:].strip())
        return None
    if p.returncode != 0:
        raise E2EError(f"{label} failed:\n{out[-3000:]}")
    j = json.loads(p.stdout)
    if j["effects"]["status"]["status"] != "success":
        raise E2EError(f"{label} failed on chain: {j['effects']['status']}")
    return j


def events(j, suffix):
    return [e["parsedJson"] for e in j.get("events", []) if e["type"].split("<")[0].endswith(suffix)]


def changes(j, kind, type_substr, owner_kind=None):
    out = []
    for c in j["objectChanges"]:
        if c["type"] != kind or type_substr not in c.get("objectType", ""):
            continue
        if owner_kind and not (isinstance(c.get("owner"), dict) and owner_kind in c["owner"]):
            continue
        out.append(c)
    return out


def address(alias):
    p = cli("addresses", "--json")
    rows = json.loads(p.stdout)["addresses"]
    return next(a for n, a in rows if n == alias)


def balances(addr):
    """{coin_type: total} via the localnet JSON-RPC (haneulx_getAllBalances)."""
    rows, active = json.loads(cli("envs", "--json").stdout)
    url = next(r["rpc"] for r in rows if r["alias"] == active)
    req = {"jsonrpc": "2.0", "id": 1, "method": "haneulx_getAllBalances", "params": [addr]}
    p = subprocess.run(["curl", "-s", "-m", "10", url, "-H", "Content-Type: application/json", "-d", json.dumps(req)],
                       capture_output=True, text=True)
    res = json.loads(p.stdout)["result"]
    return {b["coinType"]: int(b["totalBalance"]) for b in res}


def safety_check():
    env = cli("active-env").stdout.strip()
    chain = cli("chain-identifier").stdout.strip().splitlines()[-1].split()[-1]
    envs_json = cli("envs", "--json").stdout
    rows, active = json.loads(envs_json)
    url = next(r["rpc"] for r in rows if r["alias"] == active)
    if chain == MAINNET_CHAIN_ID or not chain or ("127.0.0.1" not in url and "localhost" not in url):
        sys.exit(f"refusing to run: env {env}, chain {chain}, rpc {url}")
    print(f"localnet chain {chain}, env {env}, rpc {url}")


def publish(path):
    p = subprocess.run(
        [HANEUL, "client", *(["--client.config", CLIENT_CONFIG] if CLIENT_CONFIG else []),
         "test-publish", "--build-env", "mainnet", "--pubfile-path", str(PUBFILE),
         "--gas-budget", str(GAS_BUDGET), "--json"],
        capture_output=True, text=True, cwd=path,
    )
    if p.returncode != 0:
        raise E2EError(f"publish {path.name} failed:\n{(p.stdout + p.stderr)[-3000:]}")
    j = json.loads(p.stdout)
    if j["effects"]["status"]["status"] != "success":
        raise E2EError(f"publish {path.name}: {j['effects']['status']}")
    pkg = next(c["packageId"] for c in j["objectChanges"] if c["type"] == "published")
    print(f"  published {path.name:20s} {pkg}")
    return pkg, j


def main():
    safety_check()
    if PUBFILE.exists():
        PUBFILE.unlink()
    deployer = address("deployer")
    ops = address("ops")

    section("publish")
    pump_pkg, j = publish(ROOT)
    config = changes(j, "created", "::pump::Configuration", "Shared")[0]["objectId"]
    print(f"  Configuration {config}")
    meme_pkg, j = publish(ROOT / "templates/memecoin_template")
    coin_type = f"{meme_pkg}::meme::MEME"
    treasury = changes(j, "created", f"TreasuryCap<{coin_type}>", "AddressOwner")[0]["objectId"]
    currency = changes(j, "created", f"coin_registry::Currency<{coin_type}>")
    check("Currency<MEME> created by the template init", len(currency) == 1)
    check(
        "Currency<MEME> was sent to the CoinRegistry (0xc)",
        currency and str(currency[0]["owner"].get("AddressOwner", "")).endswith("c"),
        json.dumps(currency[0]["owner"]) if currency else "",
    )
    ops_before = balances(ops)

    section("register metadata (finalize_registration, anyone can call)")
    try:
        ptb("finalize_registration", call(f"0x2::coin_registry::finalize_registration", [coin_type], COIN_REGISTRY, f"@{currency[0]['objectId']}"))
        check("finalize_registration succeeded", True)
    except E2EError as e:
        check("finalize_registration succeeded", False, str(e)[-300:])

    section("configure launchpad")
    ptb("update_config", call(f"{pump_pkg}::pump::update_config", None, f"@{config}",
        u64(FEE_BPS), u64(0), u64(VIRTUAL_HANEUL), u64(VIRTUAL_TOKEN), u64(REMAIN_TOKEN), "6u8", CLOCK))
    j = ptb("update_migration_wallet", call(f"{pump_pkg}::pump::update_migration_wallet", None, f"@{config}", f"@{ops}", CLOCK))
    ev = events(j, "::MigrationWalletChangedEvent")
    eq("migration wallet event", ev[0]["new_wallet"], ops)

    section("create pool")
    j = ptb("create", call(f"{pump_pkg}::pump::create", [coin_type], f"@{config}", f"@{treasury}", CLOCK,
        s("Test Meme"), s("MEME"), s("ipfs://meme"), s("launchpad e2e"), s(""), s(""), s("")))
    ev = events(j, "::CreatedEvent")[0]
    eq("CreatedEvent virtual_haneul_reserves", int(ev["virtual_haneul_reserves"]), VIRTUAL_HANEUL)
    eq("CreatedEvent created_by", ev["created_by"], deployer)
    pool_id = ev["pool_id"]
    cap_moves = [c for c in j["objectChanges"] if "TreasuryCap" in c.get("objectType", "") and c["type"] == "mutated"]
    check("TreasuryCap parked at 0x0", cap_moves and str(cap_moves[0]["owner"].get("AddressOwner", "")).strip("0x") == "", json.dumps(cap_moves[0]["owner"]) if cap_moves else "")

    section("buy 10%")
    cost = VIRTUAL_HANEUL * VIRTUAL_TOKEN // (VIRTUAL_TOKEN - TEN_PERCENT) - VIRTUAL_HANEUL + 1
    fee = cost * FEE_BPS // 10_000
    pay = 40_000_000_000
    j = ptb("buy", ["--split-coins", "gas", f"[{u64(pay)}]", "--assign", "pay",
        *call(f"{pump_pkg}::pump::buy", [coin_type], f"@{config}", "pay.0", u64(TEN_PERCENT), CLOCK)])
    ev = events(j, "::TradedEvent")[0]
    eq("buy: is_buy", ev["is_buy"], True)
    eq("buy: haneul_amount (cost)", int(ev["haneul_amount"]), cost)
    eq("buy: token_amount", int(ev["token_amount"]), TEN_PERCENT)
    eq("buy: virtual_haneul_reserves", int(ev["virtual_haneul_reserves"]), VIRTUAL_HANEUL + cost)
    eq("buy: virtual_token_reserves", int(ev["virtual_token_reserves"]), VIRTUAL_TOKEN - TEN_PERCENT)
    eq("buy: pool_id matches", ev["pool_id"], pool_id)
    token_coins = changes(j, "created", f"Coin<{coin_type}>", "AddressOwner")
    check("buy: received a MEME coin object", len(token_coins) == 1)
    deployer_bal = balances(deployer)
    eq("buy: MEME balance", deployer_bal.get(coin_type, 0), TEN_PERCENT)
    admin_fee_coins = [c for c in changes(j, "created", "Coin<0x2::haneul::HANEUL>", "AddressOwner")]
    check("buy: fee coin created for admin", any(True for _ in admin_fee_coins))

    section("sell it back")
    gross = cost  # symmetric curve
    net = gross - gross * FEE_BPS // 10_000
    j = ptb("sell", call(f"{pump_pkg}::pump::sell", [coin_type], f"@{config}", f"@{token_coins[0]['objectId']}", u64(0), CLOCK))
    ev = events(j, "::TradedEvent")[0]
    eq("sell: is_buy", ev["is_buy"], False)
    eq("sell: haneul_amount (gross)", int(ev["haneul_amount"]), gross)
    eq("sell: virtual_haneul_reserves back to start", int(ev["virtual_haneul_reserves"]), VIRTUAL_HANEUL)
    eq("sell: virtual_token_reserves back to start", int(ev["virtual_token_reserves"]), VIRTUAL_TOKEN)
    out_coins = changes(j, "created", "Coin<0x2::haneul::HANEUL>", "AddressOwner")
    eq("sell: MEME balance back to 0", balances(deployer).get(coin_type, 0), 0)
    check("sell: produced HANEUL coins (user + fee)", len(out_coins) == 2, f"{len(out_coins)} coins")

    section("slippage guard")
    j = ptb("buy for slippage test", ["--split-coins", "gas", f"[{u64(pay)}]", "--assign", "pay",
        *call(f"{pump_pkg}::pump::buy", [coin_type], f"@{config}", "pay.0", u64(TEN_PERCENT), CLOCK)])
    tc = changes(j, "created", f"Coin<{coin_type}>", "AddressOwner")[0]["objectId"]
    ptb("sell with min_out above gross", call(f"{pump_pkg}::pump::sell", [coin_type], f"@{config}", f"@{tc}", u64(gross), CLOCK), expect_abort=("pump", 2))
    ptb("sell again with min_out = net", call(f"{pump_pkg}::pump::sell", [coin_type], f"@{config}", f"@{tc}", u64(net), CLOCK))

    section("graduation by selling out the curve")
    full_cost = VIRTUAL_HANEUL * VIRTUAL_TOKEN // REMAIN_TOKEN - VIRTUAL_HANEUL + 1
    full_fee = full_cost * FEE_BPS // 10_000
    pay = full_cost + full_fee + 5_000_000_000
    j = ptb("buy everything", ["--split-coins", "gas", f"[{u64(pay)}]", "--assign", "pay",
        *call(f"{pump_pkg}::pump::buy", [coin_type], f"@{config}", "pay.0", u64(SELLABLE), CLOCK)])
    ev = events(j, "::TradedEvent")[0]
    eq("graduation buy: haneul_amount", int(ev["haneul_amount"]), full_cost)
    eq("graduation buy: token_amount = all sellable", int(ev["token_amount"]), SELLABLE)
    done = events(j, "::PoolCompletedEvent")
    check("PoolCompletedEvent emitted", len(done) == 1)
    eq("PoolCompletedEvent token_address", done[0]["token_address"].lstrip("0x") if done else "", coin_type[2:] if done else "x")
    ops_after = balances(ops)
    eq("ops wallet received the curve's HANEUL", ops_after.get("0x2::haneul::HANEUL", 0) - ops_before.get("0x2::haneul::HANEUL", 0), full_cost)
    eq("ops wallet received the 20% reserve tokens", ops_after.get(coin_type, 0), REMAIN_TOKEN)
    eq("deployer holds all sellable tokens", balances(deployer).get(coin_type, 0), SELLABLE)

    section("after graduation")
    ptb("buy on a completed pool", ["--split-coins", "gas", "[1000000000u64]", "--assign", "pay",
        *call(f"{pump_pkg}::pump::buy", [coin_type], f"@{config}", "pay.0", u64(1), CLOCK)], expect_abort=("pump", 5))
    ptb("assert_pool_completed passes", call(f"{pump_pkg}::pump::assert_pool_completed", [coin_type], f"@{config}"))

    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if PUBFILE.exists():
        PUBFILE.unlink()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    try:
        main()
    except E2EError as e:
        print(f"\nE2E ERROR: {e}")
        sys.exit(2)
