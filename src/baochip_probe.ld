/* Feasibility ELF, not signed badge firmware. See docs/baochip-feasibility.md.
 * Dabao bare-metal entry follows a 0x300-byte header at 0x60060000.
 * Stop at the documented code-region end, before security/control regions.
 */
ENTRY(_start)
MEMORY {
    RRAM (rx) : ORIGIN = 0x60060300, LENGTH = 0x603DA000 - 0x60060300
    SRAM (rw) : ORIGIN = 0x61000000, LENGTH = 0x200000
}
SECTIONS {
    .text : ALIGN(16) { KEEP(*(.text.start)) *(.text .text.*) } > RRAM
    .rodata : ALIGN(16) { *(.rodata .rodata.*) *(.srodata .srodata.*) } > RRAM
    .data : ALIGN(16) {
        _data_start = .;
        *(.data .data.*) *(.sdata .sdata.*)
        . = ALIGN(16); _data_end = .;
    } > SRAM AT > RRAM
    _data_lma = LOADADDR(.data);
    .bss (NOLOAD) : ALIGN(16) {
        _bss_start = .;
        *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
        . = ALIGN(16); _bss_end = .;
    } > SRAM
    __global_pointer$ = _data_start + 0x800;
    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
    _stack_bottom = _stack_top - 0x10000;
    .stack _stack_bottom (NOLOAD) : { . += 0x10000; } > SRAM
    ASSERT(_bss_end <= _stack_bottom, "static memory collides with reserved stack")
    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
