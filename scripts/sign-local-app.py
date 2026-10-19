#!/usr/bin/env python3
"""Use the previously authorized, fixed project signing certificate."""
from pathlib import Path
import json
import subprocess
import sys

folder = Path(__file__).resolve().parent.parent / ".build" / "signing"
identity = json.loads((folder / "identity.json").read_text())
password = (folder / "keychain-password").read_text()
# Never allow a subprocess exception to include the password-bearing argv.
result = subprocess.run(["/usr/bin/security", "unlock-keychain", "-p", password, identity["keychain"]], capture_output=True)
if result.returncode:
    raise SystemExit("Unable to unlock the project signing keychain; retry with keychain access enabled.")
subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--keychain", identity["keychain"],
                "--sign", identity["fingerprint"], "--timestamp=none", sys.argv[1]], check=True)
