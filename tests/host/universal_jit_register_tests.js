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
