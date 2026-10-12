"""Unit tests for the parts of the helper that can break quietly."""

import ipaddress
import json
import os
import shutil
import unittest

from helpers import CLOUD_ID, LAN_ID, PLUG_ID, FakeCloud, helper as h


class ThemeFiles:
    """A fake Omarchy current theme for the length of a with block."""

    def __init__(self, keyboard=None, accent=None):
        self.files = {}
        if keyboard is not None:
            self.files["keyboard.rgb"] = keyboard + "\n"
        if accent is not None:
            self.files["colors.toml"] = f'mode = "dark"\n\naccent = "{accent}"\nbackground = "#000000"\n'

    def __enter__(self):
        os.makedirs(h.OMARCHY_THEME_DIR)
        for name, text in self.files.items():
            with open(os.path.join(h.OMARCHY_THEME_DIR, name), "w") as handle:
                handle.write(text)

    def __exit__(self, *exc):
        shutil.rmtree(h.OMARCHY_THEME_DIR)


class Parsing(unittest.TestCase):
    def test_device_ids_are_normalised_and_checked(self):
        self.assertEqual(h.norm_id("aa:bb:cc:dd:ee:ff:00:11"), "AA:BB:CC:DD:EE:FF:00:11")
        self.assertEqual(h.norm_id("../../etc/passwd"), "")
        self.assertEqual(h.norm_id("AA:BB"), "")

    def test_colours(self):
        self.assertEqual(h.parse_color("#FF8800"), (255, 136, 0))
        self.assertEqual(h.parse_color("red"), (255, 0, 0))
        self.assertEqual(h.hex_color((255, 136, 0)), "#ff8800")
        with self.assertRaises(h.GoveeError):
            h.parse_color("blurple")

    def test_theme_is_a_colour_name(self):
        with ThemeFiles(keyboard="00ff80"):
            self.assertEqual(h.parse_color("theme"), (0, 255, 128))
        with self.assertRaises(h.GoveeError):
            h.parse_color("theme")  # no theme files

    def test_names_lose_control_characters(self):
        self.assertEqual(h.clean_text("Desk\x1b[31m Lamp\n"), "Desk [31m Lamp")
        self.assertEqual(h.clean_text("", "fallback"), "fallback")

    def test_brightness_scales_to_odd_ranges(self):
        self.assertEqual(h.from_percent(50, [1, 100]), 50)
        self.assertEqual(h.from_percent(100, [0, 254]), 254)
        self.assertEqual(h.to_percent(127, [0, 254]), 50)

    def test_test_hooks_only_accept_loopback(self):
        self.assertTrue(h._loopback_url("http://127.0.0.1:8080"))
        self.assertTrue(h._loopback_url("http://[::1]:8080"))
        for url in ("https://evil.example", "http://192.168.1.10:80", "http://evil@127.0.0.1:80",
                    "http://127.0.0.1@evil.example:80", "file://127.0.0.1/etc/passwd",
                    "http://localhost.evil.example:80", "http://127.0.0.1", "127.0.0.1"):
            self.assertFalse(h._loopback_url(url), url)


class CloudDevices(unittest.TestCase):
    def setUp(self):
        self.raw = FakeCloud()

    def tearDown(self):
        self.raw.close()

    def test_switchable_devices_only(self):
        devices = [d for d in map(h.summarize_cloud, self.raw.devices) if d]
        self.assertEqual([d["id"] for d in devices], [LAN_ID, CLOUD_ID, PLUG_ID])

    def test_capabilities(self):
        light = h.summarize_cloud(self.raw.devices[1])
        self.assertEqual(light["supports"], {"power": True, "brightness": True, "color": True,
                                             "temp": True, "scenes": True})
        self.assertEqual(light["tempRange"], [2000, 9000])
        plug = h.summarize_cloud(self.raw.devices[2])
        self.assertEqual(plug["kind"], "plug")
        self.assertFalse(plug["supports"]["brightness"])

    def test_untrusted_fields_are_rejected(self):
        self.assertIsNone(h.summarize_cloud({"sku": "H6008", "device": "not-an-id",
                                             "capabilities": [{"type": "devices.capabilities.on_off",
                                                               "instance": "powerSwitch"}]}))
        self.assertIsNone(h.summarize_cloud("garbage"))


class CloudState(unittest.TestCase):
    device = {"brightnessRange": [1, 100]}

    def state(self, **values):
        kinds = {"powerSwitch": "on_off", "brightness": "range", "colorRgb": "color_setting",
                 "colorTemperatureK": "color_setting", "online": "online"}
        return h.read_cloud_state([{"type": f"devices.capabilities.{kinds[k]}", "instance": k,
                                    "state": {"value": v}} for k, v in values.items()], self.device)

    def test_colour_mode(self):
        self.assertEqual(self.state(powerSwitch=1, brightness=30, colorRgb=0x00FF00, colorTemperatureK=0),
                         {"power": True, "brightness": 30, "mode": "color", "color": "#00ff00"})

    def test_temperature_mode_wins_when_set(self):
        self.assertEqual(self.state(colorRgb=0, colorTemperatureK=2700)["mode"], "temp")

    def test_offline(self):
        self.assertEqual(self.state(online=False), {"online": False})


class Lan(unittest.TestCase):
    def test_messages(self):
        self.assertEqual(h.lan_message("power", True), ("turn", {"value": 1}))
        self.assertEqual(h.lan_message("brightness", 0), ("brightness", {"value": 1}))
        self.assertEqual(h.lan_message("color", (1, 2, 3)),
                         ("colorwc", {"color": {"r": 1, "g": 2, "b": 3}, "colorTemInKelvin": 0}))
        self.assertEqual(h.lan_message("temp", 2700)[1]["colorTemInKelvin"], 2700)
        self.assertIsNone(h.lan_message("scene", {}))

    def test_status(self):
        self.assertEqual(h.read_lan_state({"onOff": 1, "brightness": 55,
                                           "color": {"r": 255, "g": 0, "b": 0}, "colorTemInKelvin": 0}),
                         {"online": True, "power": True, "brightness": 55, "mode": "color",
                          "color": "#ff0000"})


class Resolve(unittest.TestCase):
    state = {"devices": [
        {"id": LAN_ID, "name": "Desk Lamp", "hidden": False},
        {"id": CLOUD_ID, "name": "Shelf Strip", "hidden": False},
        {"id": PLUG_ID, "name": "Desk Fan", "hidden": True},
    ]}
    config = {"groups": {"Office": [LAN_ID, CLOUD_ID]}}

    def names(self, target):
        return [d["name"] for d in h.resolve(self.state, self.config, target)]

    def test_all_skips_hidden(self):
        self.assertEqual(self.names("all"), ["Desk Lamp", "Shelf Strip"])

    def test_group_name_is_case_insensitive(self):
        self.assertEqual(self.names("office"), ["Desk Lamp", "Shelf Strip"])

    def test_exact_name_beats_partial(self):
        self.assertEqual(self.names("desk lamp"), ["Desk Lamp"])

    def test_unique_partial(self):
        self.assertEqual(self.names("shelf"), ["Shelf Strip"])

    def test_ambiguous_partial(self):
        with self.assertRaises(h.GoveeError):
            self.names("desk")

    def test_device_id(self):
        self.assertEqual(self.names(CLOUD_ID.lower()), ["Shelf Strip"])


class Scenes(unittest.TestCase):
    options = [{"name": "Sunrise", "kind": "scene"}, {"name": "Sunset", "kind": "scene"},
               {"name": "Aurora", "kind": "scene"}]

    def test_exact_and_unique_partial(self):
        self.assertEqual(h.find_scene(self.options, "sunrise")["name"], "Sunrise")
        self.assertEqual(h.find_scene(self.options, "aur")["name"], "Aurora")
        self.assertIsNone(h.find_scene(self.options, "sun"))



class ThemeColour(unittest.TestCase):
    def test_keyboard_colour_wins_and_is_scaled_to_full_strength(self):
        with ThemeFiles(keyboard="7f007f", accent="#7aa2f7"):
            self.assertEqual(h.theme_color(), (255, 0, 255))

    def test_accent_when_the_theme_has_no_keyboard_colour(self):
        with ThemeFiles(keyboard="not a colour", accent="#7aa2f7"):
            self.assertEqual(h.theme_color(), (126, 167, 255))

    def test_grey_accents_make_white_light(self):
        with ThemeFiles(accent="#6e6e6e"):
            self.assertEqual(h.theme_color(), (255, 255, 255))

    def test_no_theme(self):
        self.assertIsNone(h.theme_color())



class UntrustedInput(unittest.TestCase):
    """Data from the network and from Govee is checked before it is used."""

    def test_lan_status_with_wrong_types_is_ignored_not_fatal(self):
        self.assertEqual(h.read_lan_state({"onOff": True, "brightness": 900, "colorTemInKelvin": 0,
                                           "color": {"r": float("inf"), "g": 0, "b": 0}}),
                         {"online": True})
        self.assertEqual(h.read_lan_state({"onOff": 1, "brightness": 40, "color": {"r": 255, "g": 0, "b": 1}}),
                         {"online": True, "power": True, "brightness": 40, "mode": "color", "color": "#ff0001"})

    def test_only_addresses_on_a_connected_network_count_as_lights(self):
        saved = list(h._networks)
        try:
            h._networks[:] = [ipaddress.ip_network("192.168.0.0/22"), ipaddress.ip_network("100.64.0.0/24"), None]
            for ip in ("192.168.1.20", "192.168.1.255", "100.64.0.9"):
                self.assertTrue(h.lan_source_ok(ip), ip)
            for ip in ("192.168.3.255", "192.168.0.0", "10.0.0.7", "8.8.8.8", "224.0.0.1", "0.0.0.0",
                       "::1", "fe80::1", "nonsense"):
                self.assertFalse(h.lan_source_ok(ip), ip)
            h._networks[:] = [None]  # no `ip`: private and link-local addresses
            self.assertTrue(h.lan_source_ok("10.0.0.7"))
            self.assertFalse(h.lan_source_ok("8.8.8.8"))
        finally:
            h._networks[:] = saved

    def test_malformed_cloud_devices_are_skipped(self):
        junk = [{"device": "AA:BB:CC:DD:EE:FF:00:11", "sku": "H6008", "capabilities": [
                    {"type": "devices.capabilities.on_off", "instance": "powerSwitch", "parameters": [1]},
                    {"type": "devices.capabilities.range", "instance": "brightness",
                     "parameters": {"range": {"min": 10 ** 400, "max": "x"}}},
                    {"type": "devices.capabilities.dynamic_scene", "instance": "snapshot",
                     "parameters": {"options": [{"name": "Bad", "value": {"x": [1]}}, 7]}}]},
                {"device": 5, "sku": None}, "not a device", {"device": "AA:BB:CC:DD:EE:FF:00:12", "sku": "-h"}]
        devices = [d for d in map(h.summarize_cloud, junk) if d]
        self.assertEqual([d["id"] for d in devices], ["AA:BB:CC:DD:EE:FF:00:11"])
        self.assertEqual(devices[0]["brightnessRange"], [1, 100])
        self.assertEqual(devices[0]["snapshots"], [])
        self.assertEqual(h.read_cloud_state([{"state": [1]}, 3, {"type": "x", "state": {"value": True}}],
                                            devices[0]), {})

    def test_scene_values_are_numbers_or_small_objects_of_numbers(self):
        self.assertEqual(h.scene_value(12), 12)
        self.assertEqual(h.scene_value({"paramId": 1, "id": 2}), {"paramId": 1, "id": 2})
        for bad in (True, "x", -1, {"a": "b"}, {str(i): i for i in range(9)}, [1]):
            self.assertIsNone(h.scene_value(bad), bad)

    def test_remembered_lan_lights_expire(self):
        now = h.time.time()
        cache = {"lanKnown": {"AA:BB:CC:DD:EE:FF:00:11": "H6008",
                              "AA:BB:CC:DD:EE:FF:00:12": {"sku": "H6072", "seenAt": now - 40 * 86400},
                              "AA:BB:CC:DD:EE:FF:00:13": {"sku": "H6072", "seenAt": now},
                              "../etc": {"sku": "H6072", "seenAt": now}}}
        self.assertEqual(h.lan_known(cache), {"AA:BB:CC:DD:EE:FF:00:11": "H6008",
                                              "AA:BB:CC:DD:EE:FF:00:13": "H6072"})


class Files(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.join(os.environ["HOME"], "files-test")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_atomic_write_is_private_and_leaves_nothing_behind(self):
        path = os.path.join(self.dir, "secret.json")
        h.write_atomic(path, "x")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(os.listdir(self.dir), ["secret.json"])
        with self.assertRaises(AttributeError):
            h.write_atomic(path, 5)  # fails after the temporary file exists
        self.assertEqual(os.listdir(self.dir), ["secret.json"])

    def test_malformed_config_entries_are_dropped(self):
        os.makedirs(os.path.dirname(h.CONFIG_PATH), exist_ok=True)
        with open(h.CONFIG_PATH, "w") as handle:
            handle.write('{"groups": {"Office": ["AA:BB:CC:DD:EE:FF:00:11", 5, "../x"], "": []},'
                         ' "aliases": {"nope": "x", "AA:BB:CC:DD:EE:FF:00:11": "Lamp"}, "hidden": [1],'
                         ' "followTheme": [2, "Office"]}')
        try:
            config = h.load_config()
        finally:
            os.remove(h.CONFIG_PATH)
        self.assertEqual(config["groups"], {"Office": ["AA:BB:CC:DD:EE:FF:00:11"]})
        self.assertEqual(config["aliases"], {"AA:BB:CC:DD:EE:FF:00:11": "Lamp"})
        self.assertEqual((config["hidden"], config["followTheme"]), ([], ["Office"]))



class StubLan:
    """Stands in for the network: a scan answered from many addresses."""
    scans, answering, conflicts = [], set(), set()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def scan(self, timeout=0):
        self.conflicts = set(StubLan.conflicts)
        return StubLan.scans.pop(0) if StubLan.scans else {}

    def status(self, ips, timeout=0):
        return {ip: {"online": True, "power": True} for ip in ips if ip in StubLan.answering}


class Discovery(unittest.TestCase):
    """poll() against a network the test controls."""

    def setUp(self):
        self.saved = h.Lan
        h.Lan = StubLan
        StubLan.scans, StubLan.answering, StubLan.conflicts = [], set(), set()
        for path in (h.CONFIG_PATH, h.CACHE_PATH, h.STATE_PATH):
            if os.path.exists(path):
                os.remove(path)
        h.save_config({"lanOnly": True})

    def tearDown(self):
        h.Lan = self.saved

    def cache(self):
        with open(h.CACHE_PATH) as handle:
            return json.load(handle)

    def test_a_flood_from_many_addresses_stays_bounded_across_polls(self):
        real = {"AA:BB:CC:DD:EE:FF:00:11": {"ip": "192.168.1.10", "sku": "H6008"}}
        StubLan.answering = {"192.168.1.10"}
        for round in range(6):
            fakes = {"AA:BB:CC:%02X:%02X:00:00:01" % (round, i): {"ip": "192.168.%d.%d" % (round + 2, i), "sku": "H6008"}
                     for i in range(64)}
            StubLan.scans.append(dict(real, **fakes))
            state = h.poll(max_age=0)
            self.assertLessEqual(len(state["devices"]), 1 + 64)
        cache = self.cache()
        self.assertEqual(list(cache["lanKnown"]), ["AA:BB:CC:DD:EE:FF:00:11"])
        self.assertEqual(list(cache["lan"]), ["AA:BB:CC:DD:EE:FF:00:11"])
        state = h.poll(max_age=0, scan=False)
        self.assertEqual([d["id"] for d in state["devices"]], ["AA:BB:CC:DD:EE:FF:00:11"])

    def test_an_id_claimed_twice_loses_its_cached_address(self):
        lamp = "AA:BB:CC:DD:EE:FF:00:11"
        StubLan.answering = {"192.168.1.66"}
        StubLan.scans.append({lamp: {"ip": "192.168.1.66", "sku": "H6008"}})  # the impostor first
        h.poll(max_age=0)
        StubLan.conflicts = {lamp}  # now the real light answers too
        StubLan.scans.append({})
        state = h.poll(max_age=0)
        self.assertNotIn(lamp, self.cache()["lan"])
        self.assertFalse(next(d for d in state["devices"] if d["id"] == lamp)["lan"])

    def test_a_time_out_mid_command_rolls_back(self):
        lamp = "AA:BB:CC:DD:EE:FF:00:11"
        StubLan.answering = {"192.168.1.10"}
        StubLan.scans.append({lamp: {"ip": "192.168.1.10", "sku": "H6008"}})
        h.poll(max_age=0)
        h.patch_devices({lamp: {"power": False}})
        saved = h.send_plan

        def stuck(*args):
            raise h.TimedOut("took too long; gave up")

        h.send_plan = stuck
        try:
            with self.assertRaises(h.TimedOut):
                h.apply(lamp, "power", True)
        finally:
            h.send_plan = saved
        with open(h.STATE_PATH) as handle:
            state = json.load(handle)
        self.assertIs(next(d for d in state["devices"] if d["id"] == lamp)["power"], False)
        self.assertIn("too long", state["error"]["message"])


if __name__ == "__main__":
    unittest.main()
