# Baochip-1x reader/evaluator feasibility

Inspected and tested 2026-10-22 with **Zig 0.16.0**, starting from
[`e0d423cf92809041115ae0036c5c02372382a5b4`](https://github.com/plurigrid/nanoclj-zig/tree/e0d423cf92809041115ae0036c5c02372382a5b4).

**Result:** a small slice of the existing nanoclj reader/evaluator cross-compiles,
links, and passes 13 checks under RV32 instruction emulation without libc or
Linux. This establishes computational feasibility. It does not establish a
working DEF CON 34 badge application, Xous integration, or hardware validation.
No device was accessed or flashed, and no signed firmware was produced.

## What failed first

The existing `embed-min` and `embed-safe` steps compile `src/main.zig` with
`link_libc = true`. A Zig 0.16 RV32IMAC freestanding attempt fails with:

```text
error: unable to provide libc for target 'riscv32-freestanding-none'
```

The `embed-min` run step also depends on the entire default install step, so it
attempts unrelated hosted and WASM builds. The new probe steps deliberately
have independent dependencies.

Replacing only the entry point and setting `link_libc = false` is insufficient.
Calling `core.initCore` from the first probe exposed `std.Thread.spawn` through
`transduction.evalBoundedPevalNative`, libc file/clock calls, POSIX types, the
host page allocator, and the optional Syrup dependency. The unmodified full
interpreter is still not a supported freestanding build.

## Isolated functionality and changes

The probe reuses `Reader`, `Value`, `GC`, `Env`, and `semantics.evalBounded`;
it does not implement a substitute language. `core.initMinimalCore` registers
only `+`, `-`, `*`, `=`, `<`, `count`, and `first`. Existing special forms remain
in the evaluator. The smoke suite exercises integer arithmetic, `let*`, an
immediate `fn*` call, `if`, `def`/`do`, vector reading, quoted lists, and
`loop`/`recur`. Five further checks exercise unbound symbols, fuel exhaustion,
eval-depth exhaustion, incomplete input, and reader out-of-memory.

Three small dependency corrections accompany the registry:

- The `peval` dispatcher honors `enable_peval` and excludes native threads on
  freestanding targets, retaining the existing disabled/WASM result behavior.
- `Env.initSmall` requires a parent and takes its allocator. Its sole caller
  already has a non-null parent; the unused fallback to `page_allocator` was
  enough to instantiate unsupported OS facilities during cross-compilation.
- The existing in-memory diagnostic I/O path also applies to freestanding
  targets. Its buffer is 4 KiB on non-WASM freestanding targets, subject to
  dead-code elimination. Hosted and WASM I/O behavior is retained.

The new RV32 build uses `generic_rv32` plus M/A/C, `freestanding-none`,
`ReleaseSmall`, `single_threaded`, `link_libc = false`, and no unwind tables.
It inherits the `embed_safe` feature options. The ELF has no unresolved symbols,
no dynamic loader, and a soft-float ABI. Zig's compiler runtime supplies software
arithmetic helpers; this is not a hardware floating-point requirement.

The native ReleaseSafe smoke runner links libc for the existing native
diagnostic sink. That runner is a separate host test; the RV32 artifact has no
libc dependency.

## Reproduce without a device

From a checkout of this change, with Zig 0.16.0 on PATH:

```sh
zig build baochip baochip-probe baochip-smoke --summary all
python -m venv .venv-baochip
.venv-baochip/bin/pip install unicorn==2.1.4 pyelftools==0.33
.venv-baochip/bin/python tools/baochip_smoke.py
```

No sibling `zig-syrup` checkout is needed for these steps. Outputs:

- `zig-out/bin/nanoclj-baochip-probe.elf`: linked feasibility ELF with symbols.
- `zig-out/lib/nanoclj-baochip-probe.o`: relocatable probe object, without startup;
  this object alone still requires compiler-runtime helpers when linked.
- `baochip-smoke`: executes the same 13 checks natively with safety checks.

The emulator loads initialized data at its RRAM **load address**, poisons SRAM,
and runs the assembly startup which copies `.data` and clears `.bss`. It maps
only the static SRAM region and reserved stack, leaving an unmapped gap below
the stack. It checks completion, the return code, all 13 checks, unresolved
symbols, and stack pointer limits. Execution has instruction and wall-time
budgets. RRAM becomes read/execute-only before execution; SRAM is non-executable.

This is Unicorn CPU instruction emulation. It does not model Baochip clocks,
RRAM timing, MMU/PMP/access filters, reset state, interrupts, USB, display,
keypad, or boot signature verification. It is not a Baochip RTL simulation.

## Measured footprint

The machine-readable result is [baochip-measurements.json](baochip-measurements.json).
Sizes below refer to the RV32 ReleaseSmall ELF; KiB means 1,024 bytes.

| Component | Bytes | Meaning |
|---|---:|---|
| `.text` | 108,658 | Instructions, startup, and linked compiler-runtime helpers |
| `.rodata` | 28,088 | Constants, tables, and smoke input corpus |
| Initialized `.data` | 160 | Stored in RRAM and copied into SRAM |
| RRAM load span | 136,928 | 133.72 KiB, includes section alignment and data initializer |
| Static SRAM excluding arena | 2,592 | `.data` plus non-arena `.bss`, including report/state |
| Arena reservation | 262,144 | 256 KiB hard allocation capacity, contained in `.bss` |
| Arena measured high water | 16,064 | 15.69 KiB for the whole suite, including transient allocations/alignment |
| Stack reservation | 65,536 | 64 KiB set by linker and ELF stack metadata |
| Stack measured high water | 28,432 | 27.77 KiB, minimum SP observed at each instruction after startup |
| Total reserved SRAM | 330,272 | 322.53 KiB: static + arena + stack, with no double counting |

The symbol/debug-bearing ELF file is about 1.46 MiB on disk. Debug sections,
symbol tables, ELF headers, and file padding are not all loaded code. The load
span above is the useful executable-storage comparison. The ELF's SRAM segment
spans the gap to the top-of-SRAM stack; that gap is address space, not additional
static objects. This physical-address probe ELF must not be used as a Xous app.

On RV32, `Value` is 8 bytes, `Obj` 72, `GC` 88, and `Env` 192. The observed
maximum eval depth is 5. These are measurements for the smoke workload, not
worst-case bounds for programs. The arena does not reclaim arbitrary dead
objects. The suite uses one interpreter lifetime, and repeated calls to the
smoke entry return the cached result.

The measured stack already exceeds the Dabao C SDK's default **8 KiB** stack.
Do not adopt that default for this evaluator. A 64 KiB reservation passed this
suite; deeper recursion or other forms still need separate analysis.

## Memory-map comparison

Primary sources inspected:

- [Baochip hardware README](https://github.com/baochip/baochip-1x/blob/main/README.md)
  and [official RRAM map](https://baochip.github.io/baochip-1x/rram.html).
- Dabao SDK at [`af42146f10f2f72886dd739c4db597d59ce30fc1`](https://github.com/ArmstrongSubero/dabao-sdk/tree/af42146f10f2f72886dd739c4db597d59ce30fc1):
  `bao1x.ld`, `src/runtime/crt0.S`, `tools/sign_and_uf2.py`.
- Xous at [`53d772438a9aeea88972b59b9707a88142b63548`](https://github.com/betrusted-io/xous-core/tree/53d772438a9aeea88972b59b9707a88142b63548):
  `README-baochip.md`, `libs/bao1x-api/src/offsets/{common,dabao,baosec}.rs`,
  `libs/bao1x-api/src/signatures.rs`, and `xtask/src/main.rs`.

| Region | Documented range or budget | Consequence |
|---|---|---|
| SRAM | `0x61000000..0x61200000` (end exclusive), 2 MiB | Probe reserves 15.75%; OS/drivers/UI costs are additional |
| RRAM physical capacity | 4 MiB starting at `0x60000000` | Not all available for executable payload |
| RRAM code/storage ceiling | `0x603DA000` exclusive | Counters, access controls, crypto slots follow |
| Bare-metal header | `0x60060000`, 768 bytes in inspected SDK | Probe entry is `0x60060300`; no signature header is generated |
| Conservative bare-metal payload budget | `0x60060300..0x603DA000`, 3,644,672 bytes | 136,928-byte probe occupies about 3.76% |
| Xous Dabao application payload region | `0x60300000..0x603DA000`, 892,928 bytes | Shared application image budget, not per-process free storage |
| IFRAM | `0x50000000..0x50020000`, 128 KiB | Separate UDMA buffers; not counted as evaluator heap |

**SDK discrepancy:** its inspected linker script uses
`RRAM LENGTH = 0x39A000 - 0x300` from `0x60060300`, ending at `0x603FA000`.
That is 128 KiB beyond the documented storage/code ceiling. This probe uses the
explicit `0x603DA000` ceiling instead. No upstream SDK file was modified.

The Xous `baosec` configuration uses external memory/swap and differs from
Dabao. Neither these layouts nor the entire 2 MiB SRAM budget should be assumed
to be freely available to an application on the user's badge. Board variant,
installed firmware, and actual available mappings remain to be established.

## Runtime integration still required

**Bare metal:** link the pure evaluator into the selected SDK startup; retain
its trap/interrupt and board initialization; explicitly provision the stack
and allocator; connect bounded input/output buffers to UART/USB/keypad/display;
put DMA buffers in IFRAM; verify privilege/access-filter state. Use the
board/bootloader's current signature and UF2 packaging workflow only after the
memory layout and entry contract are reviewed. The probe's startup intentionally
contains no peripheral or trap setup and is not a complete badge runtime.

**Xous:** expose a small C-ABI evaluator interface from a Zig object/static
library and call it from a Rust Xous service/application targeting
`riscv32imac-unknown-xous-elf`. Verify ABI, compiler-runtime helper resolution,
relocation model, application link/load layout, and stack allocation with that
actual toolchain. Allocate memory through the application runtime and exchange
input/output through Xous services/IPC. Use its normal loader/kernel/apps
packaging. Do not transplant the bare-metal physical linker map or `_start`.
No Xous service was linked or executed in this work.

**Interpreter lifecycle:** implement and test reclaim/reset semantics before a
persistent REPL. The full core registry and disk cleanup paths still need
additional host-isolation work. Existing evaluator paths can enter legacy
unmetered evaluation (e.g. macros); `boundedRead` does not comprehensively apply
all resource fields. The selected tests establish their particular error paths,
not adversarial safety for the whole language. A device-facing subset needs an
explicit allowed-form contract and measured parser/evaluator stack bounds.

The smallest next integration artifact is a Xous service or SDK app that calls
this same suite and reports its status through an existing console, with an
explicit stack budget. Its software build can be reviewed before any separate
hardware-validation decision.

## Validation status

| Layer | Result |
|---|---|
| Zig 0.16 RV32IMAC object cross-compilation | Passed |
| Freestanding ELF link, no libc / unresolved symbols | Passed |
| Native ReleaseSafe smoke suite | 13/13 passed |
| Unicorn RV32 instruction emulation, real startup | 13/13 passed |
| Full repository regression suite | Not run; the isolated targets were the validation scope |
| Xous application or SDK firmware packaging | Not performed |
| Baochip RTL/peripheral emulation | Not performed |
| Physical Baochip / DEF CON 34 badge validation | Not performed |
