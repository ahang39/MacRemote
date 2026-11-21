"""Tests for the generated Windows mstsc credential prompt profile."""
import importlib.util
from pathlib import Path
import unittest


class ProfileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).parents[1] / "tools/make-mstsc-profile.py"
        spec = importlib.util.spec_from_file_location("mstsc_profile", path)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_client_prompt_and_tls(self):
        payload = self.module.profile("rdp.example.com", "localuser", 3389)
        self.assertTrue(payload.startswith(b"\xff\xfe"))
        text = payload.decode("utf-16")
        self.assertIn("full address:s:rdp.example.com\r\n", text)
        self.assertIn("username:s:localuser\r\n", text)
        self.assertIn("prompt for credentials:i:1\r\n", text)
        self.assertIn("prompt for credentials on client:i:1\r\n", text)
        self.assertIn("enablecredsspsupport:i:0\r\n", text)
        self.assertIn("negotiate security layer:i:1\r\n", text)
        self.assertIn("authentication level:i:2\r\n", text)
        self.assertIn("session bpp:i:32\r\n", text)
        self.assertNotIn("password", text.lower())
        self.assertNotIn("authentication level:i:0", text)

    def test_remembered_client_credentials(self):
        text = self.module.profile("127.0.0.1", "ahang", remembered=True).decode("utf-16")
        self.assertIn("full address:s:127.0.0.1\r\n", text)
        self.assertIn("username:s:ahang\r\n", text)
        self.assertIn("prompt for credentials:i:0\r\n", text)
        self.assertIn("prompt for credentials on client:i:1\r\n", text)
        self.assertIn("enablecredsspsupport:i:0\r\n", text)
        self.assertNotIn("password 51:b:", text)

    def test_port_and_newline_safety(self):
        self.assertIn("server port:i:53389", self.module.profile("example.local", "user", 53389).decode("utf-16"))
        with self.assertRaises(ValueError):
            self.module.profile("rdp.example.com\nunsafe", "user")
        with self.assertRaises(ValueError):
            self.module.profile("rdp.example.com", "user", 0)


if __name__ == "__main__":
    unittest.main()
