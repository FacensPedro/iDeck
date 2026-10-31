const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.resolve(__dirname, "../../scripts/jit/universal.js"), "utf8");
const start = source.indexOf("function littleEndianHexStringToNumber(");
const end = source.indexOf("function littleEndianHexToU32(", start);
assert.ok(start >= 0 && end > start, "Register helpers must be present");

const context = vm.createContext({});
vm.runInContext(source.slice(start, end), context, { timeout: 1000 });

for (const value of [
    0n,
    1n,
    0x10000000000n,
    0x123456789abcdef0n,
    0xffffffffffffffffn
]) {
    const encoded = context.numberToLittleEndianHexString(value);
    assert.equal(encoded.length, 16);
    assert.equal(context.littleEndianHexStringToNumber(encoded), value);
}

assert.equal(context.numberToLittleEndianHexString(0x123456789abcdef0n), "f0debc9a78563412");
assert.equal(context.littleEndianHexStringToNumber("f0debc9a78563412"), 0x123456789abcdef0n);
assert.throws(() => context.littleEndianHexStringToNumber("1234567890"));
assert.throws(() => context.numberToLittleEndianHexString(-1n));
assert.throws(() => context.numberToLittleEndianHexString(0x10000000000000000n));
console.log("PASS: StikDebug universal JIT script preserves full 64-bit ARM64 registers");


const prepareStart = source.indexOf("function JIT26PrepareRegion(brkResponse) {");
const prepareEnd = source.indexOf("// Madeira's ARM64EC init_syscall_frame", prepareStart);
assert.ok(prepareStart >= 0 && prepareEnd > prepareStart);
vm.runInContext(source.slice(prepareStart, prepareEnd), context, { timeout: 1000 });

function executeJITRequest(allocResponse, originalAddress = 0n, preparation = true) {
    const replies = [];
    const prepared = [];
    context.x0 = originalAddress;
    context.x1 = 0x4000000n;
    context.tid = "24";
    context.send_command = command => {
        if (command.startsWith("_M")) return allocResponse;
        replies.push(command);
        return "OK";
    };
    context.prepare_memory_region = (address, size) => {
        prepared.push({ address, size });
        if (preparation === "throw") throw new Error("Debugger preparation refused");
        return preparation;
    };
    context.log = () => {};
    context.log_verbose = () => {};
    context.JIT26PrepareRegion(null);
    return { replies, prepared };
}

for (const response of ["E22", "E0c", "garbage", "", null, "1a00"]) {
    const result = executeJITRequest(response);
    assert.equal(result.replies[0], "P0=0000000000000000;thread:24;");
    assert.equal(result.prepared.length, 0);
}
for (const response of ["11a000000", "0x11a000000"]) {
    const result = executeJITRequest(response);
    assert.equal(result.replies[0], "P0=0000001a01000000;thread:24;");
    assert.equal(result.prepared.length, 1);
    assert.equal(result.prepared[0].address, 0x11a000000n);
}
const existing = executeJITRequest("E22", 0x11b000000n);
assert.equal(existing.prepared.length, 1);
assert.equal(existing.prepared[0].address, 0x11b000000n);
for (const result of [false, "E22", "throw"]) {
    const failed = executeJITRequest("11a000000", 0n, result);
    assert.equal(failed.replies[0], "P0=0000000000000000;thread:24;");
    assert.equal(failed.prepared.length, 1);
}
console.log("PASS: StikDebug invalid _M and failed RX preparation never return executable addresses");


// Full stop loop against a scripted debugserver: Wine's signals and FEX's
// faults must be passed through without a debugger stop, a non-BRK stop is
// continued with its signal in one round trip, and a JIT26PrepareRegion BRK
// is still serviced.
(function () {
    const le = (value) => {
        let hex = "";
        for (let i = 0; i < 8; i++) hex += Number((value >> BigInt(i * 8)) & 0xffn).toString(16).padStart(2, "0");
        return hex;
    };
    const brkPC = 0x100004000n;
    const sigPC = 0x100008000n;
    const stops = [
        // SIGUSR2 (0x1f) at an ordinary instruction.
        `T1fthread:24;20:${le(sigPC)};10:${le(0n)};00:${le(0n)};01:${le(0n)};`,
        // BRK #0xf00d with x16 = 1 (prepare region), x0 = 0, x1 = 16 KiB.
        `T05thread:24;20:${le(brkPC)};10:${le(1n)};00:${le(0n)};01:${le(0x4000n)};`,
    ];
    const sent = [];
    let continues = 0;
    const logs = [];
    const runtime = vm.createContext({
        BigInt, Number, String, parseInt, Error,
        get_pid: () => 1234,
        log: (message) => logs.push(String(message)),
        prepare_memory_region: () => true,
        send_command(command) {
            sent.push(command);
            if (command.startsWith("vAttach")) return "OK";
            if (command.startsWith("QSetIgnoredExceptions") || command.startsWith("QPassSignals")) return "OK";
            if (command === "c") {
                continues++;
                return continues === 1 ? stops[0] : "W00";
            }
            if (command.startsWith("vCont;C1f:24;c")) return stops[1];
            if (command === `m${sigPC.toString(16)},4`) return "1f2003d5"; // nop
            if (command === `m${brkPC.toString(16)},4`) return "a0013ed4"; // brk #0xf00d (0xd43e01a0)
            if (command.startsWith("_M")) return "200000000";
            return "OK";
        },
    });
    vm.runInContext(source, runtime, { timeout: 2000 });

    assert.ok(sent.includes("QSetIgnoredExceptions:EXC_BAD_ACCESS;EXC_BAD_INSTRUCTION"));
    const pass = sent.find((command) => command.startsWith("QPassSignals:"));
    assert.ok(pass, "signals must be passed through");
    assert.ok(!pass.slice("QPassSignals:".length).split(";").includes("5"), "SIGTRAP carries BRK and must stop");
    assert.ok(sent.includes("vCont;C1f:24;c"), "a non-BRK stop continues with its own signal");
    assert.ok(!sent.some((command) => command.startsWith("vCont;S")), "never single-step to forward a signal");
    assert.equal(continues, 2, "the stop returned by vCont;C must not be followed by an extra continue");
    assert.ok(sent.some((command) => command.startsWith("_M4000,rx")), "the BRK request is serviced");
    assert.ok(logs.length <= 60, `the stop loop must not flood StikDebug's UI (${logs.length} lines)`);
    console.log("PASS: universal.js passes signals through and services JIT BRKs without extra round trips");
})();
