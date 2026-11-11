# MZ-N910 slot merge: assembly and proof

`merge.s` is the continuation SwiftMD writes into the unused slot 6-7 handler space (see
`Sources/NetMDKit/SlotMerge.swift` and `docs/n910-patch-slots.md`).

`prove.py` runs Sony's two-trap path and the merged path on an MZ-N910's real firmware and RAM
dumps and requires identical registers and memory on 5000 random starting states. It also breaks
one byte of the merged code and requires the mismatch to be caught. The dumps are Sony's code and
are not in the repo; make them with `netmdcli --dump-firmware <dir>`.

```bash
xcrun clang --target=armv5te-none-eabi -c merge.s -o merge.o
xcrun llvm-objdump --triple=armv5te -d merge.o | python3 -c "import sys,re,struct; open('merge.bin','wb').write(b''.join(struct.pack('<I',int(m.group(1),16)) for m in (re.match(r'\s*[0-9a-f]+:\s+([0-9a-f]{8})\s',l) for l in sys.stdin) if m))"
FIRMWARE_DUMPS=/path/to/dumps python3 prove.py
```
