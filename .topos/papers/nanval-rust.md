# NanVal: Rust NaN-Boxing Crate

**Authors:** Longor1996
**Source:** https://docs.rs/nanval (v0.2.1, MIT/Apache-2.0)

## Contribution

A `no_std`, zero-dependency Rust crate for NaN-tagged 64-bit floating-point values. Exploits the IEEE 754 NaN payload: when a f64 is NaN (`0x7FF8000000000000`), 50 data bits are available. The crate provides:

- **UInts:** 52-bit unsigned integers packed into NaN payloads (sign bit = 0)
- **Cells/Pointers:** 48-bit pointers with 3 tag bits (sign bit = 1, using the fact that x64 only uses lower 48-50 bits for addressing)
- **Float detection:** `is_float` / `is_nanval` discrimination
- Modules: `cell` (tagged pointers), `cons` (bit-mask constants), `raw` (trait for 64-bit values), `uint` (52-bit integers)

Bit layout:
```
s111 1111 1111 1qxx xxxx xxxx xxxx xxxx xxxx xxxx xxxx xxxx xxxx xxxx xxxx xxxx
^               ^\_____________________________________________________________/
Sign            Quiet bit                    50 data bits
```

## Relevance to nanoclj-zig

**Reference implementation -- P1.**

- **Direct comparison:** nanoclj-zig's `value.zig` uses 7 type tags in NaN-boxed 64-bit values. NanVal uses 3 cell-tag bits + sign bit for 8 tag states. Compare designs: nanclj-zig could adopt the sign-bit-as-pointer-flag convention for faster float vs. pointer discrimination.
- **Pointer tagging:** NanVal's approach of using the sign bit to distinguish floats (sign=0, NaN payload) from pointers (sign=1, NaN payload) is simpler than checking multiple tag bits. nanoclj-zig could adopt this for a single-branch type dispatch.
- **52-bit integers:** NanVal supports 52-bit unsigned ints natively. nanoclj-zig currently uses a different encoding; adopting the NanVal convention would give wider integer range without heap allocation.
- **no_std relevance:** NanVal's zero-dependency design validates that NaN-boxing needs no runtime support -- important for nanoclj-zig's goal of a single static binary.
- **Interaction net agents:** Each interaction net agent needs a type tag + data. The NanVal layout (3 tag bits + 48-bit pointer) maps perfectly: tag = agent type, pointer = agent's auxiliary port data.
