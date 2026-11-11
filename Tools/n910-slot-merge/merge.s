.syntax unified
.arm
.section .text
@ Continuation at 0x02002c90 (slot 6-7 handler space). Entered from Sony's slot 2 handler after its
@ fix (strb r0, [r4, #0xa]), still in the undefined-instruction handler with r8-r12, lr pushed.
@ 1. The firmware's Thumb code between the two traps (0x59abc-0x59ac9), in ARM:
    ldrb r0, [r7, #0x14]
    ldrb r2, [r7, #0x13]
    lsls r0, r0, #4
    lsls r2, r2, #28
    lsrs r2, r2, #28
    orrs r0, r0, r2
    strb r0, [r4, #0xb]
@ 2. Sony's slot 3 fix, word for word:
    ldrb r0, [r7, #0x16]
    ldrb r1, [r7, #0x15]
    lsls r0, r0, #4
    lsls r1, r1, #28
    lsrs r1, r1, #28
    orrs r0, r0, r1
    strb r0, [r4, #0xc]
@ 3. Return past the slot 3 trap (0x59abc + 0x10 = 0x59acc), restoring the Thumb state from SPSR.
    pop {r8, r9, r10, r11, r12, lr}
    add lr, lr, #0x10
    movs pc, lr
