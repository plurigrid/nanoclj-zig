/* Minimal deterministic probe startup. No interrupts or device drivers.
 * Hardware boot/trap/privilege integration remains SDK work.
 */
.section .text.start,"ax",@progbits
.global _start
.type _start,@function
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, _stack_top
    la t0, _data_lma
    la t1, _data_start
    la t2, _data_end
1:
    beq t1, t2, 2f
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 1b
2:
    la t0, _bss_start
    la t1, _bss_end
3:
    beq t0, t1, 4f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 3b
4:
    call nanoclj_smoke
.global nanoclj_smoke_done
nanoclj_smoke_done:
    j nanoclj_smoke_done
.size _start, .-_start
