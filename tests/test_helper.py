"""Unit tests for the parts of the helper that can break quietly."""

import unittest

from helpers import CLOUD_ID, LAN_ID, PLUG_ID, FakeCloud, helper as h


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

    def test_names_lose_control_characters(self):
        self.assertEqual(h.clean_text("Desk\x1b[31m Lamp\n"), "Desk [31m Lamp")
        self.assertEqual(h.clean_text("", "fallback"), "fallback")

    def test_brightness_scales_to_odd_ranges(self):
        self.assertEqual(h.from_percent(50, [1, 100]), 50)
        self.assertEqual(h.from_percent(100, [0, 254]), 254)
        self.assertEqual(h.to_percent(127, [0, 254]), 50)

    def test_test_hooks_only_accept_loopback(self):
        self.assertTrue(h._loopback_only("http://127.0.0.1:8080"))
        self.assertTrue(h._loopback_only("127.0.0.1"))
        self.assertFalse(h._loopback_only("https://evil.example"))
        self.assertFalse(h._loopback_only("192.168.1.10"))


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


if __name__ == "__main__":
    unittest.main()
