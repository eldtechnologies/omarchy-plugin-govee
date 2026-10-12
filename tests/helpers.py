"""Load bin/eld-govee as a module, isolated from the real user.

The helper reads HOME and the XDG_* variables when it is imported, so they
point at a throwaway directory before loading: tests never see or touch real
config, state, API keys, Omarchy theme or hooks. A fake secret-tool stands in for the keyring, a local
HTTP server for the Govee cloud, and a UDP responder for a LAN light.
"""

import importlib.machinery
import importlib.util
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLI = str(ROOT / "bin" / "eld-govee")
SANDBOX = tempfile.mkdtemp(prefix="eld-govee-test-")
os.chmod(SANDBOX, 0o700)
os.environ["HOME"] = os.path.join(SANDBOX, "home")
os.makedirs(os.environ["HOME"], mode=0o700)
for name in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
    path = os.path.join(SANDBOX, name.lower())
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.environ[name] = path

# A secret-tool that keeps the "keyring" in a sandbox file.
FAKE_BIN = os.path.join(SANDBOX, "bin")
os.makedirs(FAKE_BIN)
KEYRING_FILE = os.path.join(SANDBOX, "keyring")
with open(os.path.join(FAKE_BIN, "secret-tool"), "w") as handle:
    handle.write(f"""#!/bin/sh
case "$1" in
  store) cat > "{KEYRING_FILE}" ;;
  lookup) [ -f "{KEYRING_FILE}" ] && cat "{KEYRING_FILE}" || exit 1 ;;
  clear) rm -f "{KEYRING_FILE}" ;;
esac
""")
os.chmod(os.path.join(FAKE_BIN, "secret-tool"), 0o755)
os.environ["PATH"] = FAKE_BIN + os.pathsep + os.environ.get("PATH", "")

API_KEY = "test-key-1234-abcd"
LAN_ID = "AA:BB:CC:DD:EE:FF:00:11"
CLOUD_ID = "11:22:33:44:55:66:77:88"
PLUG_ID = "99:88:77:66:55:44:33:22"


def free_port(kind=socket.SOCK_DGRAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def cap(cap_type, instance, parameters=None):
    return {"type": f"devices.capabilities.{cap_type}", "instance": instance,
            "parameters": parameters or {}}


LIGHT_CAPS = [
    cap("on_off", "powerSwitch"),
    cap("range", "brightness", {"range": {"min": 1, "max": 100}}),
    cap("color_setting", "colorRgb"),
    cap("color_setting", "colorTemperatureK", {"range": {"min": 2000, "max": 9000}}),
    cap("dynamic_scene", "lightScene"),
]


class FakeCloud:
    """The subset of openapi.api.govee.com the helper uses."""

    def __init__(self):
        self.controls = []
        self.requests = []
        self.devices = [
            {"sku": "H6008", "device": LAN_ID, "deviceName": "Desk Lamp",
             "type": "devices.types.light", "capabilities": LIGHT_CAPS},
            {"sku": "H6159", "device": CLOUD_ID, "deviceName": "Shelf Strip",
             "type": "devices.types.light", "capabilities": LIGHT_CAPS},
            {"sku": "H5080", "device": PLUG_ID, "deviceName": "Fan Plug",
             "type": "devices.types.socket", "capabilities": [cap("on_off", "powerSwitch")]},
            # Not switchable: must be ignored.
            {"sku": "H5179", "device": "01:02:03:04:05:06:07:08", "deviceName": "Thermometer",
             "type": "devices.types.thermometer", "capabilities": []},
        ]
        self.state = {CLOUD_ID: {"powerSwitch": 0, "brightness": 40, "colorRgb": 0xFF0000,
                                 "colorTemperatureK": 0, "online": True},
                      PLUG_ID: {"powerSwitch": 1, "online": True},
                      LAN_ID: {"powerSwitch": 0, "brightness": 10, "colorRgb": 0, "online": True}}
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def authorized(self):
                fake.requests.append(self.path)
                if self.headers.get("Govee-API-Key") != API_KEY:
                    self.reply(401, {"code": 401, "message": "Invalid API Key"})
                    return False
                return True

            def do_GET(self):
                if not self.authorized():
                    return
                if self.path == "/user/devices":
                    self.reply(200, {"code": 200, "message": "success", "data": fake.devices})
                else:
                    self.reply(404, {"code": 404, "msg": "not found"})

            def do_POST(self):
                if not self.authorized():
                    return
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                payload = body["payload"]
                device = payload["device"]
                if self.path == "/device/state":
                    values = fake.state.get(device, {})
                    caps = [{"type": "devices.capabilities.online", "instance": "online",
                             "state": {"value": values.get("online", True)}}]
                    for instance, kind in (("powerSwitch", "on_off"), ("brightness", "range"),
                                           ("colorRgb", "color_setting"),
                                           ("colorTemperatureK", "color_setting")):
                        if instance in values:
                            caps.append({"type": f"devices.capabilities.{kind}", "instance": instance,
                                         "state": {"value": values[instance]}})
                    self.reply(200, {"code": 200, "msg": "success",
                                     "payload": {"sku": payload["sku"], "device": device,
                                                 "capabilities": caps}})
                elif self.path == "/device/control":
                    capability = payload["capability"]
                    fake.controls.append((device, capability["instance"], capability["value"]))
                    fake.state.setdefault(device, {})[capability["instance"]] = capability["value"]
                    self.reply(200, {"code": 200, "msg": "success"})
                elif self.path == "/device/scenes":
                    options = [{"name": "Sunrise", "value": {"paramId": 1, "id": 11}},
                               {"name": "Aurora", "value": {"paramId": 2, "id": 22}}]
                    self.reply(200, {"code": 200, "msg": "success", "payload": {"capabilities": [{
                        "type": "devices.capabilities.dynamic_scene", "instance": "lightScene",
                        "parameters": {"dataType": "ENUM", "options": options}}]}})
                elif self.path == "/device/diy-scenes":
                    self.reply(200, {"code": 200, "msg": "success", "payload": {"capabilities": []}})
                else:
                    self.reply(404, {"code": 404, "msg": "not found"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class FakeLanLight:
    """One light speaking the Govee LAN protocol on 127.0.0.1."""

    def __init__(self, device_id=LAN_ID, sku="H6008"):
        self.device_id, self.sku = device_id, sku
        self.scan_port, self.listen_port, self.control_port = free_port(), free_port(), free_port()
        self.commands = []
        self.answer_status = True
        self.status = {"onOff": 0, "brightness": 10, "color": {"r": 0, "g": 0, "b": 0},
                       "colorTemInKelvin": 3000}
        self.sockets = []
        for port in (self.scan_port, self.control_port):
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.bind(("127.0.0.1", port))
            sock.settimeout(0.2)
            self.sockets.append(sock)
        self.running = True
        self.threads = [threading.Thread(target=self.serve, args=(s,), daemon=True) for s in self.sockets]
        for thread in self.threads:
            thread.start()

    @property
    def env(self):
        return f"127.0.0.1:{self.scan_port}:{self.listen_port}:{self.control_port}"

    def serve(self, sock):
        while self.running:
            try:
                raw, (ip, _port) = sock.recvfrom(4096)
            except (socket.timeout, OSError):
                continue
            msg = json.loads(raw)["msg"]
            cmd, data = msg["cmd"], msg["data"]
            if cmd == "scan":
                self.send(ip, {"cmd": "scan", "data": {"ip": "10.9.9.9", "device": self.device_id,
                                                         "sku": self.sku}})
            elif cmd == "devStatus":
                if self.answer_status:
                    self.send(ip, {"cmd": "devStatus", "data": self.status})
            else:
                self.commands.append((cmd, data))
                if cmd == "turn":
                    self.status["onOff"] = data["value"]
                elif cmd == "brightness":
                    self.status["brightness"] = data["value"]
                elif cmd == "colorwc":
                    self.status["color"] = data["color"]
                    self.status["colorTemInKelvin"] = data["colorTemInKelvin"]

    def send(self, ip, msg):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as out:
            out.sendto(json.dumps({"msg": msg}).encode(), (ip, self.listen_port))

    def close(self):
        self.running = False
        for thread in self.threads:
            thread.join()
        for sock in self.sockets:
            sock.close()


def run_cli(*args, env=None, stdin=None):
    full = dict(os.environ, **(env or {}))
    return subprocess.run([sys.executable, CLI, *args], input=stdin, capture_output=True,
                          text=True, env=full, timeout=30)


def load_helper():
    loader = importlib.machinery.SourceFileLoader("eld_govee", CLI)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helper = load_helper()
