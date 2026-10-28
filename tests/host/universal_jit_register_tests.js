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

function executeJITRequest(allocResponse, originalAddress = 0n) {
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
        return true;
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
    assert.equal(result.replies[0], "P0=0000a01101000000;thread:24;");
    assert.equal(result.prepared.length, 1);
    assert.equal(result.prepared[0].address, 0x11a000000n);
}
const existing = executeJITRequest("E22", 0x11b000000n);
assert.equal(existing.prepared.length, 1);
assert.equal(existing.prepared[0].address, 0x11b000000n);
console.log("PASS: StikDebug invalid _M replies never produce stale Wine JIT addresses");
