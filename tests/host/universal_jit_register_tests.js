// iDeck ships Madeira's own StikDebug script (app/Madeira/madeira-jit.js,
// copied line by line) as scripts/jit/universal.jitscript.
const assert = require("assert");
const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(path.resolve(__dirname, "../../scripts/jit/universal.jitscript"), "utf8");
// Syntax only: StikDebug provides send_command, log and the other globals.
assert.doesNotThrow(() => new Function(source));
assert.ok(source.startsWith("// Madeira JIT Script for StikDebug"));
for (const command of ["x16Num === 0n", "x16Num === 1n", "x16Num === 3n", "brkImm === 0x69"]) {
    assert.ok(source.includes(command), command);
}
assert.ok(source.includes("QSetIgnoredExceptions:EXC_BAD_ACCESS;EXC_BAD_INSTRUCTION"));
console.log("PASS: universal.jitscript is Madeira's madeira-jit.js (detach, prepare region, page zero, legacy 0x69)");
