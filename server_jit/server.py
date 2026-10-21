import base64
import binascii
import hmac
import http.server
import ipaddress
import json
import os
import socketserver
import subprocess
import sys
import tempfile
import urllib.parse

PORT = int(os.environ.get("JIT_SERVER_PORT", "54321"))
HOST = os.environ.get("JIT_SERVER_HOST", "127.0.0.1")
TOKEN = os.environ.get("JIT_SERVER_TOKEN", "")
MAX_BODY = 1024 * 1024  # 1 MiB
TIMEOUT = 120


def _is_loopback(host):
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host == "localhost"


class JITHandler(http.server.BaseHTTPRequestHandler):
    def _reply(self, status, message):
        body = message.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if not TOKEN:
            return True
        supplied = self.headers.get("X-JIT-Token", "")
        return hmac.compare_digest(supplied.encode(), TOKEN.encode())

    def _run(self, args):
        subprocess.run(args, check=True, timeout=TIMEOUT)

    def do_POST(self):
        if not self._authorized():
            self._reply(401, "Unauthorized")
            return

        path = urllib.parse.urlparse(self.path).path

        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._reply(400, "Invalid Content-Length")
            return
        if length < 0 or length > MAX_BODY:
            self._reply(413, "Payload Too Large")
            return
        raw = self.rfile.read(length)

        if path in ("/enable_jit", "/enable_jit_vpn"):
            self._enable_jit(path, raw)
        elif path == "/mount_ddi":
            try:
                self._run(["pymobiledevice3", "mounter", "auto-mount"])
                self._reply(200, "DDI Mounted")
            except (subprocess.SubprocessError, OSError):
                self._reply(500, "DDI Mount Failed")
        else:
            self._reply(404, "Endpoint Not Found")

    def _enable_jit(self, path, raw):
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._reply(400, "Invalid JSON")
            return

        pid = body.get("pid") if isinstance(body, dict) else None
        # bool is a subclass of int; reject it explicitly.
        if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
            self._reply(400, "Invalid PID")
            return

        pairing_file_path = None
        try:
            pairing_data = body.get("pairing_data")
            if pairing_data is not None:
                if not isinstance(pairing_data, str):
                    self._reply(400, "Invalid pairing data")
                    return
                try:
                    decoded = base64.b64decode(pairing_data, validate=True)
                except (binascii.Error, ValueError):
                    self._reply(400, "Invalid pairing data")
                    return
                fd, pairing_file_path = tempfile.mkstemp(suffix=".mobiledevicepairing")
                with os.fdopen(fd, "wb") as f:
                    f.write(decoded)

            args = ["pymobiledevice3", "developer", "debugserver", "attach", "--pid", str(pid)]
            if path == "/enable_jit_vpn":
                args.append("--network-vpn")
            if pairing_file_path:
                args += ["--pairing-record", pairing_file_path]

            self._run(args)
            self._reply(200, "JIT Activated")
        except (subprocess.SubprocessError, OSError):
            self._reply(500, "JIT Failed")
        finally:
            if pairing_file_path and os.path.exists(pairing_file_path):
                os.remove(pairing_file_path)

    def do_GET(self):
        self._reply(405, "Method Not Allowed")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main():
    if not _is_loopback(HOST) and not TOKEN:
        sys.exit(
            "Refusing to listen on a non-loopback address without JIT_SERVER_TOKEN set."
        )
    with Server((HOST, PORT), JITHandler) as httpd:
        print(f"JIT server listening on {HOST}:{PORT}")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
