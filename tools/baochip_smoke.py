#!/usr/bin/env python3
"""Execute a freestanding RV32 ELF in Unicorn, not a Baochip peripheral model.

Requires: pip install unicorn==2.1.4 pyelftools==0.33
Loads initialized data at its RRAM load address so ELF startup must copy it.
SRAM starts poisoned, and an unmapped gap guards the reserved 64 KiB stack.
"""
import argparse
import json
import struct
from pathlib import Path

import unicorn
from unicorn import Uc, UC_ARCH_RISCV, UC_MODE_RISCV32, UC_HOOK_CODE, UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn.riscv_const import UC_RISCV_REG_SP, UC_RISCV_REG_A0, UC_RISCV_REG_PC
from elftools.elf.elffile import ELFFile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", nargs="?", default="zig-out/bin/nanoclj-baochip-probe.elf")
    args = parser.parse_args()
    path = Path(args.elf)
    with path.open("rb") as stream:
        elf = ELFFile(stream)
        assert elf.elfclass == 32 and elf.little_endian and elf["e_machine"] == "EM_RISCV"
        symbols = {s.name: s["st_value"] for s in elf.get_section_by_name(".symtab").iter_symbols()}
        undefined = [s.name for s in elf.get_section_by_name(".symtab").iter_symbols() if s.name and s["st_shndx"] == "SHN_UNDEF"]
        assert not undefined, f"unresolved symbols: {undefined}"
        sections = {s.name: s["sh_size"] for s in elf.iter_sections()}
        segments = [{"vaddr": s["p_vaddr"], "paddr": s["p_paddr"], "filesz": s["p_filesz"], "memsz": s["p_memsz"], "data": s.data()} for s in elf.iter_segments() if s["p_type"] == "PT_LOAD"]
        entry = elf["e_entry"]
    uc = Uc(UC_ARCH_RISCV, UC_MODE_RISCV32)
    page = 4096
    floor = lambda n: n & -page
    ceil = lambda n: (n + page - 1) & -page
    rram_start = 0x60060300
    rram_end = max(s["paddr"] + s["filesz"] for s in segments if s["filesz"])
    assert rram_end <= 0x603DA000
    uc.mem_map(floor(rram_start), ceil(rram_end) - floor(rram_start), UC_PROT_READ | UC_PROT_WRITE | UC_PROT_EXEC)
    static_start = 0x61000000
    static_end = symbols["_bss_end"]
    stack_low, stack_top = symbols["_stack_bottom"], symbols["_stack_top"]
    assert ceil(static_end) < stack_low and stack_top == 0x61200000
    uc.mem_map(static_start, ceil(static_end) - static_start, UC_PROT_READ | UC_PROT_WRITE)
    uc.mem_write(static_start, b"\xa5" * (ceil(static_end) - static_start))
    uc.mem_map(stack_low, stack_top - stack_low, UC_PROT_READ | UC_PROT_WRITE)
    uc.mem_write(stack_low, b"\xa5" * (stack_top - stack_low))
    for segment in segments:
        if segment["filesz"]:
            uc.mem_write(segment["paddr"], segment["data"])
    uc.mem_protect(floor(rram_start), ceil(rram_end) - floor(rram_start), UC_PROT_READ | UC_PROT_EXEC)
    uc.reg_write(UC_RISCV_REG_SP, stack_top)
    minimum_sp = stack_top
    instructions = 0
    track_stack = False

    def trace(machine, _address, _size, _data):
        nonlocal minimum_sp, instructions, track_stack
        instructions += 1
        if _address == symbols["nanoclj_smoke"]:
            track_stack = True
        if not track_stack:
            return  # Startup materializes SP with AUIPC then ADDI.
        sp = machine.reg_read(UC_RISCV_REG_SP)
        if not stack_low <= sp <= stack_top:
            raise RuntimeError(f"stack outside reservation: {sp:#x}")
        minimum_sp = min(minimum_sp, sp)

    uc.hook_add(UC_HOOK_CODE, trace)
    uc.emu_start(entry, symbols["nanoclj_smoke_done"], timeout=30_000_000, count=10_000_000)
    assert uc.reg_read(UC_RISCV_REG_PC) == symbols["nanoclj_smoke_done"], "instruction/time budget exhausted"
    fields = ("status", "passed", "heap_peak", "heap_used", "max_eval_depth", "value_bytes", "object_bytes", "gc_bytes", "env_bytes")
    report = dict(zip(fields, struct.unpack("<9I", uc.mem_read(symbols["nanoclj_probe_report"], 36))))
    assert uc.reg_read(UC_RISCV_REG_A0) == report["status"] == 0, report
    assert report["passed"] == 13, report
    heap_reserved = 256 * 1024
    report.update({
        "validation": "Unicorn RV32 instruction emulation; no Baochip peripherals or hardware",
        "unicorn_version": unicorn.__version__,
        "elf_file_bytes": path.stat().st_size,
        "text_bytes": sections.get(".text", 0),
        "rodata_bytes": sections.get(".rodata", 0),
        "data_bytes": sections.get(".data", 0),
        "bss_including_heap_bytes": sections.get(".bss", 0),
        "rram_load_span_bytes": rram_end - rram_start,
        "heap_reserved_bytes": heap_reserved,
        "static_excluding_heap_bytes": static_end - static_start - heap_reserved,
        "stack_reserved_bytes": stack_top - stack_low,
        "stack_peak_bytes": stack_top - minimum_sp,
        "total_sram_reserved_bytes": static_end - static_start + stack_top - stack_low,
        "instructions_including_startup": instructions,
    })
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
