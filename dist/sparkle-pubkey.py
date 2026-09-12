#!/usr/bin/env python3
"""Print the base64 Ed25519 PUBLIC key for a Sparkle private key file.

    python3 dist/sparkle-pubkey.py ~/.bond-signing/sparkle_ed25519.key
    python3 dist/sparkle-pubkey.py --self-test

`dist/check.sh` uses it for one row and one row only: whether
DIST_SPARKLE_PUBLIC_KEY really is the public half of the key at
DIST_SPARKLE_PRIVATE_KEY_PATH. Getting that pair wrong is a failure with no
symptom at build time and a fatal one afterwards — the app ships with a
SUPublicEDKey that verifies nothing the release signs, so every installed copy
silently refuses every update, and the only fix is another release.

Why the arithmetic is written out here rather than called:

  * the stock /usr/bin/openssl on macOS is LibreSSL, which has no Ed25519 at
    all (`openssl pkeyutl` refuses the curve);
  * a fresh laptop has neither an OpenSSL 3 on PATH nor Python's
    `cryptography` package, and `dist-check` must answer on a machine that has
    just been cloned onto.

So this is the RFC 8032 reference computation over the standard library: about
sixty lines, a single scalar multiplication of the base point, and slow enough
to notice (tens of milliseconds) and fast enough not to care. `--self-test`
runs RFC 8032's first test vector, which is what says the arithmetic below is
the real curve and not a plausible-looking transcription of it.

The key file is never echoed — not on success, not in an error. Only the
public half, which goes into a plist and a public appcast, is ever printed.
"""

import base64
import hashlib
import sys

# Ed25519 domain parameters, RFC 8032 section 5.1.
_P = 2**255 - 19
_D = -121665 * pow(121666, _P - 2, _P) % _P
_BX = 15112221349535400772501151409588531511454012693041857206046113283949847762202
_BY = 46316835694926478169428394003475163141307993866256225615783033603165251855960


def _point_add(p, q):
    """Twisted Edwards addition, affine coordinates.

    Affine rather than the extended coordinates a fast implementation uses:
    one multiplication per bit of a 255-bit scalar is imperceptible here, and
    the formula below is the one written in the RFC, so it can be read against
    it line for line.
    """
    x1, y1 = p
    x2, y2 = q
    k = _D * x1 * x2 * y1 * y2 % _P
    x3 = (x1 * y2 + x2 * y1) * pow(1 + k, _P - 2, _P) % _P
    y3 = (y1 * y2 + x1 * x2) * pow(1 - k, _P - 2, _P) % _P
    return (x3, y3)


def _scalar_mult(point, scalar):
    """Double-and-add. Not constant time, and deliberately so: the input is a
    key the caller already holds on disk, and this runs on the developer's own
    machine, so there is no timing channel to anybody."""
    result = (0, 1)  # the neutral element
    while scalar > 0:
        if scalar & 1:
            result = _point_add(result, point)
        point = _point_add(point, point)
        scalar >>= 1
    return result


def _encode_point(point):
    """The 32-byte little-endian encoding: y, with x's low bit in the top bit."""
    x, y = point
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def public_from_seed(seed):
    """The public key for a 32-byte private seed, RFC 8032 section 5.1.5."""
    h = hashlib.sha512(seed).digest()
    # Clamping: clear the three low bits and the top bit, set bit 254. The
    # scalar is the FIRST half of the hash; the second half is the nonce
    # prefix, which only signing uses.
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return _encode_point(_scalar_mult((_BX, _BY), a))


def _self_test():
    """RFC 8032 test vector 1. A wrong constant or a mistyped formula still
    produces a plausible 44-character answer, so the only useful check is
    against a key pair somebody else published."""
    seed = bytes.fromhex(
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    )
    want = bytes.fromhex(
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    )
    got = public_from_seed(seed)
    if got != want:
        print("self-test FAILED: RFC 8032 vector 1 does not match", file=sys.stderr)
        return 1
    print("self-test ok (RFC 8032 vector 1)")
    return 0


def main(argv):
    if len(argv) != 2:
        print("usage: sparkle-pubkey.py <key-file> | --self-test", file=sys.stderr)
        return 2
    if argv[1] == "--self-test":
        return _self_test()

    try:
        with open(argv[1], "rb") as handle:
            raw = handle.read()
    except OSError as err:
        # The path is the caller's own argument; the CONTENTS never appear.
        print("cannot read %s: %s" % (argv[1], err.strerror), file=sys.stderr)
        return 2

    # `generate_keys -x` writes "the base64 encoding of the 32-byte private
    # seed" and a trailing newline, so the file is 44 base64 characters. The
    # 96-byte form is what older Sparkle tooling exported — a 64-byte libsodium
    # secret key with the 32-byte public key already appended to it — and a key
    # that has been carried across versions can still be in it.
    try:
        decoded = base64.b64decode(raw.strip(), validate=True)
    except (ValueError, TypeError):
        print("not a base64 Sparkle key file: %s" % argv[1], file=sys.stderr)
        return 2

    if len(decoded) == 32:
        public = public_from_seed(decoded)
    elif len(decoded) == 96:
        public = decoded[64:]
    else:
        print(
            "unexpected key length (%d bytes; expected a 32-byte seed or the "
            "96-byte legacy form): %s" % (len(decoded), argv[1]),
            file=sys.stderr,
        )
        return 2

    print(base64.b64encode(public).decode("ascii"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
