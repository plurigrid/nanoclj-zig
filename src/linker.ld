/* SectorClojure multi-sector linker script
 * Stage 2: Zig freestanding Lisp loaded at 0x7E00 (after boot sector)
 * Total budget: ~32KB (64 sectors × 512 bytes)
 * Boot stub (stage 1) loads this from disk sectors 2+ */
ENTRY(_start)

SECTIONS {
    . = 0x7C00;

    .text : {
        KEEP(*(.text.boot))
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

    /DISCARD/ : {
        *(.eh_frame)
        *(.comment)
    }
}
