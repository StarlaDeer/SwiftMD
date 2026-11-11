# MZ-N910 (S1.600) firmware patch slots

Found 2026-11-11 from the N910's firmware and RAM dumps (not in the repo: Sony's code).

The firmware loads its own fixes into patch slots at start-up. Each patched spot holds a Thumb
`udf` trap; the undefined-instruction handler (ROM 0x468) compares the trap address with each
slot's address register (0x03802004 + 0x10 * slot) and jumps to that slot's handler in RAM at
0x02002BA0 + 0x28 * slot.

| Slot | Patched at | What the fix does | Used while backing up? |
|---|---|---|---|
| 0 | 0x18924 | Skips a call in a routine working on mechanism/disc state (RAM 0x020002BC, next to the disc spin flag) | Probably: disc handling |
| 1 | 0x6E5DC | In the routine that finds which track a disc position belongs to (track ranges via 0x6D198), adds a corrected current-track lookup (0x707C8) | Yes: seeking |
| 2 | 0x59AB8 | Packs byte 0xA of a per-disc memory record correctly | Only if a per-disc record is saved |
| 3 | 0x59AC8 | Same for byte 0xC | Only if a per-disc record is saved |
| 4 | 0xBB14 | Not a trap: replaces two instructions so 0xBB0C stores 0x4A to 0x0200015E | No: runs once, at power-on |
| 5 | 0xC4 | HFEC, Sony's fault-handler fix | Always keep |

Slots 2 and 3 sit in 0x599FC, which packs a per-disc settings record. Its caller (0x7A0DC) keeps
a 20-entry table keyed by a 16-bit disc ID, replacing the least recently used, and 0x56E40 then
queues an EEPROM write at 0x930 + 64 * entry. So without those fixes, a per-disc record saved at
that moment would have two wrongly packed bytes in the EEPROM.

Correction (2026-11-11): slot 4 is also Sony's. An early read showed it switched off holding
0xE69C, but that was a leftover from one of SwiftMD's own backups made before SwiftMD checked
slot switches (it had overwritten Sony's slot 4 fix until the player reset). After a clean start
only slots 6 and 7 are free.

Bulk download needs four free slots; the N910 has two (6, 7). Merging slots 2 and 3 frees one;
a fourth would need another of Sony's slots (slot 4 is the candidate). netmd-exploits would take slot
3 (and ElectronWMD does). SwiftMD refuses instead.

## Slot 4 runs only at power-on

0xBB0C is reachable only this way, and every step has exactly one caller and no pointer to it:
reset handler 0x3C (clears RAM, then `bl 0x8B110` at 0xA4) -> ARM-to-Thumb stub 0x8B110 ->
0x7BFD0 -> 0x5A0E0 (a straight run of ~30 set-up calls that ends by starting the tasks and the
scheduler) -> 0x9F94 -> 0xBB0C. The value it stores (0x4A at 0x0200015E) is in the RAM dump.
Since the fix works on every normal start, the firmware loads its patches before this point, so
a power-on always reloads slot 4 before 0xBB14 runs. Lending slot 4 out after start-up is safe.

So for bulk on the N910: slots 6 and 7 are free, slot 3 is freed by merging it into slot 2, and
slot 4 is lent out. SwiftMD checks all of it first and puts both back afterwards.
