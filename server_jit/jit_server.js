const http = require('http');
const { execFile } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PORT = parseInt(process.env.JIT_SERVER_PORT || '54321', 10);
const HOST = process.env.JIT_SERVER_HOST || '127.0.0.1';
const TOKEN = process.env.JIT_SERVER_TOKEN || '';
const MAX_BODY = 1024 * 1024; // 1 MiB
const TIMEOUT_MS = 120000;

function isLoopback(host) {
    return host === 'localhost' || host === '::1' || /^127\./.test(host);
}

function authorized(req) {
    if (!TOKEN) return true;
    const supplied = Buffer.from(String(req.headers['x-jit-token'] || ''));
    const expected = Buffer.from(TOKEN);
    return supplied.length === expected.length && crypto.timingSafeEqual(supplied, expected);
}

function reply(res, status, message) {
    res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(message);
}

function enableJIT(res, pathname, raw) {
    let data;
    try {
        data = JSON.parse(raw);
    } catch (e) {
        return reply(res, 400, 'Invalid JSON');
    }

    const pid = data && data.pid;
    if (!Number.isInteger(pid) || pid <= 0) {
        return reply(res, 400, 'Invalid PID');
    }

    let pairingFilePath = null;
    const cleanup = () => {
        if (pairingFilePath && fs.existsSync(pairingFilePath)) {
            fs.unlinkSync(pairingFilePath);
        }
    };

    try {
        if (data.pairing_data !== undefined && data.pairing_data !== null) {
            if (typeof data.pairing_data !== 'string' ||
                !/^[A-Za-z0-9+/]*={0,2}$/.test(data.pairing_data)) {
                return reply(res, 400, 'Invalid pairing data');
            }
            const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'jit-'));
            pairingFilePath = path.join(dir, 'pairing.mobiledevicepairing');
            fs.writeFileSync(pairingFilePath, Buffer.from(data.pairing_data, 'base64'), { mode: 0o600 });
        }

        const args = ['developer', 'debugserver', 'attach', '--pid', String(pid)];
        if (pathname === '/enable_jit_vpn') args.push('--network-vpn');
        if (pairingFilePath) args.push('--pairing-record', pairingFilePath);

        execFile('pymobiledevice3', args, { timeout: TIMEOUT_MS }, (error) => {
            if (pairingFilePath) {
                cleanup();
                try { fs.rmdirSync(path.dirname(pairingFilePath)); } catch (e) { /* ignore */ }
            }
            if (error) return reply(res, 500, 'JIT Failed');
            reply(res, 200, 'JIT Activated');
        });
    } catch (e) {
        cleanup();
        reply(res, 500, 'Internal Error');
    }
}

const server = http.createServer((req, res) => {
    if (req.method !== 'POST') {
        return reply(res, 405, 'Method Not Allowed');
    }
    if (!authorized(req)) {
        return reply(res, 401, 'Unauthorized');
    }

    const pathname = new URL(req.url, 'http://localhost').pathname;
    let body = '';
    let size = 0;
    let aborted = false;

    req.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_BODY) {
            aborted = true;
            reply(res, 413, 'Payload Too Large');
            req.destroy();
            return;
        }
        body += chunk.toString();
    });

    req.on('end', () => {
        if (aborted) return;
        if (pathname === '/enable_jit' || pathname === '/enable_jit_vpn') {
            enableJIT(res, pathname, body);
        } else if (pathname === '/mount_ddi') {
            execFile('pymobiledevice3', ['mounter', 'auto-mount'], { timeout: TIMEOUT_MS }, (error) => {
                if (error) return reply(res, 500, 'DDI Mount Failed');
                reply(res, 200, 'DDI Mounted');
            });
        } else {
            reply(res, 404, 'Endpoint Not Found');
        }
    });
});

if (!isLoopback(HOST) && !TOKEN) {
    console.error('Refusing to listen on a non-loopback address without JIT_SERVER_TOKEN set.');
    process.exit(1);
}

server.listen(PORT, HOST, () => {
    console.log(`JIT server listening on ${HOST}:${PORT}`);
});
