// Universal JIT Script, last updated 2026-29-03 (YYYY-DD-MM)
/*
 // JIT "syscalls"
 __attribute__((noinline,optnone,naked))
 void JIT26Detach(void) {
     asm("mov x16, #0 \n"
         "brk #0xf00d \n"
         "ret");
 }
 __attribute__((noinline,optnone,naked))
 void* JIT26PrepareRegion(void *addr, size_t len) {
     asm("mov x16, #1 \n"
         "brk #0xf00d \n"
         "ret");
 }

 __attribute__((noinline,optnone,naked))
void BreakSendJITScript(char* script, size_t len) {
    asm("mov x16, #2 \n"
        "brk #0xf00d \n"
        "ret");
}
 */
const CMD_DETACH = 0;
const CMD_PREPARE_REGION = 1;
const CMD_NEW_BREAKPOINTS = 2;
const CMD_MAP_PAGE_ZERO = 3;
const commands = {
    [CMD_DETACH]: JIT26Detach,
    [CMD_PREPARE_REGION]: JIT26PrepareRegion,
    [CMD_NEW_BREAKPOINTS]: JIT26NewBreakpoints,
    [CMD_MAP_PAGE_ZERO]: JIT26MapPageZero
};
const legacyCommands = {
    [0x68]: JIT26NewBreakpoints,
    [0x69]: JIT26HandleBrk0x69,
    [0xf00d]: JIT26HandleBrk0xf00d
};

// Log levels
//const LOG_NONE = 0;
const LOG_INFO = 1;
const LOG_VERBOSE = 2;
let logLevel = LOG_INFO;
function log_verbose(msg) {
    if (logLevel >= LOG_VERBOSE) {
        log(msg);
    }
}

// To avoid having to re-parse these in each function, we save some registers here
let tid, x0, x1, x16, pc;
let detached = false;
let continuesWithSignal = true;
let pid = get_pid();
let attachResponse = send_command(`vAttach;${pid.toString(16)}`);

log(`pid = ${pid}`);
log(`attach_response = ${attachResponse}`);

// Only BRK stops need this script. Wine signals constantly (thread suspend
// and resume) and FEX relies on faults; making the debugger stop on each of
// them costs several protocol round trips per event and, under load, lets
// iOS's watchdog kill StikDebug (0x8BADF00D), taking the game down with it.
// Both packets are best-effort (Madeira's madeira-jit.js does the same):
//   QSetIgnoredExceptions: Mach faults go to the app's own handlers.
//   QPassSignals: signals reach the process without stopping. SIGTRAP (5)
//     is excluded because BRK arrives as SIGTRAP.
{
    const ignored = send_command(`QSetIgnoredExceptions:EXC_BAD_ACCESS;EXC_BAD_INSTRUCTION`);
    log(`QSetIgnoredExceptions -> ${ignored || "(unsupported)"}`);
    const signals = [];
    for (let signal = 1; signal <= 31; signal++) {
        if (signal !== 5) signals.push(signal.toString(16));
    }
    const passed = send_command(`QPassSignals:${signals.join(";")}`);
    log(`QPassSignals -> ${passed || "(unsupported)"}`);
}

// Each log() line redraws StikDebug's UI; inside the stop loop use ulog(),
// which stops printing after a fixed number of lines.
let logBudget = 40;
function ulog(msg) {
    if (logBudget > 0) {
        logBudget--;
        log(msg);
    }
}

function looksLikeStop(response) {
    return typeof response === "string" && /^[TSWX]/.test(response);
}

// A stop packet returned by a continue we already sent (vCont;C answers
// with the next stop, so it must not be followed by another `c`).
let pending = null;
    
let totalBreakpoints = 0;
while (!detached) {
    totalBreakpoints++;
    log_verbose(`Handling stop ${totalBreakpoints}`);

    let brkResponse = pending !== null ? pending : send_command(`c`);
    pending = null;
    log_verbose(`brkResponse = ${brkResponse}`);
    if (/^[WX]/.test(brkResponse || "")) {
        log(`Process exited: ${brkResponse}`);
        break;
    }
    
    // extract tid, pc, x16
    let tmpMatch = /T[0-9a-f]+thread:(?<tid>[0-9a-f]+);/.exec(brkResponse);
    tid = tmpMatch ? tmpMatch.groups['tid'] : null;
    tmpMatch = /20:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
    pc = tmpMatch ? tmpMatch.groups['reg'] : null;
    tmpMatch = /10:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
    x16 = tmpMatch ? tmpMatch.groups['reg'] : null;
    if (!tid || !pc || !x16) {
        ulog(`Failed to extract registers: tid=${tid}, pc=${pc}, x16=${x16}`);
        continue;
    }
    pc = littleEndianHexStringToNumber(pc);
    x16 = littleEndianHexStringToNumber(x16);
    
    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log_verbose(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);

    // check if this is a brk
    if ((instrU32 & 0xFFE0001F)>>>0 != 0xD4200000) {
        log_verbose(`Skipping: instruction was not a brk (was 0x${instrU32.toString(16)})`);
        if (continuesWithSignal) {
            let signum = /^T(?<sig>[a-z0-9;]{2})/.exec(brkResponse);
            signum = signum ? signum.groups['sig'] : null;
            if (!signum) {
                ulog(`Failed to extract signal number: ${signum}`);
                continue;
            }
            log_verbose(`Continuing with signal 0x${signum}`);
            // Continue (not single-step) with the signal; the reply is the
            // next stop, which the loop handles without another `c`.
            const resumed = send_command(`vCont;C${signum}:${tid};c`);
            if (looksLikeStop(resumed)) pending = resumed;
        }
        continue;
    }
    
    let brkImmediate = extractBrkImmediate(instrU32);
    log_verbose(`BRK immediate: 0x${brkImmediate.toString(16)} (${brkImmediate})`);
    if (legacyCommands[brkImmediate] != undefined) {
        // when we find a valid brk immediate command, parse x0 and x1
        tmpMatch = /00:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
        x0 = tmpMatch ? tmpMatch.groups['reg'] : null;
        tmpMatch = /01:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
        x1 = tmpMatch ? tmpMatch.groups['reg'] : null;
        if (!x0 || !x1) {
            ulog(`Failed to extract registers: x0=${x0}, x1=${x1}`);
            continue;
        }
        x0 = littleEndianHexStringToNumber(x0);
        x1 = littleEndianHexStringToNumber(x1);
        
        // jump over brk
        let pcPlus4 = numberToLittleEndianHexString(pc + 4n);
        let pcPlus4Response = send_command(`P20=${pcPlus4};thread:${tid};`);
        log_verbose(`pcPlus4Response = ${pcPlus4Response}`);
        
        // dispatch brk-immediate command
        const command = legacyCommands[brkImmediate];
        command(brkResponse);
    } else {
        ulog(`Skipping breakpoint: brk immediate 0x${brkImmediate.toString(16)} was not handled by this script. You could add it by evaluating legacyCommands[0x${brkImmediate.toString(16)}] = yourFunction;`);
        continue;
    }
}

function JIT26Detach() {
    let detachResponse = send_command(`D`);
    log_verbose(`detachResponse = ${detachResponse}`);
    detached = true;
}

// brk 0x68
function JIT26NewBreakpoints(brkResponse) {
    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log_verbose(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    let brkImmediate = extractBrkImmediate(instrU32);
    
    let memResponse = send_command(`m${x0.toString(16)},${x1}`);

    let scriptText = hexToAscii(memResponse);
    log_verbose(`Script text: ${scriptText}`);

    const res = runScriptAndCapture(scriptText);
    if (res.ok) {
        log('Script succeeded:', res.value);
    } else {
        log('Script failed:', res.name, res.message);
        log(res.stack);
    }
}

// brk 0x69
function JIT26HandleBrk0x69(brkResponse) {
    // in the old script we chose 0x69, so now we check here and return error
    // if you wish to keep using this, you can set your own handler like `legacyCommands[0x69] = yourHandler;` using BreakSendJITScript
    log(`Error: It seems you are using legacy breakpoint 0x69. Please set your legacy handler using \`legacyCommands[0x69] = yourHandler;\` or migrate to universal jitcalls to use this script. The function will now return 0xE0000069.`);
    let putX0Response = send_command(`P0=E0000069;thread:${tid};`);
    log(`putX0Response = ${putX0Response}`);
}

// brk 0xf00d
function JIT26HandleBrk0xf00d(brkResponse) {
    // dispatch command via x16
    const command = commands[x16];
    if (command === undefined) {
        log(`Unknown command ${x16.toString(16)}`);
        return;
    }
    log_verbose(`Invoking command ${x16.toString(16)}`);
    command(brkResponse);
}

function JIT26PrepareRegion(brkResponse) {
    let jitPageAddress = x0;
    if (x0 === 0n && x1 > 0n) {
        const response = send_command(`_M${x1.toString(16)},rx`);
        const address = typeof response === "string" ? response.trim().replace(/^0x/i, "") : "";
        if (/^[0-9a-fA-F]{1,16}$/.test(address)) {
            const candidate = BigInt("0x" + address);
            // StikDebug's _M may return a GDB error such as E22. Never
            // interpret it as a successful tiny address or return stale x0.
            if (candidate >= 0x100000000n && candidate % 0x4000n === 0n) {
                jitPageAddress = candidate;
            }
        }
        if (jitPageAddress === 0n) {
            log(`Failed to allocate JIT RX for size 0x${x1.toString(16)} (debugger reply: ${response})`);
        }
    }

    if (jitPageAddress !== 0n && x1 > 0n) {
        try {
            const result = prepare_memory_region(jitPageAddress, x1);
            log_verbose(`prepare_memory_region returned ${result}`);
            if (result === false ||
                (typeof result === "string" && /^E[0-9a-f]+$/i.test(result))) {
                log(`Failed to prepare RX memory: debugger replied ${result}`);
                jitPageAddress = 0n;
            }
        } catch (error) {
            // Never return an RX address when the debugger explicitly failed
            // to prepare that memory. The host must not attempt to use it.
            log(`Failed to prepare RX memory: ${error}`);
            jitPageAddress = 0n;
        }
    }

    const reply = send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);
    log_verbose(`JIT allocation RX=0x${jitPageAddress.toString(16)} reply=${reply}`);
}

// Madeira's ARM64EC init_syscall_frame requests command 3. Never leave x0
// unchanged: a stale address would be mistaken for a successful page-zero map.
function JIT26MapPageZero(brkResponse) {
    let success = 0n;
    if (x0 !== 0n && x1 !== 0n) {
        const tebOffset = x0 & 0x3fffn;
        const tebData = send_command(`m${x0.toString(16)},100`);
        if (/^(?:[a-fA-F0-9]{2})+$/.test(tebData) && tebData.length === 0x200) {
            const response = send_command(`M${tebOffset.toString(16)},100:${tebData}`);
            if (response === "OK") success = 1n;
        }
    }
    send_command(`P0=${numberToLittleEndianHexString(success)};thread:${tid};`);
    log(`Madeira page-zero request: success=${success}`);
}

// utilities
function littleEndianHexStringToNumber(hexStr) {
    if (!/^[0-9a-fA-F]{16}$/.test(hexStr)) {
        throw new Error("Expected exactly eight register bytes");
    }
    let value = 0n;
    for (let i = 7; i >= 0; i--) {
        value = (value << 8n) | BigInt(parseInt(hexStr.slice(i * 2, i * 2 + 2), 16));
    }
    return value;
}

function numberToLittleEndianHexString(value) {
    if (typeof value !== "bigint" || value < 0n || value > 0xffffffffffffffffn) {
        throw new Error("Register value must be an unsigned 64-bit bigint");
    }
    const bytes = [];
    for (let i = 0; i < 8; i++) {
        bytes.push(Number(value & 0xffn).toString(16).padStart(2, "0"));
        value >>= 8n;
    }
    return bytes.join("");
}

function littleEndianHexToU32(hexStr) {
    return parseInt(hexStr.match(/../g).reverse().join(''), 16);
}

function extractBrkImmediate(u32) {
    return (u32 >> 5) & 0xFFFF;
}

function hexToAscii(hexStr) {
    let str = '';
    for (let i = 0; i < hexStr.length; i += 2) {
        const byte = parseInt(hexStr.substr(i, 2), 16);
        if (byte === 0) break;
        str += String.fromCharCode(byte);
    }
    return str;
}

function runScriptAndCapture(scriptText) {
    try {
        const value = eval(scriptText);
        return { ok: true, value };
    } catch (err) {
        return {
            ok: false,
            name: err && err.name,
            message: err && err.message,
            stack: err && err.stack
        };
    }
}

// For making your own script / adding your own breakpoints. you can send this string to BreakSendJITScript and it'll add it for any subsequent breakpoints
// x0, x1, x16, pc and tid are global variables. If you need more registers, parse them like:
// tmpMatch = /02:(?<reg>[0-9a-f]{16});/.exec(brkResponse); // x2
// let x2 = tmpMatch ? tmpMatch.groups['reg'] : null;
// if (!x2) {
//     log(`Failed to extract registers: x2=${x2}`);
//     return;
// }
// x2 = littleEndianHexStringToNumber(x2);
//
/*
commands[3] = wowBreakPoint;

function wowBreakPoint(brekpoint) {
    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log_verbose(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    let brkImmediate = extractBrkImmediate(instrU32);
    
    if (x0 == 0n && x1 == 0n) {
        return;
    }

    let jitPageAddress = x0;
    let prepareJITPageResponse = prepare_memory_region(jitPageAddress, x1);
    log(`prepareJITPageResponse = ${prepareJITPageResponse}`);

    let putX0Response = send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);
    log(`putX0Response = ${putX0Response}`);
}
*/