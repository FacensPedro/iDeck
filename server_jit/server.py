import hmac
import http.server
import ipaddress
import json
import os
import socket
import socketserver
import subprocess
import sys
import time
import urllib.parse

PORT = int(os.environ.get("JIT_SERVER_PORT", "54321"))
HOST = os.environ.get("JIT_SERVER_HOST", "127.0.0.1")
TOKEN = os.environ.get("JIT_SERVER_TOKEN", "")
MAX_BODY = 1024 * 1024  # 1 MiB
TIMEOUT = 120
UDID = os.environ.get("JIT_SERVER_UDID", "")      # optional: target device (default: first USB device)
TUNNEL = os.environ.get("JIT_SERVER_TUNNEL", "")  # optional (iOS 17+): tunneld UDID to use
ATTACH_TIMEOUT = 30


class JITError(Exception):
    pass


def gdb_packet(payload: bytes) -> bytes:
    """Frames a GDB remote-protocol packet: $<payload>#<checksum>."""
    return b"$" + payload + b"#" + b"%02x" % (sum(payload) % 256)


def gdb_read_packet(sock: socket.socket) -> bytes:
    """Reads one packet, acknowledging it with '+'. Leading ack characters are skipped."""
    buf = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            raise JITError("debugserver closed the connection")
        buf += chunk
        start = buf.find(b"$")
        if start != -1:
            end = buf.find(b"#", start)
            if end != -1 and len(buf) >= end + 3:
                payload = buf[start + 1:end]
                if int(buf[end + 1:end + 3], 16) != sum(payload) % 256:
                    sock.sendall(b"-")
                    raise JITError("bad checksum from debugserver")
                sock.sendall(b"+")
                return payload


def gdb_attach_and_detach(sock: socket.socket, pid: int) -> None:
    """vAttach makes the debugger the process' tracer (this is what grants JIT), then detach."""
    sock.sendall(gdb_packet(b"vAttach;%x" % pid))
    reply = gdb_read_packet(sock)
    if reply.startswith(b"E"):
        raise JITError("debugserver refused to attach: " + reply.decode(errors="replace"))
    sock.sendall(gdb_packet(b"D"))
    try:
        gdb_read_packet(sock)
    except (JITError, OSError):
        pass  # the connection may close right after detaching


def _wait_for_endpoint(proc: subprocess.Popen, local_port: int):
    """Returns (host, port) of the debugserver once pymobiledevice3 exposes it."""
    deadline = time.time() + ATTACH_TIMEOUT
    while time.time() < deadline:
        if proc.poll() is not None:
            raise JITError("pymobiledevice3 exited early (is the device connected and paired?)")
        try:
            with socket.create_connection(("127.0.0.1", local_port), timeout=1):
                return "127.0.0.1", local_port
        except OSError:
            time.sleep(0.3)
    raise JITError("timed out waiting for debugserver")


def enable_jit(pid: int) -> None:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        local_port = probe.getsockname()[1]

    cmd = ["pymobiledevice3", "developer", "debugserver", "start-server", "--local-port", str(local_port)]
    if UDID:
        cmd += ["--udid", UDID]
    if TUNNEL:
        cmd += ["--tunnel", TUNNEL]

    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        host, port = _wait_for_endpoint(proc, local_port)
        with socket.create_connection((host, port), timeout=ATTACH_TIMEOUT) as sock:
            sock.settimeout(ATTACH_TIMEOUT)
            gdb_attach_and_detach(sock, pid)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


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

        if path in ("/enable_jit", "/enable_jit_vpn"):  # both do the same; the VPN variant is kept for compatibility
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

        try:
            enable_jit(pid)
            self._reply(200, "JIT Activated")
        except JITError as error:
            self._reply(500, "JIT Failed: " + str(error))
        except (subprocess.SubprocessError, OSError) as error:
            self._reply(500, "JIT Failed: " + str(error))

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
