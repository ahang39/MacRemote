"""Real loopback TLS+PAM test, using a nonexistent login to verify denial.

No Mac password is requested, stored, logged or guessed. A full successful
login test requires a real client entering its own Mac credentials.
"""
import argparse
import os
import re
import secrets
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True)
    parser.add_argument("--client", required=True)
    parser.add_argument("--compat-graphics", action="store_true")
    args = parser.parse_args()
    for binary in (args.server, args.client):
        if not Path(binary).is_file():
            parser.error(f"missing binary: {binary}")

    with tempfile.TemporaryDirectory(prefix="macremote-tls-test-") as dirname:
        root = Path(dirname)
        env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root),
                   WLOG_LEVEL="INFO")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]

        with (root / "server.log").open("w") as logfile:
            server_args = [args.server, "serve", "--bind", "127.0.0.1",
                           "--port", str(port)]
            if args.compat_graphics:
                server_args.append("--compat-graphics")
            server = subprocess.Popen(
                server_args,
                cwd=root, env=env, stdout=logfile,
                stderr=subprocess.STDOUT, start_new_session=True
            )
            try:
                ready = False
                for _ in range(70):
                    if server.poll() is not None: break
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=.15):
                            ready = True
                            break
                    except OSError:
                        time.sleep(.12)
                if not ready:
                    raise RuntimeError("FreeRDP Shadow TLS/PAM listener did not start")

                # Deliberately *not* the active user: authorization must fail.
                # No real user password, no lockout risk for an existing account.
                password = secrets.token_urlsafe(18)
                client = subprocess.run(
                    [args.client, f"/v:127.0.0.1:{port}",
                     "/u:__macremote_invalid_account__", f"/p:{password}",
                     "/cert:ignore", "/sec:tls", "-gfx",
                     "/size:1920x1080", "/bpp:32"],
                    cwd=root, env=env, capture_output=True, text=True, timeout=15
                )
                # The sample client may exit zero after an orderly RDP error;
                # validate the server-side PAM username rejection instead.
                server_text = (root / "server.log").read_text(errors="replace")
                client_text = client.stdout + "\n" + client.stderr
                assert "login as '__macremote_invalid_account__' refused" in server_text, (
                    "Expected upstream macOS Shadow PAM username callback not observed"
                )
                assert "FIRST_FRAME_MS" not in client_text, (
                    "Unexpected rendered desktop frame despite rejected account"
                )
                print("PASS TLS session reached macOS PAM and denied invalid Mac login")
                print("PASS no desktop pixels delivered for rejected credentials")
            finally:
                if server.poll() is None:
                    os.killpg(server.pid, signal.SIGTERM)
                    try:
                        server.wait(timeout=6)
                    except subprocess.TimeoutExpired:
                        os.killpg(server.pid, signal.SIGKILL)
                        server.wait(timeout=5)

if __name__ == "__main__":
    main()
