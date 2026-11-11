# Milestone 4: factory mode, hardware test plan

Factory mode reads and writes the player's memory and loads firmware patches. netmd-exploits warns
that a crash while in factory mode can corrupt the EEPROM's NetMD block, after which the player refuses
NetMD uploads. Its safety patch for this exists only for firmware S1.000, S1.400, S1.500 and S1.600.

Rules:
- Every step runs on the **MZ-N910 first** (it already can't record long tracks). The MZ-N707 only
  follows once a step has behaved on the N910.
- Ask before each step that writes anything to a player.
- Keep the player on a fresh battery or AC power; don't unplug mid-step.
- Run with `SWIFTMD_TRACE=1` and keep the trace.

## Step 1: identify (writes nothing)

```bash
SWIFTMD_TRACE=1 swift run netmdcli --identify
```

Authenticates to the factory command set and reads the firmware code (e.g. `S1.600`, `R1.400`).
Record each player's code. It decides everything below:

| Firmware | Safety patch (HFEC) | ATRAC download | TOC editing |
|---|---|---|---|
| S1.000, S1.400–S1.600 | yes | supported | supported |
| S1.100–S1.300 | **no** | supported | supported |
| R1.000–R1.400 | **no** | no-RAM method only | supported |

If a player's code isn't in netmd-exploits' tables, stop there for that player.

## Step 2: read-only factory reads (writes nothing)

On the N910: read the 16 patch slots (`readPatch`) and one UTOC sector from the disc cache. Compare
with netmd-js doing the same reads (`Tools/record-netmdjs-transcripts.js` approach, against hardware).

## Step 3 onward

Decided after steps 1–2, from the firmware codes and the exploit port's progress.

## Step 3: firmware dump (N910 first)

`swift run netmdcli --dump-firmware <dir>` ports ElectronWMD's firmware dump:

1. On S firmware with a known safety patch (S1.000, S1.400, S1.500, S1.600), it reads every patch
   slot and loads Sony's HFEC fix into a free one if it isn't there. Patch slots clear on reset.
   On Type-R firmware, nothing is known, so it writes nothing here.
2. It reads RAM with ordinary factory reads.
3. It writes 16 zero bytes into the factory read-range table in RAM, which lifts the read limit.
4. It reads the flash ROM, then closes the range.

Nothing is written to the EEPROM or the disc. Unplug the player afterwards so it resets.
Checked byte for byte against netmd-exploits in `FactoryParityTests`.

Goal: compare the S1.600 ROM with a Type-R ROM to find where Sony's HFEC fix would go on Type-R.

### Results (2026-11-10)

- MZ-N910, S1.600: HFEC was already in patch slot 5 (applied at the factory), so the dump wrote
  only the RAM table. Fault vectors (SWI, prefetch abort, data abort) go to 0xC4; HFEC there is
  `B 0x3C`, a jump to the reset entry.
- MZ-N505, R1.400: all 4 patch slots empty (`netmdcli --patches`, read-only). Fault vectors go to
  0xC0, which in ROM is already `B 0x3C`. Type-R firmware has Sony's fix built in, which is why
  netmd-exploits lists no HFEC for it.
- MZ-N707, R1.300: same as R1.400, fault vectors go to 0xC0 = `B 0x3C` in ROM. Slots 0-2 hold
  Sony boot-time fixes (Thumb `0xDE00` traps at 0x1d310, 0x1d348, 0x1d368) handled by the
  undefined-instruction dispatcher at 0xC8; slot 3 is free.

## Step 4: disc backup (ATRAC download), N910 first

`swift run netmdcli --download-track <n> [dir]` ports netmd-exploits' ATRAC recovery with the
CachedSectorNoRamControlDownload reader (works on every Type-S and Type-R):

1. Safety patches as in step 3, then one patch makes a USB command run SwiftMD's code.
2. The player seeks to the track and fills its anti-skip buffer; SwiftMD copies the cached sectors
   out of it, and re-seeks when the buffer runs out.
3. The patch is removed afterwards. The disc is only read.

Output: `.aea` for SP (ATRAC1), `.wav` (ATRAC3 in WAV) for LP2 / LP4. Checked against netmd-exploits
in `DownloadParityTests` (SP on S1.600 and LP2 on R1.400, both with a re-seek).
Use a disc that doesn't matter and a short track for the first run.

### Results (2026-11-10)

- Write-protected LP2 disc, track 1 (2:53). MZ-N505 (R1.400): 268 s, decodes with 0 errors.
  MZ-N910 (S1.600): 196 s, byte-identical to the N505 copy
  (sha256 428dc563…efd81d07).
- Type-S firmware copies its buffer in 8-byte units: netmd-exploits' 420-byte NoRam pieces that
  start 4 bytes off an 8-byte boundary come back with every other word shifted. SwiftMD reads
  416-byte pieces on Type-S. (ElectronWMD normally uses the bulk method on Type-S instead.)
- `--read-cache <track> <count> <dir>` saves raw buffered sectors for comparisons like this.

## Next player tests (written 2026-11-11, nothing below has run on a player yet)

Unplug each player for a moment before starting, so its patch slots are clear. Ordered from
safest to riskiest; stop at any surprise.

1. **Read the TOC** (read-only), N910 then N707:
   `swift run netmdcli --toc`
   Expect track fragments, titles, and "written ... by Sony MZ-N910" style lines.
2. **Bulk backup** (N910 only, reads the disc): same write-protected LP2 disc as before,
   `swift run netmdcli --download-track 1 <dir> --bulk`
   Expect "Method: bulk", a much shorter time than 196 s, and a file byte-identical to the
   control-transfer copy (`cmp` against backups-n910/01.wav). If it matches, make bulk the default
   on Type-S.
3. **SP backup** (reads the disc): back up an SP track (e.g. the song on the N707's disc) and
   play the .m4a. SP decoding is checked against FFmpeg but no real SP backup has been made yet.
4. **LP4 backup**: needs an LP4 track, which means uploading one first (that writes to the disc,
   so use a blank). Back it up and listen.
5. **TOC write** (writes the disc's table of contents): only on a throwaway disc, N910 first.
   Not wired into netmdcli or the app yet; add a command once 1-4 pass.

### Results (2026-11-11, MZ-N910 with the write-protected LP2 disc)

1. `--toc`: works, read-only (no write commands). The disc's TOC was last written by a Sharp
   MD-F250 (signature 0x0a23); tracks have no recording dates.
2. Bulk: **not possible on this N910.** Its firmware loads its own fixes into patch slots 0-3 at
   start-up (and HFEC sits in 5), leaving three free slots; bulk needs four. netmd-exploits doesn't
   check which slots are in use, so ElectronWMD would overwrite one of those fixes. SwiftMD now
   reads every slot's switch first, uses only free ones, and refuses bulk here before sending
   anything (verified: 0 writes). Control-transfer backups use slot 7 as before.
3-5. Not run: the disc in the N910 has only LP2 tracks, and 4-5 write to a disc.

### Bulk on the MZ-N910 (2026-11-11)

With slots 6-7, slot 3 (merged into slot 2) and slot 4 (start-up only) free, a bulk backup of
the same LP2 track took **33 s instead of 196 s** and is byte-identical to the control-transfer
copy. Each bulk burst starts with one zero-length transfer (netmd-js reads past it; SwiftMD now
does too). Afterwards slots 0-5 read back exactly as before. Backups now use bulk where possible
and fall back to control transfers when bulk is refused (always before anything is changed).

## ForceTOCEdit (write edits without unplugging), 2026-11-11

`SWIFTMD_DEV=1 netmdcli --erase-and-write <archive>` on an MZ-N505 (R1.400) with an archived LP2 disc:
erased, triggered the firmware's TOC write, 63 s, code execution removed cleanly, player reported
0 tracks. Taking the disc out and back in without unplugging gave "Error" on the player; after a
power cycle the same disc read as Blank. So the write reached the disc, but the player couldn't read
the next disc until restarted, which needs an unplug anyway. Not used in the app: portables are told
to unplug after erasing instead.

The MZ-N910 looped on "TOC Edit" after an erase (even with a fresh battery) and its lid stayed shut
until the battery was pulled; with its weak recording, erase on another recorder.
