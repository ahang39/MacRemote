"""CLI behavior regression without opening any listening port."""
import json
import os
import subprocess
import sys
import tempfile

def run(binary, *args, env):
    return subprocess.run([binary, *args], capture_output=True,
                          text=True, env=env, timeout=8)

def main():
    binary = sys.argv[1]
    with tempfile.TemporaryDirectory(prefix="macremote-cli-") as folder:
        env = {**os.environ, "HOME": folder}
        status = run(binary, "status", "--json", env=env)
        assert status.returncode == 0, status.stderr
        data = json.loads(status.stdout)
        assert data["authentication"] == "macOS PAM over TLS"
        assert data["input"] == "enabled"
        assert data["max_clients"] is None
        assert data["default_bind"] == "0.0.0.0"
        assert data["default_port"] == 3389
        assert data["account"] not in ("", "macremote", "unknown")
        assert "paired" not in data
        print("PASS status: native Mac login, TLS/PAM, full remote control, no pairing")

        version = run(binary, "version", env=env)
        assert version.returncode == 0 and "FreeRDP" in version.stdout
        doctor = run(binary, "doctor", env=env)
        assert doctor.returncode == 0 and "Mac login account" in doctor.stdout
        help_result = run(binary, "--help", env=env)
        assert (help_result.returncode == 0 and "--gfx" in help_result.stdout
                and "avc444" in help_result.stdout)
        print("PASS version, doctor and graphics profiles")

        for port in ("0", "65536", "-1", "x", "3389oops", ""):
            result = run(binary, "serve", "--port", port, env=env)
            assert result.returncode == 2, (port, result.stderr)
        print("PASS numeric port validation")

        for address in ("abc", "127.0.0.1,0.0.0.0",
                        "127.0.0.1;anything", "", "example.com"):
            result = run(binary, "serve", "--bind", address, env=env)
            assert result.returncode == 2, (address, result.stderr)
        print("PASS listen-IP validation")

        for profile in ("bad", "", "AVC444", "auto"):
            result = run(binary, "serve", "--gfx", profile, env=env)
            assert result.returncode == 2, (profile, result.stderr)
        print("PASS unsupported graphics profiles rejected")

        for args in (["pair"], ["pair", "--reset"], ["serve", "--unknown"],
                     ["serve", "--bind"], ["serve", "--port"],
                     ["doctor", "--json"]):
            result = run(binary, *args, env=env)
            assert result.returncode == 2, (args, result.stderr)
        print("PASS removed pairing and obsolete options")
    print("PASS all CLI regression checks")

if __name__ == "__main__":
    main()
