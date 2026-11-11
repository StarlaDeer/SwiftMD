// Records netmd-exploits' disc-backup (ATRAC download) command sequence against a simulated player,
// for SwiftMD's parity tests. Writes Tests/NetMDKitTests/Fixtures/download-transcripts.json.
//
//   ELECTRON_RUN_AS_NODE=1 /Applications/electronwmd.app/Contents/MacOS/electronwmd Tools/record-netmdjs-download.js
//
// The simulated player holds one two-fragment track and a small anti-skip buffer, so the
// recording includes netmd-exploits re-seeking when the buffer runs out. No real device is touched.

const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const base = process.env.NETMDJS_MODULES || '/Applications/electronwmd.app/Contents/Resources/app/node_modules/';
const { NetMD } = require(base + 'netmd-js/dist/netmd');
const { NetMDInterface } = require(base + 'netmd-js/dist/netmd-interface');
const factory = require(base + 'netmd-js/dist/factory');
const { scanQuery } = require(base + 'netmd-js/dist/query-utils');
const Crypto = require(base + '@originjs/crypto-js-wasm');
const { ExploitStateManager } = require(base + 'netmd-exploits/dist/exploit-state');
const { loadSafetyPatches } = require(base + 'netmd-exploits/dist/safety');
const { USBCodeExecution } = require(base + 'netmd-exploits/dist/exploits/usb-code-execution');
const { CachedSectorNoRamControlDownload } = require(base + 'netmd-exploits/dist/exploits/atrac-recovery/cached-sector-noram-transfers');
const { CachedSectorBulkDownload } = require(base + 'netmd-exploits/dist/exploits/atrac-recovery/cached-sector-bulk-transfers');
const { ForceTOCEdit } = require(base + 'netmd-exploits/dist/exploits/force-toc-edit');
const tocmanip = require(base + 'netmd-tocmanip');
const jconv = require(base + 'jconv');

/// A hand-built UTOC: three tracks (one in two fragments), multi-cell titles, a full-width title,
/// timestamps written by three different recorders. Paddings are filled with recognisable bytes.
function sampleTOC() {
    const s = [0, 1, 2, 3].map(i => new Uint8Array(2352).map((_, j) => (j * 7 + i * 13) & 0xff));
    const zero = (sec, from, to) => s[sec].fill(0, from, to);
    // Sector 0: signature 0x0121, non-empty, 3 tracks, track map, fragments.
    zero(0, 0x30, 2352);
    s[0].set([0x01, 0x21, 1, 3], 0x1c);
    s[0][0x2f] = 5; // next free track slot
    s[0].set([0, 1, 2, 4], 0x30); // disc, track 1 -> 1, track 2 -> 2, track 3 -> 4
    const addr = (l, g) => tocmanip.discAddressToBytes({ cluster: Math.floor(l / 32), sector: l % 32, group: g });
    const frag = (slot, start, sg, end, eg, mode, link) => s[0].set([...addr(start, sg), mode, ...addr(end, eg), link], 0x130 + slot * 8);
    frag(1, 0x640, 0, 0x6ff, 10, 0x86, 0);
    frag(2, 0x700, 0, 0x73f, 4, 0x82, 3);
    frag(3, 0x900, 6, 0x91f, 10, 0x82, 0);
    frag(4, 0x740, 0, 0x7ff, 10, 0x80, 0);
    // Sector 1: titles. Disc "Mixtape", track 1 "Hello world" (two cells), track 2 "B-side", track 3 none.
    zero(1, 0x2f, 2352);
    s[1][0x2f] = 6;
    s[1].set([1, 2, 4, 0], 0x30);
    const cell = (sec, slot, text, link) => { const b = [...text]; while (b.length < 7) b.push(0); s[sec].set([...b.slice(0, 7), link], 0x130 + slot * 8); };
    cell(1, 1, Buffer.from('Mixtape'), 0);
    cell(1, 2, Buffer.from('Hello w'), 3);
    cell(1, 3, Buffer.from('orld'), 0);
    cell(1, 4, Buffer.from('B-side'), 0);
    // Sector 2: timestamps. Track 1 by an MZ-N910 (0x121), track 2 by an MZ-N707 (0x120), track 3 unknown.
    zero(2, 0x2f, 2352);
    s[2].set([0, 1, 2, 3], 0x30);
    const stamp = (slot, sig) => s[2].set([0x26, 0x11, 0x10, 0x12, 0x34, 0x56, sig >> 8, sig & 0xff], 0x130 + slot * 8);
    stamp(1, 0x121); stamp(2, 0x120); stamp(3, 0x9999);
    // Sector 3: full-width title for track 1.
    zero(3, 0x2f, 2352);
    s[3].set([0, 1], 0x30);
    const fw = jconv.encode('テスト', 'SJIS');
    cell(3, 1, fw, 0);
    return s;
}

/// netmd-tocmanip's view of the sample TOC, for TOCTests.
function tocFixture() {
    const sectors = sampleTOC();
    const toc = tocmanip.parseTOC(...sectors);
    const info = [1, 2, 3].map(t => {
        const i = tocmanip.getTrackInfo(toc, t);
        return {
            title: i.title, writtenBy: i.writtenBy, signature: i.timestamp.signature,
            fragments: i.ranges.map(f => [tocmanip.discAddressToLogical(f.start), f.start.group, tocmanip.discAddressToLogical(f.end), f.end.group, f.mode]),
        };
    });
    const discTitle = tocmanip.getTitleByTrackNumber(toc, 0);
    const fullWidth = tocmanip.getTitleByTrackNumber(toc, 1, true);
    const rebuilt = tocmanip.reconstructTOC(toc, true).map(hex);
    const edited = JSON.parse(JSON.stringify(toc));
    tocmanip.swapTrack(edited, 1, 2);
    tocmanip.updateFlagAllFragmentsOfTrack(edited, 1, tocmanip.ModeFlag.F_WRITABLE, false);
    return { sectors: sectors.map(hex), rebuiltWithSignature: rebuilt, discTitle, fullWidth, info, edited: tocmanip.reconstructTOC(edited, false).map(hex) };
}

const hex = b => Buffer.from(b instanceof ArrayBuffer ? new Uint8Array(b) : new Uint8Array(b.buffer, b.byteOffset, b.byteLength)).toString('hex');
const fromHex = h => new Uint8Array(Buffer.from(h.replace(/ /g, ''), 'hex'));
const le32 = (b, o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// ExploitStateManager.create plus SwiftMD's one addition: slots whose patch is switched on (the
/// firmware's own fixes) are read first and never handed out. netmd-exploits itself doesn't check.
async function createLikeSwiftMD(iface, f) {
    const { getDescriptiveDeviceCode } = require(base + 'netmd-js');
    const deviceInfo = await f.getDeviceCode();
    const versionCode = await getDescriptiveDeviceCode(deviceInfo);
    const total = versionCode.startsWith('R') ? 4 : 8;
    const inUse = [];
    for (let i = 0; i < total; i++) {
        const control = await factory.cleanRead(f, 0x03802000 + i * 0x10, 4, factory.MemoryType.MAPPED);
        if (control[0] & 1) inUse.push(i);
    }
    const { Assembler } = require(base + 'netmd-exploits/dist/assembler/assembler');
    const { CORE_MACROS } = require(base + 'netmd-exploits/dist/assembler/core-macros');
    const esm = new ExploitStateManager(iface, f, { hwid: deviceInfo.hwid, versionCode, isHimd: false },
        await Assembler.create(CORE_MACROS, 'ARM'), await Assembler.create(CORE_MACROS, 'THUMB'), null);
    await loadSafetyPatches(esm);
    esm.freePatches = Array.from({ length: total }, (_, i) => i).filter(i => !inUse.includes(i));
    return esm;
}

const DRAM_SECTORS = 20; // anti-skip buffer size, in sectors
const SECONDS_PER_SECTOR = 704 / 11025;

/// Disc address bytes as stored in the UTOC.
const discAddress = (logical, group) => {
    const cluster = Math.floor(logical / 32), sector = logical % 32;
    return [cluster >> 6, ((cluster & 0x3f) << 2) | (sector >> 4), ((sector & 0xf) << 4) | group];
};

function makePlayer(scenario) {
    const { versionReply, mode, fragments, title, lp } = scenario;
    const planted = {};
    const plant = (addr, bytes) => bytes.forEach((b, i) => { planted[addr + i] = b; });
    const memoryByte = (addr, i) => planted[addr + i] ?? ((addr + i * 7) & 0xff);
    // Patch slot control words: switched off unless the scenario says otherwise.
    for (let i = 0; i < 8; i++) plant(0x03802000 + i * 0x10, [0, 0, 0, 0]);
    for (const [a, v] of scenario.plants || []) plant(a, v);

    // UTOC sector 0: track 1 -> fragment 1 (linked to 2...), sector 1: title of track 1.
    const utoc = [new Uint8Array(2352), new Uint8Array(2352)];
    utoc[0][0x30 + 1] = 1;
    fragments.forEach(([start, sg, end, eg], i) => {
        utoc[0].set([...discAddress(start, sg), mode, ...discAddress(end, eg), i + 1 < fragments.length ? i + 2 : 0], 0x130 + (i + 1) * 8);
    });
    utoc[1][0x30 + 1] = 1;
    utoc[1].set([...Buffer.from(title)].slice(0, 7), 0x130 + 8);

    const playOrder = fragments.flatMap(([start, , end]) => Array.from({ length: end - start + 1 }, (_, i) => start + i));
    const sectorContent = logical => {
        const s = new Uint8Array(2352);
        for (let i = 0; i < 2352; i++) s[i] = (logical * 31 + i * 13) & 0xff;
        s.set([logical >> 13, (logical >> 5) & 0xff, logical & 0x1f], 12);
        for (let f = 0; f < 11; f++) { const o = 20 + f * 212; s[o + 211] = s[o]; }
        return s;
    };
    const garbage = new Uint8Array(2352).fill(0x5a);
    garbage.set([0xff, 0xff, 0x1f], 12);
    garbage[20 + 10 * 212] = 1; garbage[20 + 10 * 212 + 1] = 2; // last frame fails the ATRAC check

    let dram = [];
    const written = {}; // RAM written through factory writes: address -> byte
    let bulkStream = new Uint8Array(0);
    const le32At = addr => [0, 1, 2, 3].reduce((v, i) => v | ((written[addr + i] ?? 0) << (8 * i)), 0);
    const refill = seconds => {
        const sectorTime = SECONDS_PER_SECTOR * (lp ? 2 : 1);
        const startIndex = Math.min(Math.floor(seconds / sectorTime), playOrder.length - 1);
        dram = playOrder.slice(startIndex, startIndex + DRAM_SECTORS).map(sectorContent);
    };

    const respond = function (request, cmd) {
        const q = cmd.slice(1);
        const h = hex(q);
        const accept = payload => new Uint8Array([0x09, ...payload]);
        const echo00 = () => { const out = new Uint8Array(q); out[2] = 0x00; return accept(out); };
        const tryScan = fmt => { try { return scanQuery(q, fmt); } catch { return null; } };
        let v;
        if (request === 0x80) {
            if (h.startsWith('18c5ff')) return echo00(); // stop
            if (h.startsWith('1850ff01')) return echo00(); // gotoTrack
            if (h.startsWith('1850ff00')) { // gotoTime: refill the buffer from that time
                const bcd = b => (b >> 4) * 10 + (b & 0xf);
                refill(bcd(q[10]) * 3600 + bcd(q[11]) * 60 + bcd(q[12]));
                return echo00();
            }
            if (q[0] === 0x18 && (q[1] === 0xd2 || q[1] === 0xd3) && q[2] === 0xff) { // code execution
                const code = q.slice(3);
                if (code.length === 13) return new Uint8Array([0x08, ...q]); // probe: not patched yet
                if (scenario.tocWrite) return new Uint8Array([0x08, ...q]); // ForceTOCEdit code just runs
                if (scenario.bulk && code.length !== 84) {
                    // Bulk download code: init and cleanup just run; the prep loader starts streaming
                    // the cached sectors between the sector_start and sector_end words in RAM.
                    if (code.length === scenario.bulk.prepLoaderLength) {
                        const start = le32At(scenario.bulk.sectorStart), end = le32At(scenario.bulk.sectorEnd);
                        const parts = [];
                        for (let i = start; i < end; i++) {
                            const padded = new Uint8Array(2432).fill(0xee);
                            padded.set(dram[i] ?? garbage);
                            parts.push(padded);
                        }
                        bulkStream = Buffer.concat(parts.map(p => Buffer.from(p)));
                    }
                    return new Uint8Array([0x08, ...q]);
                }
                const sector = le32(code, 72), start = le32(code, 76), length = le32(code, 80);
                const content = dram[sector] ?? garbage;
                return new Uint8Array([0x08, ...q, ...content.slice(start, start + length)]);
            }
            throw new Error('Simulated player has no answer for ' + h);
        }
        if (h.startsWith('1801ff0e')) return accept(q);
        if (h === '1812ff') return accept(fromHex(versionReply));
        if (tryScan('1820 ff %b %<d %b %b %b')) return echo00();
        if ((v = tryScan('1821 ff %b %<d %b'))) {
            const [type, addr, len] = v.map(x => Number(x.toString()));
            const data = Array.from({ length: len }, (_, i) => memoryByte(addr, i));
            return accept(new Uint8Array([...fromHex('1821 00'), type, ...q.slice(3, 7), len, 0, 0, ...data, 0xab, 0xcd]));
        }
        if (h.startsWith('1822ff')) {
            const addr = q[4] | (q[5] << 8) | (q[6] << 16) | (q[7] << 24), len = q[8];
            for (let i = 0; i < len; i++) written[addr + i] = q[11 + i];
            return accept(echo00().slice(1, 10));
        }
        if ((v = tryScan('1824 ff %<w %<w %b'))) {
            const [sector, offset, len] = v.map(x => Number(x.toString()));
            return accept(new Uint8Array([...fromHex('1824 00'), ...q.slice(3, 7), len, ...utoc[sector].slice(offset, offset + len)]));
        }
        if (h.startsWith('1825ff') || h.startsWith('1851ff') || h.startsWith('1852ff')) return echo00();
        throw new Error('Simulated player has no answer for ' + h);
    };
    respond.bulkIn = length => {
        const out = bulkStream.slice(0, length);
        bulkStream = bulkStream.slice(length);
        return out;
    };
    return respond;
}

function makeDevice(respond, log) {
    let pending = null;
    return {
        opened: true, vendorId: 0x054c, productId: 0x00c7,
        async open() {}, async selectConfiguration() {}, async claimInterface() {},
        async reset() {}, async releaseInterface() {}, async close() {},
        async controlTransferOut(setup, data) {
            const cmd = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            pending = respond(setup.request, cmd);
            log.push({ request: setup.request, command: hex(cmd), reply: hex(pending) });
            return { status: 'ok', bytesWritten: cmd.length };
        },
        async transferIn(endpoint, length) {
            const data = new Uint8Array(respond.bulkIn(length));
            log.push({ bulkIn: hex(data) });
            return { status: 'ok', data: new DataView(data.buffer) };
        },
        async controlTransferIn(setup, length) {
            if (setup.request === 0x01) {
                return { status: 'ok', data: new DataView(new Uint8Array([0, 0, pending ? pending.length : 0, 0]).buffer) };
            }
            const reply = pending; pending = null;
            return { status: 'ok', data: new DataView(reply.slice(0, length).buffer) };
        },
    };
}

/// netmd-exploits' NoRam reader with SwiftMD's one change: on Type-S, pieces are 8-byte aligned
/// (416 bytes instead of 420), because Type-S firmware garbles pieces that start off an 8-byte boundary.
const { concatUint8Arrays } = require(base + 'netmd-js/dist/utils');
const { formatUIntQuery } = require(base + 'netmd-exploits/dist/utils');
class AlignedNoRamDownload extends CachedSectorNoRamControlDownload {
    async readNextSector() {
        if (this.currentTrack === -1) throw new Error('You need to startDownload() first');
        const exec = await this.stateManager.require(USBCodeExecution);
        let maxPiece = 512 - 8 - this.codeLength;
        if (!this.stateManager.device.versionCode.startsWith('R')) maxPiece &= ~7;
        const parts = [];
        let rem = 2352;
        while (rem > 0) {
            const length = Math.min(rem, maxPiece);
            const full = await exec.execute(concatUint8Arrays(this.codeTemplate, formatUIntQuery('%<d', this.sector),
                formatUIntQuery('%<d', 2352 - rem), formatUIntQuery('%<d', length)), length + this.codeLength + 4);
            const part = full.slice(this.codeLength);
            parts.push(part);
            rem -= part.length;
        }
        ++this.sector;
        return concatUint8Arrays(...parts);
    }
}
AlignedNoRamDownload._name = CachedSectorNoRamControlDownload._name;

const SCENARIOS = {
    // MZ-N910-like: S1.600 with Sony's safety patch in slot 5, an SP stereo track in two fragments.
    'download.spStereo.S1.600': {
        versionReply: '1812 00 21 08 00 16', mode: 0x86, title: 'Tone', lp: false,
        fragments: [[0x100, 0, 0x111, 10], [0x200, 6, 0x20b, 4]],
        plants: [
            [0x03802050, [1, 0, 0, 0]], [0x03802054, [0xc4, 0, 0, 0]], [0x03802058, [0xdc, 0xff, 0xff, 0xea]], // HFEC in slot 5
            [0x02000310, [0x10]], // disc has stopped spinning
        ],
    },
    // Patch slots as on the real MZ-N910: the firmware's fixes switched on in slots 0-3, HFEC in 5,
    // and 4, 6 and 7 switched off but still holding an earlier session's code-execution address
    // (which netmd-exploits mistakes for developer patches). Only 4, 6 and 7 may be used.
    'download.spStereo.S1.600.n910slots': {
        versionReply: '1812 00 21 08 00 16', mode: 0x86, title: 'Tone', lp: false,
        fragments: [[0x100, 0, 0x111, 10], [0x200, 6, 0x20b, 4]],
        plants: [
            ...[0, 1, 2, 3].flatMap(i => [[0x03802000 + i * 0x10, [1, 0, 0, 0]], [0x03802004 + i * 0x10, [0x24, 0x89, 1, 0]]]),
            ...[4, 6, 7].flatMap(i => [[0x03802004 + i * 0x10, [0x9c, 0xe6, 0, 0]], [0x03802008 + i * 0x10, [0x13, 0x48, 0x00, 0x47]]]),
            [0x03802050, [1, 0, 0, 0]], [0x03802054, [0xc4, 0, 0, 0]], [0x03802058, [0xdc, 0xff, 0xff, 0xea]],
            [0x02000310, [0x10]],
        ],
    },
    // The same player and track with netmd-exploits' bulk reader (its first choice on Type-S).
    'download.spStereo.S1.600.bulk': {
        versionReply: '1812 00 21 08 00 16', mode: 0x86, title: 'Tone', lp: false,
        fragments: [[0x100, 0, 0x111, 10], [0x200, 6, 0x20b, 4]],
        plants: [
            [0x03802050, [1, 0, 0, 0]], [0x03802054, [0xc4, 0, 0, 0]], [0x03802058, [0xdc, 0xff, 0xff, 0xea]],
            [0x02000310, [0x10]],
        ],
        bulk: { prepLoaderLength: 12, sectorStart: 0x02006304, sectorEnd: 0x02006308 },
    },
    // Writing an edited TOC (Web MiniDisc Pro's writeModifiedTOC): four sectors, then ForceTOCEdit.
    'toc.write.S1.600': {
        versionReply: '1812 00 21 08 00 16', mode: 0x86, title: 'Tone', lp: false, tocWrite: true,
        fragments: [[0x100, 0, 0x111, 10]],
        plants: [[0x03802050, [1, 0, 0, 0]], [0x03802054, [0xc4, 0, 0, 0]], [0x03802058, [0xdc, 0xff, 0xff, 0xea]]],
    },
    'toc.write.R1.400': {
        versionReply: '1812 00 20 04 00 14', mode: 0x82, title: 'Song', lp: true, tocWrite: true,
        fragments: [[0x300, 0, 0x31b, 10]],
    },
    // MZ-N505-like: R1.400, an LP2 track.
    'download.lp2.R1.400': {
        versionReply: '1812 00 20 04 00 14', mode: 0x82, title: 'Song', lp: true,
        fragments: [[0x300, 0, 0x31b, 10]],
    },
};

(async () => {
    await Crypto.algo.DES.loadWasm();
    await Crypto.algo.TripleDES.loadWasm();
    const out = {};
    for (const [name, scenario] of Object.entries(SCENARIOS)) {
        const log = [];
        const netmd = new NetMD(makeDevice(makePlayer(scenario), log));
        const iface = new NetMDInterface(netmd);
        const f = new factory.NetMDFactoryInterface(netmd);
        const esm = await createLikeSwiftMD(iface, f);
        if (scenario.tocWrite) {
            const sectors = tocmanip.reconstructTOC(tocmanip.parseTOC(...sampleTOC()), false);
            for (let i = 0; i < 4; i++) await factory.writeUTOCSector(f, i, sectors[i]);
            await (await esm.require(ForceTOCEdit)).forceTOCEdit();
            out[name] = { exchanges: log };
            console.log(`${name}: ${log.length} exchanges`);
            continue;
        }
        const downloader = await esm.require(scenario.bulk ? CachedSectorBulkDownload : AlignedNoRamDownload);
        const { data, extension } = await downloader.downloadTrack(0);
        await esm.unload(downloader);
        await esm.unload(USBCodeExecution); // SwiftMD removes its patch when done
        out[name] = {
            result: {
                extension,
                length: data.length,
                sha256: crypto.createHash('sha256').update(data).digest('hex'),
                head: hex(data.slice(0, 64)),
            },
            exchanges: log,
        };
        console.log(`${name}: ${log.length} exchanges, ${data.length} bytes .${extension}`);
    }
    fs.writeFileSync(path.join(__dirname, '..', 'Tests', 'NetMDKitTests', 'Fixtures', 'toc-fixture.json'), JSON.stringify(tocFixture(), null, 1) + '\n');
    console.log('Wrote toc-fixture.json');
    const dest = path.join(__dirname, '..', 'Tests', 'NetMDKitTests', 'Fixtures', 'download-transcripts.json');
    fs.writeFileSync(dest, JSON.stringify(out) + '\n');
    console.log('Wrote', dest);
})().catch(e => { console.error(e); process.exit(1); });
