const http = require('http');
const { exec } = require('child_process');
const url = require('url');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PORT = 54321;

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const pathname = parsedUrl.pathname;

    if (req.method === 'POST') {
        let body = '';
        req.on('data', chunk => {
            body += chunk.toString();
        });

        req.on('end', () => {
            if (pathname === '/enable_jit' || pathname === '/enable_jit_vpn') {
                try {
                    const data = JSON.parse(body);
                    const pid = data.pid;
                    const pairingData = data.pairing_data;

                    if (!pid) {
                        res.writeHead(400);
                        res.end('Missing PID');
                        return;
                    }

                    let pairingFilePath = '';
                    if (pairingData) {
                        pairingFilePath = path.join(os.tmpdir(), `temp_${Date.now()}.mobiledevicepairing`);
                        fs.writeFileSync(pairingFilePath, Buffer.from(pairingData, 'base64'));
                    }

                    const networkFlag = pathname === '/enable_jit_vpn' ? '--network-vpn' : '';
                    const pairingFlag = pairingFilePath ? `--pairing-record ${pairingFilePath}` : '';
                    
                    const command = `pymobiledevice3 developer debugserver attach --pid ${pid} ${networkFlag} ${pairingFlag}`;
                    
                    exec(command, (error, stdout, stderr) => {
                        if (pairingFilePath && fs.existsSync(pairingFilePath)) {
                            fs.unlinkSync(pairingFilePath);
                        }
                        
                        if (error) {
                            res.writeHead(500);
                            res.end('JIT Failed');
                            return;
                        }
                        res.writeHead(200);
                        res.end('JIT Activated');
                    });
                } catch (e) {
                    res.writeHead(500);
                    res.end('Internal Error');
                }
            } else if (pathname === '/mount_ddi') {
                const command = `pymobiledevice3 mounter auto-mount`;
                exec(command, (error, stdout, stderr) => {
                    if (error) {
                        res.writeHead(500);
                        res.end('DDI Mount Failed');
                        return;
                    }
                    res.writeHead(200);
                    res.end('DDI Mounted');
                });
            } else {
                res.writeHead(404);
                res.end('Endpoint Not Found');
            }
        });
    } else {
        res.writeHead(405);
        res.end('Method Not Allowed');
    }
});

server.listen(PORT, '0.0.0.0');
