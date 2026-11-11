// Records netmd-js's exact USB command/reply sequences for SwiftMD's parity tests.
//
// Runs netmd-js (the copy bundled in ElectronWMD) against a simulated player and writes every
// exchange, plus each scenario's result, to Tests/NetMDKitTests/Fixtures/factory-transcripts.json.
// SwiftMD's tests replay the replies and require byte-identical commands.
//
//   ELECTRON_RUN_AS_NODE=1 /Applications/electronwmd.app/Contents/MacOS/electronwmd Tools/record-netmdjs-transcripts.js
//
// No real device is touched.

const path = require('path');
const fs = require('fs');
const base = process.env.NETMDJS_MODULES || '/Applications/electronwmd.app/Contents/Resources/app/node_modules/';
const { NetMD } = require(base + 'netmd-js/dist/netmd');
const factory = require(base + 'netmd-js/dist/factory');
const { formatQuery, scanQuery } = require(base + 'netmd-js/dist/query-utils');
const Crypto = require(base + '@originjs/crypto-js-wasm');
const { ExploitStateManager } = require(base + 'netmd-exploits/dist/exploit-state');
const { loadSafetyPatches } = require(base + 'netmd-exploits/dist/safety');
const { FirmwareDumper } = require(base + 'netmd-exploits/dist/exploits/firmware-dumper');

/// An exploit state manager like ExploitStateManager.create's, minus the assemblers (unused here).
const stateManager = (f, versionCode) => new ExploitStateManager(null, f, { hwid: 0, versionCode, isHimd: versionCode.startsWith('H') }, null, null, null);

/// Small regions for the dump scenario: RAM has a decoy USB buffer at 0x10 and the real one at 0x50,
/// whose read-range table (at 0x70) starts with its own address, as on a real player.
class SmallFirmwareDumper extends FirmwareDumper {
    getPropertyStore() { return { romSize: { '*': 0x40 }, ramSize: { '*': 0x100 } }; }
}

const hex = b => Buffer.from(b instanceof ArrayBuffer ? new Uint8Array(b) : new Uint8Array(b.buffer, b.byteOffset, b.byteLength)).toString('hex');
const fromHex = h => new Uint8Array(Buffer.from(h.replace(/ /g, ''), 'hex'));

/// Deterministic "memory" contents, so reads return recognisable data.
/// Scenarios can plant specific bytes (absolute address -> byte) in `planted`.
let planted = {};
const memoryByte = (addr, i) => planted[addr + i] ?? ((addr + i * 7) & 0xff);
const plant = (addr, bytes) => bytes.forEach((b, i) => { planted[addr + i] = b; });

/// A simulated deck answering factory commands. Returns the full reply (status byte + payload).
function respond(request, cmd) {
    const q = cmd.slice(1); // drop status byte
    const h = hex(q);
    const accept = payload => new Uint8Array([0x09, ...payload]);
    const tryScan = fmt => { try { return scanQuery(q, fmt); } catch { return null; } };
    let v;
    if (h.startsWith('1801ff0e') || h.startsWith('1802ff04')) return accept(q);
    if (h === '1812ff') return accept(fromHex('1812 00 21 08 00 16')); // Type-S, hwid 8, v1.6 subversion 0 -> S1.600
    if (h === '1813ff') return accept(fromHex('1813 00 00 16'));
    if ((v = tryScan('1820 ff %b %<d %b %b %b')) || (v = tryScan('182b ff %b %<d %b %b %b'))) {
        const out = new Uint8Array(q); out[2] = 0x00; return accept(out);
    }
    if ((v = tryScan('1821 ff %b %<d %b'))) {
        const [type, addr, len] = v.map(x => Number(x.toString()));
        const data = Array.from({ length: len }, (_, i) => memoryByte(addr, i));
        return accept(new Uint8Array([...fromHex('1821 00'), type, ...new Uint8Array(formatQuery('%<d', addr)), len, 0, 0, ...data, 0xab, 0xcd]));
    }
    if ((v = tryScan('182c ff %b %<d'))) {
        const [lenType, addr] = v.map(x => Number(x.toString()));
        const len = lenType & 0x1f;
        const data = Array.from({ length: len }, (_, i) => memoryByte(addr, i));
        return accept(new Uint8Array([...fromHex('182c 00'), lenType, ...new Uint8Array(formatQuery('%<d', addr)), len, 0, 0, ...data, 0xab, 0xcd]));
    }
    if (h.startsWith('1822ff') || h.startsWith('182dff')) { const out = new Uint8Array(q); out[2] = 0x00; return accept(out.slice(0, 9)); }
    if ((v = tryScan('1824 ff %<w %<w %b'))) {
        const [sector, offset, len] = v.map(x => Number(x.toString()));
        const data = Array.from({ length: len }, (_, i) => memoryByte(sector * 4096 + offset, i));
        return accept(new Uint8Array([...fromHex('1824 00'), ...q.slice(3, 7), len, ...data]));
    }
    if (h.startsWith('1825ff') || h.startsWith('1851ff') || h.startsWith('1852ff')) { const out = new Uint8Array(q); out[2] = 0x00; return accept(out); }
    throw new Error('Simulated deck has no answer for ' + h);
}

/// A WebUSB-like device that records every command and reply.
function makeDevice(log) {
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
        async controlTransferIn(setup, length) {
            if (setup.request === 0x01) {
                return { status: 'ok', data: new DataView(new Uint8Array([0, 0, pending ? pending.length : 0, 0]).buffer) };
            }
            const reply = pending; pending = null;
            return { status: 'ok', data: new DataView(reply.slice(0, length).buffer) };
        },
    };
}

const toPlain = r => r instanceof Uint8Array ? { bytes: hex(r) } : r === undefined ? null : r;

const scenarios = {
    'netmd.auth': f => f.auth(),
    'netmd.deviceCode': async f => factory.getDescriptiveDeviceCode(f),
    'netmd.cleanRead': f => factory.cleanRead(f, 0x03802004, 4, factory.MemoryType.MAPPED),
    'netmd.cleanReadEncrypted': f => factory.cleanRead(f, 0x00001000, 16, factory.MemoryType.EEPROM_2, true),
    'netmd.cleanWrite': f => factory.cleanWrite(f, 0x02003ff0, new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]), factory.MemoryType.MAPPED),
    'netmd.cleanWriteEncrypted': f => factory.cleanWrite(f, 0x00001000, new Uint8Array([9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6]), factory.MemoryType.EEPROM_2, true),
    'netmd.writeOfAnyLength': f => factory.writeOfAnyLength(f, 0x02004000, new Uint8Array(Array.from({ length: 40 }, (_, i) => i)), factory.MemoryType.MAPPED),
    'netmd.readPatch': async f => { const p = await factory.readPatch(f, 3); return { address: p.address, data: hex(p.data) }; },
    'netmd.patch': f => factory.patch(f, 0x000000c4, fromHex('dcffffea'), 7, 8),
    'netmd.unpatch': f => factory.unpatch(f, 7, 8),
    'netmd.display': f => factory.display(f, 'SwiftMD', true),
    'netmd.readUTOCSector': f => factory.readUTOCSector(f, 1),
    'netmd.writeUTOCSector': f => factory.writeUTOCSector(f, 2, new Uint8Array(Array.from({ length: 2352 }, (_, i) => (i * 13) & 0xff))),
    'netmd.safetyApply': async f => {
        const esm = stateManager(f, 'S1.600');
        await loadSafetyPatches(esm);
        return esm.freePatches.join(',');
    },
    'netmd.safetyFound': async f => {
        plant(0x03802034, [0xc4, 0, 0, 0]); plant(0x03802038, [0xdc, 0xff, 0xff, 0xea]); // HFEC in slot 3
        plant(0x03802054, [0xc0, 0xe6, 0, 0]); // developer patch in slot 5
        const esm = stateManager(f, 'S1.600');
        await loadSafetyPatches(esm);
        return esm.freePatches.join(',');
    },
    'netmd.safetyTypeR': async f => {
        const esm = stateManager(f, 'R1.400');
        await loadSafetyPatches(esm);
        return esm.freePatches.join(',');
    },
    'netmd.firmwareDump': async f => {
        plant(0x02000010, [0x00, 0x18, 0x21, 0x00, 0x00]);
        plant(0x02000050, [0x00, 0x18, 0x21, 0x00, 0x00]);
        plant(0x02000070, [0x70, 0x00, 0x00, 0x02]);
        const { ram, rom } = await new SmallFirmwareDumper(stateManager(f, 'S1.600')).readFirmware();
        return { bytes: hex(ram) + hex(rom) };
    },
    'himd.auth': f => f.auth(),
    'himd.cleanRead': f => factory.cleanRead(f, 0x03804008, 4, factory.MemoryType.MAPPED),
    'himd.cleanWrite': f => factory.cleanWrite(f, 0x02003ff0, new Uint8Array([1, 2, 3, 4]), factory.MemoryType.MAPPED),
};

(async () => {
    await Crypto.algo.DES.loadWasm(); // NetMD.init() does this on a real connection
    await Crypto.algo.TripleDES.loadWasm();
    const out = {};
    for (const [name, run] of Object.entries(scenarios)) {
        const log = [];
        planted = {};
        const netmd = new NetMD(makeDevice(log));
        const iface = name.startsWith('himd.') ? new factory.HiMDFactoryInterface(netmd) : new factory.NetMDFactoryInterface(netmd);
        const result = await run(iface);
        out[name] = { result: toPlain(result), exchanges: log };
        console.log(`${name}: ${log.length} exchanges`);
    }
    const dest = path.join(__dirname, '..', 'Tests', 'NetMDKitTests', 'Fixtures', 'factory-transcripts.json');
    fs.writeFileSync(dest, JSON.stringify(out, null, 1) + '\n');
    console.log('Wrote', dest);
})().catch(e => { console.error(e); process.exit(1); });
