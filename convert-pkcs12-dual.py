#!/usr/bin/env python3
"""Optional helper for Signing Script: convert a dual-password PKCS12.

Android Studio can write PKCS12 files where the private key password differs
from the store password. Java ignores the separate key password, so Gradle
signing fails. This reads:

  - private key encrypted with keyPassword
  - cert bag encrypted with storePassword

and writes a new .p12 where both use storePassword.

Passwords are read from files (not argv) so they are not left in shell history.
"""
from __future__ import annotations

import sys
from pathlib import Path

from asn1crypto import pkcs12 as a12
from cryptography import x509
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives.serialization import (
    BestAvailableEncryption,
    load_der_private_key,
    pkcs12 as c12,
)


def decrypt_pbes2(enc_algo, ciphertext: bytes, password: bytes) -> bytes:
    params = enc_algo["parameters"]
    kdf = params["key_derivation_func"]
    encsch = params["encryption_scheme"]
    kdf_params = kdf["parameters"]
    salt = bytes(kdf_params["salt"].native)
    iters = int(kdf_params["iteration_count"].native)
    prf = "sha1"
    if kdf_params["prf"].native is not None:
        prf = kdf_params["prf"]["algorithm"].native.replace("-", "")
    enc_alg = encsch["algorithm"].native
    iv = bytes(encsch["parameters"])
    if enc_alg == "aes128_cbc":
        key_len = 16
    elif enc_alg == "aes192_cbc":
        key_len = 24
    elif enc_alg == "aes256_cbc":
        key_len = 32
    else:
        raise ValueError(f"unsupported enc {enc_alg}")
    if "sha256" in prf:
        hash_algo = hashes.SHA256()
    elif "sha512" in prf:
        hash_algo = hashes.SHA512()
    else:
        hash_algo = hashes.SHA1()
    key = PBKDF2HMAC(
        algorithm=hash_algo, length=key_len, salt=salt, iterations=iters
    ).derive(password)
    decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    pt = decryptor.update(ciphertext) + decryptor.finalize()
    pad = pt[-1]
    if pad < 1 or pad > 16 or pt[-pad:] != bytes([pad]) * pad:
        raise ValueError("bad padding (wrong password?)")
    return pt[:-pad]


def convert(src: Path, dest: Path, alias: str, store_pass: bytes, key_pass: bytes) -> None:
    data = src.read_bytes()
    pfx = a12.Pfx.load(data)
    safe = a12.AuthenticatedSafe.load(bytes(pfx["auth_safe"]["content"]))

    bags0 = a12.SafeContents.load(bytes(safe[0]["content"]))
    shrouded = bags0[0]["bag_value"]
    pt_key = decrypt_pbes2(
        shrouded["encryption_algorithm"],
        bytes(shrouded["encrypted_data"]),
        key_pass,
    )
    private_key = load_der_private_key(pt_key, password=None)

    ed = safe[1]["content"]
    eci = ed["encrypted_content_info"]
    pt_certs = decrypt_pbes2(
        eci["content_encryption_algorithm"],
        bytes(eci["encrypted_content"]),
        store_pass,
    )
    bags = a12.SafeContents.load(pt_certs)
    cert_der = None
    for bag in bags:
        if (
            bag["bag_id"].native == "cert_bag"
            and bag["bag_value"]["cert_id"].native == "x509"
        ):
            cert_der = bytes(bag["bag_value"]["cert_value"])
            break
    if cert_der is None:
        raise RuntimeError("No X.509 certificate bag found")
    cert = x509.load_der_x509_certificate(cert_der)

    dest.write_bytes(
        c12.serialize_key_and_certificates(
            alias.encode("utf-8"),
            private_key,
            cert,
            None,
            BestAvailableEncryption(store_pass),
        )
    )

    # Round-trip check with store password only
    key2, cert2, _ = c12.load_key_and_certificates(dest.read_bytes(), store_pass)
    if key2 is None or cert2 is None:
        raise RuntimeError("Converted keystore failed verification")


def main() -> int:
    if len(sys.argv) != 6:
        print(
            "Usage: convert-pkcs12-dual.py <src.p12> <dest.p12> <alias> <storePassFile> <keyPassFile>"
        )
        return 2
    src, dest, alias, store_file, key_file = sys.argv[1:6]
    store_pass = Path(store_file).read_bytes().decode("utf-8").strip().encode("utf-8")
    key_pass = Path(key_file).read_bytes().decode("utf-8").strip().encode("utf-8")
    convert(Path(src), Path(dest), alias, store_pass, key_pass)
    print(f"OK: wrote {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
