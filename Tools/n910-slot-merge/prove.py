"""Runs Sony's two-trap path and SwiftMD's merged path on the MZ-N910's real bytes and compares.

Only the instruction forms that occur on these paths are implemented; anything else aborts, so the
simulator can't silently skip an instruction it doesn't understand."""
import os, random, struct, sys
DUMPS = os.environ.get('FIRMWARE_DUMPS', '../firmware-dumps')

ROM = open(os.path.join(DUMPS, 'S1.600-rom.bin'), 'rb').read()
RAM0 = open(os.path.join(DUMPS, 'S1.600-ram.bin'), 'rb').read()
MERGE = open('merge.bin', 'rb').read()
RAMBASE = 0x02000000
SLOT_ADDR = {2: 0x59ab8, 3: 0x59ac8}           # patch slot address registers (Sony)
SLOT_DATA = {2: bytes.fromhex('617200de'), 3: bytes.fromhex('e07200de')}
HANDLER = lambda s: 0x02002ba0 + 0x28 * s
MASK = 0xffffffff

class CPU:
    def __init__(self, regs, mem, merged):
        self.r = list(regs) + [0] * (16 - len(regs))
        self.mem = mem            # dict addr -> byte, for data
        self.merged = merged
        self.und_stack = []
        self.steps = 0

    # Code fetch: ROM with Sony's patches overlaid (the patch peripheral), RAM with handlers.
    def code(self, addr, n):
        out = b''
        for a in range(addr, addr + n):
            for s, pa in SLOT_ADDR.items():
                if self.merged and s == 3:
                    continue  # slot 3 switched off in the merged setup
                if pa <= a < pa + 4:
                    out += SLOT_DATA[s][a - pa:a - pa + 1]
                    break
            else:
                if a >= RAMBASE:
                    out += bytes([self.ram_code(a)])
                else:
                    out += ROM[a:a + 1]
        return out

    def ram_code(self, a):
        off = a - RAMBASE
        if self.merged:
            if a == 0x02002c0c or 0x02002c0c < a < 0x02002c10:
                return struct.pack('<I', 0xEA00001F)[a - 0x02002c0c]
            if 0x02002c90 <= a < 0x02002c90 + len(MERGE):
                return MERGE[a - 0x02002c90]
        return RAM0[off]

    def ldrb(self, a): return self.mem.get(a & MASK, 0)
    def strb(self, a, v): self.mem[a & MASK] = v & 0xff

    def undefined(self, ret):
        # The firmware's handler at ROM 0x468: push {r8-r12, lr}; find the slot whose address
        # register matches the trap; jump to its RAM handler. lr = trap + 2 (Thumb).
        trap = ret - 2
        slots = [s for s, pa in SLOT_ADDR.items() if (pa & ~3) == (trap & ~3) and not (self.merged and s == 3)]
        if not slots:
            raise Exception(f'undefined instruction at {trap:#x} with no slot')
        self.und_stack.append(self.r[8:13] + [ret])
        self.r[14] = ret
        return HANDLER(slots[0]), False  # ARM state

    def run(self, pc, thumb, stop):
        while True:
            self.steps += 1
            if self.steps > 200: raise Exception('runaway')
            if thumb and pc == stop: return
            if thumb:
                (h,) = struct.unpack('<H', self.code(pc, 2))
                if h == 0xde00:                       # udf
                    pc, thumb = self.undefined(pc + 2); continue
                op = h >> 11
                rd, rn, imm = h & 7, (h >> 3) & 7, (h >> 6) & 31
                if op == 0b01111:   self.r[rd] = self.ldrb(self.r[rn] + imm)            # ldrb
                elif op == 0b01110: self.strb(self.r[rn] + imm, self.r[rd])               # strb
                elif op == 0b00000: self.r[rd] = (self.r[rn] << imm) & MASK               # lsls
                elif op == 0b00001: self.r[rd] = self.r[rn] >> (imm or 32) if imm else 0  # lsrs
                elif h >> 6 == 0b0100001100: self.r[rd] |= self.r[rn]                     # orrs
                else: raise Exception(f'thumb {h:#06x} at {pc:#x} not modelled')
                pc += 2
            else:
                (w,) = struct.unpack('<I', self.code(pc, 4))
                if w >> 20 == 0xe5d:   rn, rt, i = (w >> 16) & 15, (w >> 12) & 15, w & 0xfff; self.r[rt] = self.ldrb(self.r[rn] + i)
                elif w >> 20 == 0xe5c: rn, rt, i = (w >> 16) & 15, (w >> 12) & 15, w & 0xfff; self.strb(self.r[rn] + i, self.r[rt])
                elif w & 0xfff00060 == 0xe1b00000 and (w >> 4) & 1 == 0 and w & 0xf000 != 0xf000:  # movs rd, rm, lsl #imm
                    rd, rm, sh = (w >> 12) & 15, w & 15, (w >> 7) & 31; self.r[rd] = (self.r[rm] << sh) & MASK
                elif w & 0xfff00060 == 0xe1b00020 and (w >> 4) & 1 == 0:                         # movs rd, rm, lsr #imm
                    rd, rm, sh = (w >> 12) & 15, w & 15, (w >> 7) & 31; self.r[rd] = self.r[rm] >> (sh or 32) if sh else 0
                elif w & 0xfff00ff0 == 0xe1900000: rd, rn, rm = (w >> 12) & 15, (w >> 16) & 15, w & 15; self.r[rd] = self.r[rn] | self.r[rm]
                elif w == 0xe8bd5f00:  saved = self.und_stack.pop(); self.r[8:13] = saved[:5]; self.r[14] = saved[5]
                elif w == 0xe28ee010:  self.r[14] = (self.r[14] + 0x10) & MASK
                elif w == 0xe28ee002:  self.r[14] = (self.r[14] + 2) & MASK
                elif w == 0xe1b0f00e:  pc, thumb = self.r[14], True; continue                    # movs pc, lr
                elif w >> 24 == 0xea:  off = w & 0xffffff; off -= (1 << 24) if off & 0x800000 else 0; pc = pc + 8 + off * 4; continue
                else: raise Exception(f'arm {w:#010x} at {pc:#x} not modelled')
                pc += 4

def trial(seed):
    rnd = random.Random(seed)
    regs = [rnd.getrandbits(32) for _ in range(13)]
    regs[4], regs[7] = 0x02001000 + rnd.randrange(0, 0x100), 0x02003000 + rnd.randrange(0, 0x100)
    mem = {}
    for base in (regs[4], regs[7]):
        for i in range(0x20): mem[base + i] = rnd.getrandbits(8)
    results = []
    for merged in (False, True):
        cpu = CPU(regs, dict(mem), merged)
        cpu.run(0x59ab8, True, 0x59acc)
        assert not cpu.und_stack, 'unbalanced handler stack'
        results.append((cpu.r[:13], sorted(cpu.mem.items())))
    return results[0] == results[1], results

# Sanity: the simulator must notice a wrong merge. Break one byte of the merged code and expect a mismatch.
ok = all(trial(s)[0] for s in range(5000))
print('identical on 5000 random states:', ok)
MERGE = MERGE[:0x18] + bytes([0x0c]) + MERGE[0x19:]   # strb to [r4, #0xc] instead of #0xb
broken = all(trial(s)[0] for s in range(200))
print('deliberately broken merge detected:', not broken)
sys.exit(0 if ok and not broken else 1)
