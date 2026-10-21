import http.server
import socketserver
import subprocess
import urllib.parse
import json
import base64
import os
import tempfile

PORT = 54321

class JITHandler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        parsed_url = urllib.parse.urlparse(self.path)
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)
        
        if parsed_url.path in ['/enable_jit', '/enable_jit_vpn']:
            try:
                body = json.loads(post_data.decode('utf-8'))
                pid = body.get('pid')
                pairing_data = body.get('pairing_data')
                
                if not pid:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b'Missing PID')
                    return
                
                pairing_file_path = None
                if pairing_data:
                    fd, pairing_file_path = tempfile.mkstemp(suffix=".mobiledevicepairing")
                    with os.fdopen(fd, 'wb') as f:
                        f.write(base64.b64decode(pairing_data))
                
                network_flag = '--network-vpn' if parsed_url.path == '/enable_jit_vpn' else ''
                pairing_flag = f"--pairing-record {pairing_file_path}" if pairing_file_path else ''
                
                command = f"pymobiledevice3 developer debugserver attach --pid {pid} {network_flag} {pairing_flag}"
                
                subprocess.run(command, shell=True, check=True)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'JIT Activated')
                
            except Exception:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'JIT Failed')
            finally:
                if 'pairing_file_path' in locals() and pairing_file_path and os.path.exists(pairing_file_path):
                    os.remove(pairing_file_path)
                    
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
