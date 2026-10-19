#!/usr/bin/env python3
"""Create a project-only signing identity. Does not grant privacy access.

No system/login keychain certificates or root trust are changed. Preserve
.build/signing across builds; never distribute its private files with the app.
"""
from pathlib import Path
import hashlib
import json
import os
import secrets
import shlex
import subprocess

root = Path(__file__).resolve().parent.parent
folder = root / ".build" / "signing"
folder.mkdir(mode=0o700, parents=True, exist_ok=True)
os.chmod(folder, 0o700)
os.umask(0o077)
keychain = folder / "jianchao.keychain-db"
manifest = folder / "identity.json"
password_file = folder / "keychain-password"

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

if manifest.exists() and keychain.exists() and password_file.exists():
    print("Existing project signing identity preserved.")
    raise SystemExit(0)
if keychain.exists():
    raise SystemExit("An incomplete signing keychain exists. Inspect it before retrying; it will not be overwritten.")

password = secrets.token_urlsafe(32)
password_file.write_text(password)
config = folder / "certificate.conf"
config.write_text("""[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=Jianchao Local Development
[extensions]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
""")
private_key = folder / "private-key.pem"
certificate = folder / "certificate.pem"
pkcs12 = folder / "identity.p12"
run("/usr/bin/openssl", "req", "-new", "-newkey", "rsa:3072", "-nodes", "-x509", "-sha256", "-days", "3650",
    "-config", str(config), "-keyout", str(private_key), "-out", str(certificate), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(private_key), "-in", str(certificate),
    "-out", str(pkcs12), "-passout", f"file:{password_file}")
original_search = shlex.split(subprocess.check_output(["/usr/bin/security", "list-keychains", "-d", "user"], text=True))
try:
    run("/usr/bin/security", "create-keychain", "-p", password, str(keychain))
finally:
    # create-keychain adds to the search list. Restore it immediately; builds
    # explicitly select this private keychain instead of changing defaults.
    run("/usr/bin/security", "list-keychains", "-d", "user", "-s", *original_search)
run("/usr/bin/security", "unlock-keychain", "-p", password, str(keychain))
run("/usr/bin/security", "import", str(pkcs12), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign", "-x")
run("/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,codesign:", "-s", "-k", password, str(keychain), stdout=subprocess.DEVNULL)
der = subprocess.check_output(["/usr/bin/openssl", "x509", "-in", str(certificate), "-outform", "DER"])
fingerprint = hashlib.sha1(der).hexdigest().upper()
manifest.write_text(json.dumps({"fingerprint": fingerprint, "keychain": str(keychain)}, indent=2) + "\n")
private_key.unlink()
pkcs12.unlink()
print("Fixed project signing identity created. No privacy permissions or root trust were changed.")
