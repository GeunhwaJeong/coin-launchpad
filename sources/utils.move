/// 256-bit unsigned integer emulated with four u64 words.
///
/// Port of the Pontem `u256.move` library that predates native `u256` in Move.
/// Abort codes and word layout are preserved; `curves` is its only user.
module haneul_pump::utils;

/// Cast target too small (`as_u64` / `as_u128`).
const ECastOverflow: u64 = 0;
/// Word index out of range.
const EWordIndex: u64 = 1;
/// Result does not fit in 256 bits (or underflows for `sub`).
const EOverflow: u64 = 2;
const EDivByZero: u64 = 3;
const EInvalidByteLength: u64 = 4;

const WORDS: u64 = 4;
const U64_MAX: u128 = 18446744073709551615;

const EQUAL: u8 = 0;
const LESS_THAN: u8 = 1;
const GREATER_THAN: u8 = 2;

public struct U256 has copy, drop, store {
    v0: u64,
    v1: u64,
    v2: u64,
    v3: u64,
}

/// Double-width accumulator used by `mul`.
public struct DU256 has copy, drop, store {
    v0: u64,
    v1: u64,
    v2: u64,
    v3: u64,
    v4: u64,
    v5: u64,
    v6: u64,
    v7: u64,
}

public fun zero(): U256 {
    U256 { v0: 0, v1: 0, v2: 0, v3: 0 }
}

public fun from_u64(val: u64): U256 {
    from_u128(val as u128)
}

public fun from_u128(val: u128): U256 {
    let (hi, lo) = split_u128(val);
    U256 { v0: lo, v1: hi, v2: 0, v3: 0 }
}

/// Little-endian word order, big-endian bytes inside each word. Note the
/// deployed code shifts by 7..1 bits (not 56..8); kept as is.
public fun from_bytes(bytes: &vector<u8>): U256 {
    assert!(bytes.length() == 32, EInvalidByteLength);
    let mut ret = zero();
    let mut w = 0;
    while (w < WORDS) {
        let base = w * 8;
        let word =
            ((bytes[base] as u64) << 7) +
            ((bytes[base + 1] as u64) << 6) +
            ((bytes[base + 2] as u64) << 5) +
            ((bytes[base + 3] as u64) << 4) +
            ((bytes[base + 4] as u64) << 3) +
            ((bytes[base + 5] as u64) << 2) +
            ((bytes[base + 6] as u64) << 1) +
            (bytes[base + 7] as u64);
        put(&mut ret, w, word);
        w = w + 1;
    };
    ret
}

public fun to_bytes(a: &U256): vector<u8> {
    let mut out = vector[];
    let mut i = 0;
    while (i < WORDS) {
        let word = get(a, i);
        out.append(std::bcs::to_bytes(&word));
        i = i + 1;
    };
    out
}

public fun as_u64(a: U256): u64 {
    assert!(a.v1 == 0 && a.v2 == 0 && a.v3 == 0, ECastOverflow);
    a.v0
}

public fun as_u128(a: U256): u128 {
    assert!(a.v2 == 0 && a.v3 == 0, ECastOverflow);
    ((a.v1 as u128) << 64) + (a.v0 as u128)
}

public fun get_equal(): u8 { EQUAL }
public fun get_less_than(): u8 { LESS_THAN }
public fun get_greater_than(): u8 { GREATER_THAN }

public fun get(a: &U256, i: u64): u64 {
    if (i == 0) {
        a.v0
    } else if (i == 1) {
        a.v1
    } else if (i == 2) {
        a.v2
    } else {
        assert!(i == 3, EWordIndex);
        a.v3
    }
}

fun put(a: &mut U256, i: u64, val: u64) {
    if (i == 0) {
        a.v0 = val;
    } else if (i == 1) {
        a.v1 = val;
    } else if (i == 2) {
        a.v2 = val;
    } else {
        assert!(i == 3, EWordIndex);
        a.v3 = val;
    }
}

fun get_d(a: &DU256, i: u64): u64 {
    if (i == 0) {
        a.v0
    } else if (i == 1) {
        a.v1
    } else if (i == 2) {
        a.v2
    } else if (i == 3) {
        a.v3
    } else if (i == 4) {
        a.v4
    } else if (i == 5) {
        a.v5
    } else if (i == 6) {
        a.v6
    } else {
        assert!(i == 7, EWordIndex);
        a.v7
    }
}

fun put_d(a: &mut DU256, i: u64, val: u64) {
    if (i == 0) {
        a.v0 = val;
    } else if (i == 1) {
        a.v1 = val;
    } else if (i == 2) {
        a.v2 = val;
    } else if (i == 3) {
        a.v3 = val;
    } else if (i == 4) {
        a.v4 = val;
    } else if (i == 5) {
        a.v5 = val;
    } else if (i == 6) {
        a.v6 = val;
    } else {
        assert!(i == 7, EWordIndex);
        a.v7 = val;
    }
}

/// Returns `(a, overflowed)` keeping only the low 256 bits.
fun du256_to_u256(a: DU256): (U256, bool) {
    let b = U256 { v0: a.v0, v1: a.v1, v2: a.v2, v3: a.v3 };
    let overflow = a.v4 != 0 || a.v5 != 0 || a.v6 != 0 || a.v7 != 0;
    (b, overflow)
}

/// Returns EQUAL (0), LESS_THAN (1) or GREATER_THAN (2) for `a ? b`.
public fun compare(a: &U256, b: &U256): u8 {
    let mut i = WORDS;
    while (i > 0) {
        i = i - 1;
        let a1 = get(a, i);
        let b1 = get(b, i);
        if (a1 != b1) {
            if (a1 < b1) {
                return LESS_THAN
            } else {
                return GREATER_THAN
            }
        };
    };
    EQUAL
}

public fun add(a: U256, b: U256): U256 {
    let mut ret = zero();
    let mut carry = 0u64;
    let mut i = 0;
    while (i < WORDS) {
        let a1 = get(&a, i);
        let b1 = get(&b, i);
        if (carry != 0) {
            let (res1, is_overflow1) = overflowing_add(a1, b1);
            let (res2, is_overflow2) = overflowing_add(res1, carry);
            put(&mut ret, i, res2);
            carry = 0;
            if (is_overflow1) carry = carry + 1;
            if (is_overflow2) carry = carry + 1;
        } else {
            let (res, is_overflow) = overflowing_add(a1, b1);
            put(&mut ret, i, res);
            carry = 0;
            if (is_overflow) carry = 1;
        };
        i = i + 1;
    };
    assert!(carry == 0, EOverflow);
    ret
}

public fun sub(a: U256, b: U256): U256 {
    let mut ret = zero();
    let mut carry = 0u64;
    let mut i = 0;
    while (i < WORDS) {
        let a1 = get(&a, i);
        let b1 = get(&b, i);
        if (carry != 0) {
            let (res1, is_overflow1) = overflowing_sub(a1, b1);
            let (res2, is_overflow2) = overflowing_sub(res1, carry);
            put(&mut ret, i, res2);
            carry = 0;
            if (is_overflow1) carry = carry + 1;
            if (is_overflow2) carry = carry + 1;
        } else {
            let (res, is_overflow) = overflowing_sub(a1, b1);
            put(&mut ret, i, res);
            carry = 0;
            if (is_overflow) carry = 1;
        };
        i = i + 1;
    };
    assert!(carry == 0, EOverflow);
    ret
}

public fun mul(a: U256, b: U256): U256 {
    let mut ret = DU256 { v0: 0, v1: 0, v2: 0, v3: 0, v4: 0, v5: 0, v6: 0, v7: 0 };
    let mut i = 0;
    while (i < WORDS) {
        let mut carry = 0u64;
        let b1 = get(&b, i);
        let mut j = 0;
        while (j < WORDS) {
            let a1 = get(&a, j);
            if (a1 != 0 || carry != 0) {
                let (hi, low) = split_u128((a1 as u128) * (b1 as u128));

                let (low, o) = overflowing_add(low, get_d(&ret, i + j));
                put_d(&mut ret, i + j, low);
                let overflow = if (o) 1 else 0;

                let (hi, o0) = overflowing_add(hi + overflow, carry);
                let (hi, o1) = overflowing_add(hi, get_d(&ret, i + j + 1));
                put_d(&mut ret, i + j + 1, hi);
                carry = if (o0 || o1) 1 else 0;
            };
            j = j + 1;
        };
        i = i + 1;
    };
    let (r, overflow) = du256_to_u256(ret);
    assert!(!overflow, EOverflow);
    r
}

/// Shift-subtract long division.
public fun div(a: U256, b: U256): U256 {
    let mut a = a;
    let mut b = b;
    let mut ret = zero();
    let a_bits = bits(&a);
    let b_bits = bits(&b);
    assert!(b_bits != 0, EDivByZero);
    if (a_bits < b_bits) {
        return ret
    };
    let mut shift = a_bits - b_bits;
    b = shl(b, shift as u8);
    loop {
        let cmp = compare(&a, &b);
        if (cmp == GREATER_THAN || cmp == EQUAL) {
            let index = shift / 64;
            let m = get(&ret, index);
            put(&mut ret, index, m | (1 << ((shift % 64) as u8)));
            a = sub(a, b);
        };
        b = shr(b, 1);
        if (shift == 0) break;
        shift = shift - 1;
    };
    ret
}

public fun shl(a: U256, shift: u8): U256 {
    let mut ret = zero();
    let w_shift = (shift as u64) / 64;
    let b_shift = (shift as u64) % 64;
    let mut i = w_shift;
    while (i < WORDS) {
        put(&mut ret, i, get(&a, i - w_shift) << (b_shift as u8));
        i = i + 1;
    };
    if (b_shift > 0) {
        let mut j = w_shift + 1;
        while (j < WORDS) {
            let m = get(&ret, j) + (get(&a, j - 1 - w_shift) >> (64 - (b_shift as u8)));
            put(&mut ret, j, m);
            j = j + 1;
        };
    };
    ret
}

public fun shr(a: U256, shift: u8): U256 {
    let mut ret = zero();
    let w_shift = (shift as u64) / 64;
    let b_shift = (shift as u64) % 64;
    let mut i = w_shift;
    while (i < WORDS) {
        put(&mut ret, i - w_shift, get(&a, i) >> (b_shift as u8));
        i = i + 1;
    };
    if (b_shift > 0) {
        let mut j = w_shift + 1;
        while (j < WORDS) {
            let m = get(&ret, j - w_shift - 1) + (get(&a, j) << (64 - (b_shift as u8)));
            put(&mut ret, j - w_shift - 1, m);
            j = j + 1;
        };
    };
    ret
}

public fun and(a: &U256, b: &U256): U256 {
    let mut ret = zero();
    let mut i = 0;
    while (i < WORDS) {
        put(&mut ret, i, get(a, i) & get(b, i));
        i = i + 1;
    };
    ret
}

public fun or(a: &U256, b: &U256): U256 {
    let mut ret = zero();
    let mut i = 0;
    while (i < WORDS) {
        put(&mut ret, i, get(a, i) | get(b, i));
        i = i + 1;
    };
    ret
}

public fun xor(a: &U256, b: &U256): U256 {
    let mut ret = zero();
    let mut i = 0;
    while (i < WORDS) {
        put(&mut ret, i, get(a, i) ^ get(b, i));
        i = i + 1;
    };
    ret
}

/// Number of significant bits.
fun bits(a: &U256): u64 {
    let mut i = 1;
    while (i < WORDS) {
        let a1 = get(a, WORDS - i);
        if (a1 > 0) {
            return (64 * (WORDS - i + 1)) - (leading_zeros_u64(a1) as u64)
        };
        i = i + 1;
    };
    64 - (leading_zeros_u64(get(a, 0)) as u64)
}

fun leading_zeros_u64(a: u64): u8 {
    if (a == 0) {
        return 64
    };
    let a1 = a & 0xFFFFFFFF;
    let a2 = a >> 32;
    if (a2 == 0) {
        let mut bit: u8 = 32;
        while (bit >= 1) {
            if (((a1 >> (bit - 1)) & 1) != 0) break;
            bit = bit - 1;
        };
        (32 - bit) + 32
    } else {
        let mut bit: u8 = 64;
        while (bit >= 1) {
            if (((a >> (bit - 1)) & 1) != 0) break;
            bit = bit - 1;
        };
        64 - bit
    }
}

fun overflowing_add(a: u64, b: u64): (u64, bool) {
    let a128 = a as u128;
    let b128 = b as u128;
    let r = a128 + b128;
    if (r > U64_MAX) {
        ((r - U64_MAX - 1) as u64, true)
    } else {
        ((a128 + b128) as u64, false)
    }
}

fun overflowing_sub(a: u64, b: u64): (u64, bool) {
    if (a < b) {
        ((U64_MAX as u64) - (b - a) + 1, true)
    } else {
        (a - b, false)
    }
}

fun split_u128(a: u128): (u64, u64) {
    ((a >> 64) as u64, (a & U64_MAX) as u64)
}
