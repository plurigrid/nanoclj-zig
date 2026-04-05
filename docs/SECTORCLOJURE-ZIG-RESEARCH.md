# SectorClojure: Freestanding Zig BIOS Boot Research

## Executive Summary

Building a freestanding Zig binary that boots from BIOS like SectorLisp is **feasible but with critical constraints**. A pure 512-byte boot sector Lisp in Zig is **not realistic** — Zig/LLVM cannot generate true 16-bit x86 code, and compiler overhead makes sub-1KB binaries impractical. The recommended approach is a **hybrid**: a tiny hand-written assembly boot stub (≤128 bytes) that loads a Zig-compiled 32-bit freestanding kernel (~2-8KB) from subsequent disk sectors.

---

## 1. Zig Freestanding x86 Target

### Target Triple

```
.cpu_arch = .x86,
.os_tag = .freestanding,
.abi = .none,
```

This tells Zig/LLVM to emit **32-bit x86** code with **no OS** and **no ABI**. There is no true `i8086` or 16-bit real mode target in LLVM/Zig.

### Critical Limitation: No True 16-bit x86 Support

**Zig/LLVM cannot generate real 16-bit x86 code.** Per [ziglang/zig#7469](https://github.com/ziglang/zig/issues/7469):

- Zig has a `code16` ABI that emits `.code16gcc` directives — this produces 32-bit code with 16-bit operand size prefixes
- The output uses 32-bit registers (eax, ebx...) with override prefixes, not native 16-bit registers
- This creates **bloated** code: every 32-bit instruction gets a 0x66 prefix byte
- True i8086 targets (segmentation, far pointers, 16-bit-only registers) are a pre-1.0 proposal with no implementation

Per Ziggit forum discussion (April 2025):
> "16-bit x86 has never been a target of LLVM or GCC. The most you'll get is the equivalent of the `.code16gcc` GNU AS directive."

### Disabling Standard Library

For freestanding, Zig automatically disables std when `os_tag = .freestanding`. You must provide:

```zig
// Panic handler (required)
pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    while (true) { asm volatile ("hlt"); }
}
```

### Entry Point

For a boot sector at 0x7C00, use a `naked` function with inline assembly:

```zig
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ .code16
        \\ cli
        \\ xor %%ax, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%ss
        \\ mov $0x7C00, %%sp
        \\ sti
        \\ jmp main_entry
    );
}
```

### Emitting a Flat Binary

Zig can produce raw binaries via `addObjCopy`:

```zig
const bin = kernel.addObjCopy(.{ .format = .bin });
```

Or via `zig objcopy -O binary kernel.elf kernel.bin` post-build.

**Known issue**: [`zig objcopy -O binary` may produce zero-padding at the start](https://github.com/ziglang/zig/issues/25653) (open bug as of Oct 2025). Workaround: use GNU objcopy or verify output manually.

---

## 2. SectorLisp Techniques (for Reuse/Adaptation)

### Memory Model — NULL = 0x7C00

SectorLisp's most brilliant trick: **redefine NULL to be the boot address**.

```
Memory Layout (SectorLisp):
  0x0000 - 0x7BFF : Cons cells (negative memory, grows UP from 0x0000)
  0x7C00 - 0x7DFF : Boot sector code (512 bytes) — this IS the atom table
  0x7E00 - 0xFFFF : Atom interning (positive memory, grows outward)

  NULL = 0x7C00
  Positive offsets from NULL = atoms (interned strings)
  Negative offsets from NULL = cons cells (pairs)
```

The program's own machine code bytes serve double duty as the initial atom table entries. `NIL` is literally the string at address 0x7C00, and the first bytes (`N`, `I`, `L`, `\0`) decode as harmless x86 instructions.

### %fs Segment Register as Monotonic Allocator

SectorLisp uses the `%fs` segment register as a cons cell allocator pointer:
- `%fs` starts at bottom of memory
- Each `CONS` call increments it
- No free — allocation is monotonic

### ABC Garbage Collector (40 bytes of x86)

The ABC GC is remarkable for its simplicity:

```
A = cons stack pointer BEFORE eval
B = cons stack pointer AFTER eval  
C = position after copying eval result down

Algorithm:
1. Save cons pointer as A
2. Run Eval (allocates cons cells, pointer moves to B)
3. Copy result recursively (pointer moves to C)
4. Memmove B..C range up to A
5. New cons pointer = A - (B - C)
```

This gives **perfect heap defragmentation** with zero overhead, because LISP data structures are acyclic (no cycles possible).

### Character I/O via BIOS Interrupts

```asm
; Print character (INT 10h, AH=0Eh — teletype output)
mov ah, 0x0E
mov al, <char>
int 0x10

; Read keyboard (INT 16h, AH=00h — wait for keypress)
xor ah, ah
int 0x16
; AL = ASCII character
```

### Overlapping Functions (extreme size optimization)

SectorLisp uses x86 variable-length encoding to make functions **overlap** — the tail bytes of one function are reinterpreted as the start of another. Example: `Assoc`, `Cadr`, `Cdr`, `Car` share overlapping byte sequences.

---

## 3. Zig-Specific Challenges

### Code Size

| Implementation | Size | Notes |
|---|---|---|
| SectorLisp (hand-tuned x86 asm) | 436 bytes | 223 lines of assembly |
| SectorC (hand-tuned x86 asm) | 512 bytes | C compiler in boot sector |
| SectorForth (hand-tuned asm) | ~512 bytes | Forth in boot sector |
| Zig minimal kernel (32-bit, Multiboot) | ~4-8 KB | With VGA, no BIOS |
| Zig `ReleaseSmall` minimal program | ~44 KB | With std, stripped |
| Zig freestanding minimal (no std) | ~200-500 bytes | Possible with heavy inline asm |

### Why Zig Can't Match Hand-Tuned Assembly

1. **No overlapping functions** — compiler emits standard function prologues/epilogues
2. **Register allocation overhead** — compiler doesn't know about segment registers
3. **No `.code16` native support** — 32-bit code with prefixes is ~1.5x larger
4. **Alignment padding** — compiler may insert NOPs for alignment
5. **Error handling** — `try`/`catch` adds branching code (must avoid entirely)
6. **No allocator** — must use raw pointer arithmetic via `@intToPtr`

### Inline Assembly for BIOS Interrupts

```zig
fn bios_print_char(c: u8) void {
    asm volatile (
        \\ .code16
        \\ mov $0x0E, %%ah
        \\ int $0x10
        :
        : [al] "{al}" (c),
        : "ah"
    );
}

fn bios_read_char() u8 {
    return asm volatile (
        \\ .code16
        \\ xor %%ah, %%ah
        \\ int $0x16
        : [ret] "={al}" (-> u8),
        :
        : "ah"
    );
}
```

**Warning**: Using `.code16` in inline asm within a 32-bit Zig compilation is fragile. The LLVM backend may not handle mixed 16/32-bit code correctly ([codeberg ziglang/zig#31022](https://codeberg.org/ziglang/zig/issues/31022)).

### Raw Memory Arithmetic (No Allocator)

```zig
const NULL: usize = 0x7C00;

fn cons(car: i16, cdr: i16) i16 {
    const ptr: *volatile i16 = @ptrFromInt(cons_ptr);
    ptr[0] = car;
    ptr[1] = cdr;
    const result: i16 = @intCast(@as(isize, cons_ptr) - @as(isize, NULL));
    cons_ptr -= 4;
    return result;
}

fn car(x: i16) i16 {
    const addr = NULL +% @as(usize, @bitCast(x));
    return @as(*volatile i16, @ptrFromInt(addr)).*;
}
```

---

## 4. Realistic Size Estimates

### Option A: Pure 512-byte Boot Sector (Mostly Assembly)

**Feasibility: Very Difficult, borderline impossible with Zig**

- Write the entire boot sector in inline assembly within a Zig file
- Zig serves as assembler/linker only — no Zig language features used
- At that point, you're just writing assembly with extra steps
- **Better to use NASM/GAS directly** for this approach

Estimated Zig overhead for a naked function with pure inline asm: ~0 bytes (possible but pointless — it's just assembly).

### Option B: Two-Stage Bootloader (~4-8 KB total)

**Feasibility: Realistic and recommended**

```
Stage 1 (512 bytes, hand-written asm or Zig inline asm):
  - Set up segments, stack
  - Load Stage 2 from disk sectors 2-N via BIOS INT 13h
  - Jump to Stage 2

Stage 2 (2-8 KB, Zig freestanding 32-bit):
  - Switch to protected mode (32-bit)
  - Implement Lisp eval/apply/read/print
  - ABC garbage collector
  - Console I/O via VGA memory (0xB8000) or serial port
```

Size breakdown for Stage 2 Lisp:
| Component | Estimated Size |
|---|---|
| Eval + Apply | 400-800 bytes |
| Read (parser) | 300-500 bytes |
| Print | 200-300 bytes |
| Cons/Car/Cdr | 100-150 bytes |
| ABC GC | 150-300 bytes |
| I/O (VGA or serial) | 100-200 bytes |
| Atom interning | 200-400 bytes |
| Boot/init code | 100-200 bytes |
| **Total** | **~1.5 - 3 KB** |

### Option C: Hybrid — Asm Boot Stub + Zig in Real Mode

**Feasibility: Experimental**

- 128-byte asm stub loads remaining sectors, stays in real mode
- Zig code compiled with `.code16gcc` equivalent (32-bit code with 16-bit prefixes)
- Can use BIOS interrupts via inline asm
- Code is ~1.5x larger than native 16-bit due to operand size prefixes
- Estimated total: ~2-4 KB

---

## 5. Build System Configuration

### build.zig for Freestanding x86 Boot Sector

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // ── Freestanding x86 target ──────────────────────────────────
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
        // Disable all SIMD — not available in boot environment
        .cpu_features_sub = std.Target.x86.featureSet(&.{
            .sse, .sse2, .avx, .avx2, .mmx,
        }),
        // Enable soft float since no FPU setup
        .cpu_features_add = std.Target.x86.featureSet(&.{
            .soft_float,
        }),
    });

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .red_zone = false, // Interrupts would corrupt the red zone
        .strip = true,     // Remove debug info for size
        .unwind_tables = .none, // No unwinding in freestanding
    });

    const kernel = b.addExecutable(.{
        .name = "sector.elf",
        .root_module = kernel_mod,
    });

    // Use custom linker script for boot sector layout
    kernel.setLinkerScript(b.path("src/linker.ld"));

    b.installArtifact(kernel);

    // ── Convert ELF to raw binary ────────────────────────────────
    const bin = kernel.addObjCopy(.{
        .format = .bin,
    });
    const bin_install = b.addInstallBinFile(bin.getOutput(), "sector.bin");
    b.getInstallStep().dependOn(&bin_install.step);

    // ── Create floppy disk image ─────────────────────────────────
    const disk_cmd = b.addSystemCommand(&.{
        "dd", "if=/dev/zero", "of=disk.img", "bs=512", "count=2880",
    });
    const copy_cmd = b.addSystemCommand(&.{
        "dd", "conv=notrunc", "if=zig-out/bin/sector.bin", "of=disk.img",
    });
    copy_cmd.step.dependOn(&disk_cmd.step);
    copy_cmd.step.dependOn(&bin_install.step);

    const disk_step = b.step("disk", "Create floppy disk image");
    disk_step.dependOn(&copy_cmd.step);

    // ── QEMU run step ────────────────────────────────────────────
    const qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-i386",
        "-fda", "disk.img",
        "-nographic",
        "-serial", "mon:stdio",
    });
    qemu_cmd.step.dependOn(disk_step);

    const run_step = b.step("run", "Boot in QEMU");
    run_step.dependOn(&qemu_cmd.step);
}
```

### Linker Script (src/linker.ld)

```ld
/* Boot sector linker script — load at 0x7C00 */
ENTRY(_start)

SECTIONS {
    /* BIOS loads boot sector to 0x7C00 */
    . = 0x7C00;

    .text : {
        KEEP(*(.text.boot))   /* Boot entry point first */
        *(.text)
    }

    .rodata : {
        *(.rodata)
    }

    .data : {
        *(.data)
    }

    .bss : {
        *(.bss)
    }

    /* Pad to 510 bytes and add boot signature */
    . = 0x7C00 + 510;
    .sig : {
        SHORT(0xAA55)
    }
}
```

---

## 6. Template: Boot Sector Entry Point in Zig

```zig
// src/main.zig — SectorClojure boot sector template

// No standard library in freestanding
const builtin = @import("builtin");

// ── Memory layout ────────────────────────────────────────────────
// NULL = 0x7C00 (boot address, same as SectorLisp)
// Atoms: 0x7C00+ (positive offsets = interned symbols)
// Cons:  0x0000..0x7BFF (negative offsets = cons cells, grow upward)
const NULL: usize = 0x7C00;

var cons_top: usize = 0x7BFC; // Cons allocation pointer (grows DOWN toward 0)

// ── Boot entry point ─────────────────────────────────────────────
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        // Set up real-mode segments and stack
        \\ cli
        \\ xor %%ax, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%ss
        \\ mov $0x7C00, %%sp
        \\ sti
        \\ call %[main:P]
        \\ hlt
        :
        : [main] "X" (&main),
    );
}

// ── BIOS I/O ─────────────────────────────────────────────────────
fn putchar(c: u8) void {
    asm volatile (
        \\ mov $0x0E, %%ah
        \\ int $0x10
        :
        : [al] "{al}" (c),
        : "ah"
    );
}

fn getchar() u8 {
    return asm volatile (
        \\ xor %%ah, %%ah
        \\ int $0x16
        : [ret] "={al}" (-> u8),
        :
        : "ah"
    );
}

// ── Cons Cell Operations ─────────────────────────────────────────
fn cons(a: i16, d: i16) i16 {
    const ptr: [*]volatile i16 = @ptrFromInt(cons_top);
    ptr[0] = a;  // CAR
    ptr[1] = d;  // CDR
    const result: i16 = @intCast(@as(isize, @intCast(cons_top)) - @as(isize, @intCast(NULL)));
    cons_top -= 4;
    return result;
}

fn car(x: i16) i16 {
    if (x >= 0) return x; // atoms are their own car
    const addr: usize = @intCast(@as(isize, @intCast(NULL)) + @as(isize, x));
    return @as(*volatile i16, @ptrFromInt(addr)).*;
}

fn cdr(x: i16) i16 {
    const addr: usize = @intCast(@as(isize, @intCast(NULL)) + @as(isize, x) + 2);
    return @as(*volatile i16, @ptrFromInt(addr)).*;
}

// ── Panic handler (required for freestanding) ────────────────────
pub fn panic(_: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

// ── Main REPL ────────────────────────────────────────────────────
fn main() callconv(.c) noreturn {
    // Print banner
    const banner = "SectorClojure v0.1\r\n> ";
    for (banner) |c| putchar(c);

    // REPL loop placeholder
    while (true) {
        const c = getchar();
        putchar(c); // echo
        if (c == '\r') {
            putchar('\n');
            putchar('>');
            putchar(' ');
        }
    }
}
```

---

## 7. Memory Layout Diagram

```
┌──────────────────────────────────────────────────────────┐
│  x86 Real Mode Memory Map (64KB segment)                 │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  0xFFFF ┌────────────────────────┐                       │
│         │    Stack (grows down)  │ ← SP starts at 0x7C00 │
│         │                       │                        │
│  0x7E00 ├────────────────────────┤                       │
│         │  BOOT SECTOR (512B)   │ ← BIOS loads here     │
│         │  = Atom table (NULL)  │    NULL = 0x7C00       │
│  0x7C00 ├────────────────────────┤                       │
│         │                       │                        │
│         │  Cons cells            │ ← Grow DOWN from      │
│         │  (negative offsets)    │   0x7BFC toward 0x0500│
│         │                       │                        │
│  0x0500 ├────────────────────────┤                       │
│         │  BIOS Data Area       │                        │
│  0x0000 └────────────────────────┘                       │
│                                                          │
│  After multi-sector load (Option B):                     │
│  0x8000 ┌────────────────────────┐                       │
│         │  Stage 2 Zig code     │ ← Loaded from disk    │
│         │  (2-8 KB)             │   sectors 2+           │
│  0x7E00 └────────────────────────┘                       │
│                                                          │
│  Atom interning (SectorLisp style):                      │
│  Offset from NULL:                                       │
│   +0: "NIL\0"  (bytes from boot sector code)             │
│   +4: "T\0"                                              │
│   +6: "QUOTE\0"                                          │
│  +12: "COND\0"                                           │
│  ... etc                                                 │
│                                                          │
│  Cons cells (SectorLisp style):                          │
│  Offset from NULL:                                       │
│   -4: first cons cell  [CAR, CDR]                        │
│   -8: second cons cell [CAR, CDR]                        │
│  ... grows toward 0x0000                                 │
└──────────────────────────────────────────────────────────┘
```

---

## 8. QEMU Test Commands

```bash
# Build (assuming build.zig is configured as above)
zig build -Doptimize=ReleaseSmall

# Test with QEMU — floppy disk image
qemu-system-i386 -fda disk.img -nographic

# Test with QEMU — direct kernel boot (if using Multiboot)
qemu-system-i386 -kernel zig-out/bin/sector.elf

# Test with QEMU — serial output for debugging
qemu-system-i386 -fda disk.img -serial stdio -monitor none

# Debug with QEMU + GDB
qemu-system-i386 -fda disk.img -s -S -nographic &
gdb -ex "target remote :1234" -ex "set architecture i8086" -ex "break *0x7c00"

# Alternative: use Blinkenlights (SectorLisp's emulator)
blinkenlights -rt sector.bin
```

---

## 9. Existing Zig Bare-Metal / OS Projects

| Project | URL | Notes |
|---|---|---|
| zig-minimal-kernel-x86 | [github.com/lopespm/zig-minimal-kernel-x86](https://github.com/lopespm/zig-minimal-kernel-x86) | 225★, Multiboot, 32-bit, zero asm files, Feb 2026 |
| Pluto (ZystemOS) | [github.com/ZystemOS/pluto](https://github.com/ZystemOS/pluto) | 720★, x86 kernel in Zig, uses GRUB |
| zig_os (Codeberg) | [codeberg.org/sfiedler/zig_os](https://codeberg.org/sfiedler/zig_os) | 28★, UEFI bootloader + kernel, educational |
| OSDev Zig Bare Bones | [wiki.osdev.org/Zig_Bare_Bones](https://wiki.osdev.org/Zig_Bare_Bones) | Tutorial, Multiboot, GRUB-dependent |
| dos.zig | [github.com/jayschwa/dos.zig](https://github.com/jayschwa/dos.zig) | DOS/retro Zig research project |

**Key finding**: All existing Zig OS/bare-metal projects use either Multiboot (GRUB) or UEFI. **None boot directly from BIOS without an external bootloader.** A Zig BIOS boot sector would be novel.

---

## 10. Realistic Assessment: Can We Fit Lisp Eval in 512 Bytes of Zig?

### Verdict: **No, not with Zig language features.**

**Why:**
1. **No true 16-bit codegen**: Zig/LLVM produces 32-bit code with 16-bit operand prefixes. Every instruction is 1-2 bytes larger than native 16-bit.
2. **No overlapping functions**: SectorLisp's most powerful size optimization (saving ~50-100 bytes) is impossible with a compiler.
3. **Function call overhead**: Even `callconv(.naked)` functions have constraints. Zig won't share `ret` opcodes between functions.
4. **Compiler can't exploit x86 encoding tricks**: Things like using `scasw` to increment DI by 2 (used as CDR), using `lodsw` for CAR, etc.
5. **Minimum overhead**: Even a trivial Zig freestanding program with inline asm compiles to ~100-200 bytes before any logic.

### What IS Feasible:

| Approach | Size | Practicality |
|---|---|---|
| **A) 512B boot sector in pure inline asm** | 436-512 bytes | Possible but just assembly with Zig as assembler |
| **B) Multi-sector Zig Lisp** | 2-8 KB | ✅ **Recommended** — real Zig code, full Lisp |
| **C) Zig boot stub + Zig Lisp** | 4-8 KB | ✅ Clean separation, all Zig |
| **D) Asm boot stub + Zig 32-bit Lisp** | 2-4 KB | ✅ Smallest viable Zig Lisp |

### Recommended Architecture for SectorClojure:

```
┌─────────────────────────────────────────────┐
│  Sector 1 (512 bytes) — Assembly boot stub  │
│  • Set up real mode segments                │
│  • Load sectors 2-8 via INT 13h             │
│  • Switch to 32-bit protected mode          │
│  • Jump to Zig entry point at 0x8000        │
├─────────────────────────────────────────────┤
│  Sectors 2-8 (~3.5KB) — Zig freestanding   │
│  • Eval / Apply / Evcon / Evlis             │
│  • Read (S-expression parser)               │
│  • Print                                    │
│  • Cons / Car / Cdr                         │
│  • ABC Garbage Collector                    │
│  • VGA text-mode console (0xB8000)          │
│  • Atom interning                           │
│  • REPL loop                                │
└─────────────────────────────────────────────┘
```

---

## 11. Key References

1. **SectorLisp v2** — https://justine.lol/sectorlisp2/ — 436 bytes, Lisp + GC in boot sector
2. **SectorLisp source** — https://github.com/jart/sectorlisp — Assembly listing
3. **SectorC** — https://github.com/xorvoid/sectorc — C compiler in 512 bytes
4. **Zig Bare Bones (OSDev)** — https://wiki.osdev.org/Zig_Bare_Bones
5. **zig-minimal-kernel-x86** — https://github.com/lopespm/zig-minimal-kernel-x86
6. **Zig 16-bit x86 issue** — https://github.com/ziglang/zig/issues/7469
7. **Zig freestanding support** — https://zread.ai/ziglang/zig/28-bare-metal-and-freestanding-support
8. **Zig objcopy for raw binary** — https://github.com/ziglang/zig/issues/2826

---

## 12. Open Questions / Blockers

1. **16-bit inline asm reliability**: Zig's LLVM backend may miscompile `.code16` inline asm blocks mixed with 32-bit code. Needs empirical testing.
2. **objcopy zero-padding bug**: `zig objcopy -O binary` may add unwanted zeros. May need GNU objcopy as fallback.
3. **Protected mode switch**: If using 32-bit Zig code, the boot stub must set up a GDT and switch to protected mode — this adds ~80-100 bytes of assembly.
4. **VGA vs Serial**: In protected mode, BIOS interrupts are unavailable. Must use VGA memory-mapped I/O (0xB8000) or serial port I/O for console.
5. **Cons cell representation**: Need to decide between SectorLisp's signed-offset-from-NULL scheme vs. direct pointers (32-bit mode gives us flat address space).
