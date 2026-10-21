const http = require('http');
const { exec } = require('child_process');
const url = require('url');

const PORT = 54321;

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const pathname = parsedUrl.pathname;
    const query = parsedUrl.query;

    if (pathname === '/enable_jit' || pathname === '/enable_jit_vpn') {
        const pid = query.pid;
        if (!pid) {
            res.writeHead(400);
            res.end('Missing PID');
            return;
        }

        const networkFlag = pathname === '/enable_jit_vpn' ? '--network-vpn' : '';
        const command = `pymobiledevice3 developer debugserver attach --pid ${pid} ${networkFlag}`;
        
        exec(command, (error, stdout, stderr) => {
            if (error) {
                res.writeHead(500);
                res.end('JIT Failed');
                return;
            }
            res.writeHead(200);
            res.end('JIT Activated');
        });
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

server.listen(PORT, '0.0.0.0');
