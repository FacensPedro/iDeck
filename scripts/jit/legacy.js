function littleEndianHexStringToNumber(hexStr) {
    const bytes = [];
    for (let i = 0; i < hexStr.length; i += 2) bytes.push(parseInt(hexStr.substr(i, 2), 16));
    let num = 0n;
    for (let i = 4; i >= 0; i--) num = (num << 8n) | BigInt(bytes[i]);
    return num;
}
function numberToLittleEndianHexString(num) {
    const bytes = [];
    for (let i = 0; i < 5; i++) { bytes.push(Number(num & 0xFFn)); num >>= 8n; }
    while (bytes.length < 8) bytes.push(0);
    return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
}
function littleEndianHexToU32(hexStr) { return parseInt(hexStr.match(/../g).reverse().join(''), 16); }
function extractBrkImmediate(u32) { return (u32 >>> 5) & 0xFFFF; }
function attach(breakpointcount) {
    const pid = get_pid();
    log(`pid = ${pid}`);
    log(`attach_response = ${send_command(`vAttach;${pid.toString(16)}`)}`);
    let validBreakpoints = 0;
    let totalBreakpoints = 0;
    try {
        while (validBreakpoints < breakpointcount) {
            totalBreakpoints++;
            log(`Handling breakpoint ${totalBreakpoints} (looking for valid breakpoint ${validBreakpoints + 1}/${breakpointcount})`);
            const response = send_command('c');
            const tidMatch = /T[0-9a-f]+thread:(?<tid>[0-9a-f]+);/.exec(response);
            const tid = tidMatch?.groups?.tid;
            const pcMatch = /20:(?<reg>[0-9a-f]{16});/.exec(response);
            const x0Match = /00:(?<reg>[0-9a-f]{16});/.exec(response);
            const x1Match = /01:(?<reg>[0-9a-f]{16});/.exec(response);
            if (!tid || !pcMatch || !x0Match || !x1Match) throw new Error('Failed to extract registers');
            const pc = littleEndianHexStringToNumber(pcMatch.groups.reg);
            const x0 = littleEndianHexStringToNumber(x0Match.groups.reg);
            const x1 = littleEndianHexStringToNumber(x1Match.groups.reg);
            const instruction = littleEndianHexToU32(send_command(`m${pc.toString(16)},4`));
            const immediate = extractBrkImmediate(instruction);
            if (immediate !== 0x69) continue;
            const result = prepare_memory_region(x0, x1);
            log(`prepare_memory_region = ${result}`);
            log(`PC update = ${send_command(`P20=${numberToLittleEndianHexString(pc + 4n)};thread:${tid};`)}`);
            validBreakpoints++;
        }
    } finally {
        log(`detach_response = ${send_command('D')}`);
    }
}
attach(1);
