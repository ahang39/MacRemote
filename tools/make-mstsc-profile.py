#!/usr/bin/env python3
"""Create a password-free Windows mstsc profile for MacRemote TLS/PAM.

Prompts are CLIENT settings, not server directives. The user still enters
their own macOS password in Windows, and Windows controls whether a dialog
appears. Never put a password in an .rdp file.
"""
import argparse
import getpass
from pathlib import Path


def profile(host: str, user: str, port: int = 3389, remembered: bool = False) -> bytes:
    for value in (host, user):
        if not value or any(c in value for c in "\r\n"):
            raise ValueError("Host and user must be nonempty, without newlines")
    if not 1 <= port <= 65535:
        raise ValueError("Port must be 1..65535")
    lines = [
        f"full address:s:{host}",
        f"server port:i:{port}",
        f"username:s:{user}",
        # Windows decides whether to prompt or use its saved credentials.
        f"prompt for credentials:i:{0 if remembered else 1}",
        "prompt for credentials on client:i:1",
        "enablecredsspsupport:i:0",
        "negotiate security layer:i:1",
        # Do not silently trust an unverified TLS certificate.
        "authentication level:i:2",
        "session bpp:i:32",
    ]
    return ("\r\n".join(lines) + "\r\n").encode("utf-16")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="Mac hostname/IP reachable from Windows")
    parser.add_argument("--user", default=getpass.getuser(), help="macOS account name")
    parser.add_argument("--port", type=int, default=3389)
    parser.add_argument("--output", type=Path, default=Path("MacRemote.rdp"))
    parser.add_argument("--remembered", action="store_true",
                        help="Allow Windows mstsc to reuse its saved password")
    args = parser.parse_args()
    payload = profile(args.host, args.user, args.port, remembered=args.remembered)
    with args.output.open("xb") as file:
        file.write(payload)
    print(f"Created {args.output} (no passwords saved)")


if __name__ == "__main__":
    main()
