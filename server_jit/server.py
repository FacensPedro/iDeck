import http.server
import socketserver
import subprocess
import urllib.parse

PORT = 54321

class JITHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed_url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed_url.query)

        if parsed_url.path in ['/enable_jit', '/enable_jit_vpn']:
            pid = query.get('pid', [None])[0]
            if not pid:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'Missing PID')
                return

            network_flag = '--network-vpn' if parsed_url.path == '/enable_jit_vpn' else ''
            command = f"pymobiledevice3 developer debugserver attach --pid {pid} {network_flag}"
            
            try:
                subprocess.run(command, shell=True, check=True)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'JIT Activated')
            except subprocess.CalledProcessError:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'JIT Failed')
                
        elif parsed_url.path == '/mount_ddi':
            command = "pymobiledevice3 mounter auto-mount"
            try:
                subprocess.run(command, shell=True, check=True)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'DDI Mounted')
            except subprocess.CalledProcessError:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'DDI Mount Failed')
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Endpoint Not Found')

with socketserver.TCPServer(("0.0.0.0", PORT), JITHandler) as httpd:
    httpd.serve_forever()
