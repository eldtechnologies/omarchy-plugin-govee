"""Run the real CLI against a fake Govee cloud and a fake LAN light."""

import json
import os
import shutil
import stat
import tempfile
import unittest

from helpers import API_KEY, CLOUD_ID, KEYRING_FILE, LAN_ID, NOTIFY_LOG, PLUG_ID, FakeCloud, FakeLanLight, run_cli


class Sandbox(unittest.TestCase):
    """A fresh config and state directory per test."""

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="eld-govee-e2e-")
        self.cloud = FakeCloud()
        self.light = FakeLanLight()
        self.env = {
            "HOME": self.home,
            "XDG_CONFIG_HOME": os.path.join(self.home, "config"),
            "XDG_STATE_HOME": os.path.join(self.home, "state"),
            "ELD_GOVEE_TEST_API_BASE": self.cloud.url,
            "ELD_GOVEE_TEST_LAN": self.light.env,
        }
        if os.path.exists(KEYRING_FILE):
            os.remove(KEYRING_FILE)

    def tearDown(self):
        self.cloud.close()
        self.light.close()
        shutil.rmtree(self.home, ignore_errors=True)

    def cli(self, *args, stdin=None, ok=True):
        result = run_cli(*args, env=self.env, stdin=stdin)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def state(self):
        with open(os.path.join(self.home, "state", "eld-govee", "state.json")) as handle:
            return json.load(handle)

    def device(self, device_id):
        return next(d for d in self.state()["devices"] if d["id"] == device_id)

    def setup_key(self):
        return json.loads(self.cli("setup-save", stdin=API_KEY + "\n").stdout)


class Setup(Sandbox):
    def test_key_goes_to_the_keyring_not_the_config(self):
        result = self.setup_key()
        self.assertEqual(result["keyStore"], "keyring")
        self.assertEqual(result["devices"], 3)
        with open(KEYRING_FILE) as handle:
            self.assertEqual(handle.read().strip(), API_KEY)
        config_path = os.path.join(self.home, "config", "eld-govee", "config.json")
        with open(config_path) as handle:
            self.assertNotIn(API_KEY, handle.read())
        self.assertEqual(stat.S_IMODE(os.stat(config_path).st_mode), 0o600)

    def test_rejected_key_is_not_stored(self):
        result = self.cli("setup-save", stdin="wrong-key-0000\n", ok=False)
        self.assertIn("rejected", result.stderr)
        self.assertFalse(os.path.exists(KEYRING_FILE))

    def test_lan_only(self):
        result = json.loads(self.cli("setup-save", "--lan-only").stdout)
        self.assertEqual(result["keyStore"], "none")
        devices = self.state()["devices"]
        self.assertEqual([d["id"] for d in devices], [LAN_ID])
        self.assertEqual(self.cloud.requests, [])

    def test_lan_only_lights_can_be_renamed_and_reset(self):
        self.cli("setup-save", "--lan-only")
        self.assertEqual(self.device(LAN_ID)["name"], "H6008 0011")
        self.cli("rename", LAN_ID, "Floor Lamp")
        self.assertEqual(self.device(LAN_ID)["name"], "Floor Lamp")
        self.cli("on", "floor lamp")  # the new name works as a target
        self.assertIn(("turn", {"value": 1}), self.light.commands)
        self.cli("rename", LAN_ID, "")
        self.assertEqual(self.device(LAN_ID)["name"], "H6008 0011")

    def test_unconfigured_commands_say_so(self):
        self.assertIn("not set up", self.cli("on", ok=False).stderr)


class Discovery(Sandbox):
    def test_lan_and_cloud_devices_merge(self):
        self.setup_key()
        lamp = self.device(LAN_ID)
        self.assertTrue(lamp["lan"])
        self.assertEqual(lamp["name"], "Desk Lamp")
        self.assertEqual(lamp["via"], "lan")
        self.assertEqual(lamp["colorTemp"], 3000)
        strip = self.device(CLOUD_ID)
        self.assertFalse(strip["lan"])
        self.assertEqual((strip["power"], strip["brightness"], strip["color"]), (False, 40, "#ff0000"))

    def test_lan_device_state_never_costs_a_cloud_request(self):
        self.setup_key()
        self.assertNotIn(LAN_ID, json.dumps([r for r in self.cloud.requests if "state" in r]))

    def test_address_comes_from_the_packet_not_the_payload(self):
        self.setup_key()
        cache = os.path.join(self.home, "state", "eld-govee", "cache.json")
        with open(cache) as handle:
            self.assertEqual(json.load(handle)["lan"][LAN_ID]["ip"], "127.0.0.1")

    def test_lan_only_light_shows_offline_when_it_stops_answering(self):
        self.cli("setup-save", "--lan-only")
        self.light.close()
        self.light = FakeLanLight(device_id="AB:AB:AB:AB:AB:AB:AB:AB")
        self.env["ELD_GOVEE_TEST_LAN"] = self.light.env
        self.cli("poll", "--max-age", "0")
        self.assertIs(self.device(LAN_ID)["online"], False)


class Control(Sandbox):
    def setUp(self):
        super().setUp()
        self.setup_key()

    def test_lan_light_is_driven_locally(self):
        self.cli("brightness", "Desk Lamp", "60")
        # Off before: woken first, then dimmed.
        self.assertEqual(self.light.commands, [("turn", {"value": 1}), ("brightness", {"value": 60})])
        self.assertEqual(self.cloud.controls, [])
        lamp = self.device(LAN_ID)
        self.assertEqual((lamp["power"], lamp["brightness"]), (True, 60))

    def test_lan_falls_back_to_cloud_when_the_light_is_silent(self):
        self.light.answer_status = False
        self.cli("on", "Desk Lamp")
        self.assertIn((LAN_ID, "powerSwitch", 1), self.cloud.controls)

    def test_cloud_light(self):
        self.cli("color", "Shelf Strip", "#00ff80")
        self.assertEqual(self.cloud.controls, [(CLOUD_ID, "powerSwitch", 1),
                                               (CLOUD_ID, "colorRgb", 0x00FF80)])
        self.assertEqual(self.device(CLOUD_ID)["color"], "#00ff80")

    def test_temperature_is_clamped_to_the_device_range(self):
        self.cli("temp", "Shelf Strip", "10000")
        self.assertIn((CLOUD_ID, "colorTemperatureK", 9000), self.cloud.controls)

    def test_toggle_all_turns_everything_off_when_anything_is_on(self):
        self.cli("toggle")  # the plug is on
        self.assertIn((PLUG_ID, "powerSwitch", 0), self.cloud.controls)
        self.assertFalse(any(d["power"] for d in self.state()["devices"]))

    def test_relative_brightness(self):
        self.cli("brightness", "Shelf Strip", "+15")
        self.assertIn((CLOUD_ID, "brightness", 55), self.cloud.controls)

    def test_scene_by_name(self):
        self.cli("scene", "Shelf Strip", "aurora")
        self.assertIn((CLOUD_ID, "lightScene", {"paramId": 2, "id": 22}), self.cloud.controls)
        scenes = json.loads(self.cli("scenes", "Shelf Strip", "--json").stdout)
        self.assertEqual([s["name"] for s in scenes], ["Sunrise", "Aurora"])

    def test_unsupported_action_is_refused(self):
        result = self.cli("brightness", "Fan Plug", "50", ok=False)
        self.assertIn("support", result.stderr)

    def test_failure_rolls_back_and_records_the_error(self):
        self.cloud.state[CLOUD_ID]["powerSwitch"] = 0
        self.cloud.close()  # cloud gone
        result = self.cli("on", "Shelf Strip", ok=False)
        self.assertIn("cannot reach", result.stderr)
        self.assertIs(self.device(CLOUD_ID)["power"], False)
        self.assertIn("cannot reach", self.state()["error"]["message"])
        self.cli("dismiss")
        self.assertIsNone(self.state()["error"])
        self.cloud = FakeCloud()  # for tearDown

    def test_groups(self):
        self.cli("group", "set", "Office", "Desk Lamp", "Shelf Strip")
        self.cli("off", "office")
        group = self.state()["groups"][0]
        self.assertEqual((group["name"], group["members"], group["power"]),
                         ("Office", [LAN_ID, CLOUD_ID], False))
        self.cli("on", "Office")
        self.assertEqual(self.state()["groups"][0]["onCount"], 2)
        self.cli("group", "remove", "office")
        self.assertEqual(self.state()["groups"], [])

    def test_editing_groups_keeps_lan_lights_on_the_lan(self):
        self.cli("group", "set", "Office", "Desk Lamp")
        self.assertTrue(self.device(LAN_ID)["lan"])
        self.cli("on", "Office")
        self.assertEqual(self.cloud.controls, [])
        self.assertIn(("turn", {"value": 1}), self.light.commands)

    def test_rename_and_hide(self):
        self.cli("rename", "Shelf Strip", "Bookcase")
        self.assertEqual(self.device(CLOUD_ID)["name"], "Bookcase")
        self.cli("hide", "Fan Plug")
        self.cli("off")
        self.assertNotIn((PLUG_ID, "powerSwitch", 0), self.cloud.controls)

    def test_usage_is_counted(self):
        self.cli("on", "Shelf Strip")
        self.assertGreater(self.state()["usage"]["today"], 0)

    def test_forget_key(self):
        self.cli("forget-key")
        self.assertFalse(os.path.exists(KEYRING_FILE))
        self.assertFalse(self.state()["configured"])


class FollowTheme(Sandbox):
    """Lights that take the Omarchy theme's colour."""

    def setUp(self):
        super().setUp()
        self.setup_key()
        self.hook = os.path.join(self.home, ".config", "omarchy", "hooks", "theme-set.d", "eld-govee")
        self.set_theme("00ff80")

    def set_theme(self, rgb):
        theme = os.path.join(self.home, ".local", "state", "omarchy", "current", "theme")
        os.makedirs(theme, exist_ok=True)
        with open(os.path.join(theme, "keyboard.rgb"), "w") as handle:
            handle.write(rgb + "\n")

    def colours_sent(self):
        return [data["color"] for cmd, data in self.light.commands if cmd == "colorwc"]

    def test_following_installs_the_hook_and_recolours_a_lit_light(self):
        self.cli("on", "Desk Lamp")
        self.cli("theme", "follow", "Desk Lamp")
        self.assertEqual(self.colours_sent(), [{"r": 0, "g": 255, "b": 128}])
        self.assertTrue(os.access(self.hook, os.X_OK))
        with open(self.hook) as handle:
            self.assertIn("theme apply", handle.read())
        self.assertTrue(self.device(LAN_ID)["followsTheme"])
        self.assertEqual(self.state()["theme"]["color"], "#00ff80")

    def test_a_theme_change_leaves_lights_that_are_off_alone(self):
        self.cli("theme", "follow", "Desk Lamp")  # it is off
        self.set_theme("ff0000")
        self.cli("theme", "apply")
        self.assertEqual(self.light.commands, [])
        self.assertIs(self.device(LAN_ID)["power"], False)

    def test_a_theme_change_recolours_a_group_on_lan_and_cloud(self):
        self.cli("group", "set", "Office", "Desk Lamp", "Shelf Strip")
        self.cli("on", "Office")
        self.cli("theme", "follow", "office")
        self.set_theme("ff0000")
        self.cli("theme", "apply")
        self.assertEqual(self.colours_sent()[-1], {"r": 255, "g": 0, "b": 0})
        self.assertIn((CLOUD_ID, "colorRgb", 0xFF0000), self.cloud.controls)
        self.assertTrue(self.state()["groups"][0]["followsTheme"])

    def test_renaming_a_group_keeps_it_following_and_removing_it_stops(self):
        self.cli("group", "set", "Office", "Desk Lamp")
        self.cli("theme", "follow", "Office")
        self.cli("group", "set", "office", "Desk Lamp")  # same group, new spelling
        self.assertTrue(self.state()["groups"][0]["followsTheme"])
        self.cli("group", "remove", "Office")
        self.assertFalse(os.path.exists(self.hook))

    def test_unfollow_all_removes_the_hook(self):
        self.cli("theme", "follow", "all")
        self.cli("theme", "unfollow", "all")
        self.assertFalse(os.path.exists(self.hook))
        self.assertIn("nothing", self.cli("theme").stdout)


class Demo(Sandbox):
    DESK = "D0:E1:00:00:00:00:00:01"
    SHELF = "D0:E1:00:00:00:00:00:03"

    def test_demo_lights_work_like_real_ones_and_leave_the_real_setup_alone(self):
        self.setup_key()
        self.cli("demo", "on")
        state = self.state()
        self.assertTrue(state["demo"])
        self.assertEqual(len(state["devices"]), 5)
        self.assertEqual([g["name"] for g in state["groups"]], ["Living room", "Office"])
        self.assertEqual(self.device(self.DESK)["via"], "lan")

        self.cli("color", "Desk Lamp", "#00ff80")
        self.cli("scene", "Shelf Strip", "ocean")
        self.cli("group", "set", "Desk", "Desk Lamp")
        self.cli("theme", "follow", "Office")  # the hook belongs to the real lights
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "omarchy", "hooks")))
        self.cli("poll", "--max-age", "0")
        self.assertEqual(self.device(self.DESK)["color"], "#00ff80")
        self.assertEqual(self.device(self.SHELF)["color"], "#1e6bff")
        self.assertEqual(self.cloud.controls, [])
        self.assertEqual(self.light.commands, [])

        self.cli("demo", "off")
        state = self.state()
        self.assertFalse(state["demo"])
        self.assertEqual(state["groups"], [])
        self.assertEqual({d["id"] for d in state["devices"]}, {LAN_ID, CLOUD_ID, PLUG_ID})


class Hostile(Sandbox):
    """What a noisy or hostile host on the network, or a broken keyring, can do."""

    def packet(self, msg):
        return json.dumps({"msg": msg}).encode()

    def test_junk_packets_are_ignored(self):
        self.light.extra = [b"not json", b"[1]", self.packet({"cmd": "scan", "data": [1]}),
                            self.packet({"cmd": "devStatus", "data": {"color": {"r": 1e400}}}),
                            b'{"msg": {"cmd": "devStatus", "data": {"onOff": Infinity}}}']
        self.cli("setup-save", "--lan-only")
        self.cli("on", "H6008")
        self.assertIs(self.device(LAN_ID)["power"], True)

    def test_a_flood_of_made_up_lights_is_not_remembered(self):
        fakes = [self.packet({"cmd": "scan", "data": {"device": "AA:BB:CC:DD:EE:%02X:00:11" % i, "sku": "H6008"}})
                 for i in range(200)]
        self.light.extra = fakes
        self.cli("setup-save", "--lan-only")
        self.assertEqual([d["id"] for d in self.state()["devices"]], [LAN_ID])
        with open(os.path.join(self.home, "state", "eld-govee", "cache.json")) as handle:
            self.assertEqual(list(json.load(handle)["lanKnown"]), [LAN_ID])

    def test_forget_drops_a_lan_light(self):
        self.cli("setup-save", "--lan-only")
        self.cli("rename", LAN_ID, "Lamp")
        self.cli("forget", "Lamp")
        self.assertEqual(self.state()["devices"], [])

    def test_cloud_lights_cannot_be_forgotten(self):
        self.setup_key()
        self.assertIn("hide it instead", self.cli("forget", "Shelf Strip", ok=False).stderr)

    def test_a_locked_keyring_is_an_error_not_a_plaintext_file(self):
        self.env["FAKE_SECRET_TOOL_FAIL"] = "Cannot unlock collection: dismissed"
        result = self.cli("setup-save", stdin=API_KEY + "\n", ok=False)
        self.assertIn("keyring did not store", result.stderr)
        config = os.path.join(self.home, "config", "eld-govee", "config.json")
        self.assertFalse(os.path.exists(config) and API_KEY in open(config).read())

    def test_no_keyring_at_all_falls_back_to_the_file(self):
        self.env["FAKE_SECRET_TOOL_FAIL"] = "The name org.freedesktop.secrets was not provided by any .service files"
        self.assertEqual(self.setup_key()["keyStore"], "file")

    def test_forget_key_says_so_when_the_keyring_will_not_let_go(self):
        self.setup_key()
        self.env["FAKE_SECRET_TOOL_FAIL"] = "Cannot unlock collection: dismissed"
        self.assertIn("could not remove", self.cli("forget-key", ok=False).stderr)
        self.assertTrue(os.path.exists(KEYRING_FILE))
        self.assertTrue(self.state()["cloud"])

    def test_demo_mode_never_touches_the_real_key(self):
        self.setup_key()
        self.cli("demo", "on")
        self.assertIn("demo mode is on", self.cli("setup-save", stdin="other-key-5678\n", ok=False).stderr)
        self.assertIn("demo mode is on", self.cli("forget-key", ok=False).stderr)
        with open(KEYRING_FILE) as handle:
            self.assertEqual(handle.read().strip(), API_KEY)

    def test_notifications_treat_names_as_text(self):
        self.setup_key()
        self.cli("rename", "Shelf Strip", "--wait <b>x</b>")
        self.cloud.close()
        self.cli("--notify", "on", "--", "--wait <b>x</b>", ok=False)
        with open(NOTIFY_LOG) as handle:
            args = handle.read().splitlines()
        self.assertEqual(args[:4], ["-a", "Govee", "--", "Govee"])
        self.assertNotIn("<b>", args[4])
        self.cloud = FakeCloud()


if __name__ == "__main__":
    unittest.main()
