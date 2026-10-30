#!/usr/bin/env python3
"""PoB build codes <-> XML.

  pobcode.py decode <code file | pobb.in URL | -> [out.xml]   code -> XML (stdout if no out)
  pobcode.py encode <build.xml> [out.txt]                      XML -> code (stdout if no out)

A pobb.in URL is fetched from https://pobb.in/<id>/raw (needs network access to pobb.in).
"""
import base64, sys, urllib.request, zlib


def decode(code: str) -> bytes:
    code = "".join(code.split())
    code = code.replace("-", "+").replace("_", "/")
    code += "=" * (-len(code) % 4)
    return zlib.decompress(base64.b64decode(code))


def encode(xml: bytes) -> str:
    return base64.urlsafe_b64encode(zlib.compress(xml, 9)).decode()


def read_code(src: str) -> str:
    if src.startswith("http"):
        url = src.rstrip("/")
        if not url.endswith("/raw"):
            url += "/raw"
        with urllib.request.urlopen(url, timeout=30) as r:
            return r.read().decode()
    if src == "-":
        return sys.stdin.read()
    return open(src).read()


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("decode", "encode"):
        print(__doc__)
        sys.exit(1)
    mode, src = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else None
    if mode == "decode":
        data = decode(read_code(src))
        if out:
            open(out, "wb").write(data)
        else:
            sys.stdout.write(data.decode("utf-8", "replace"))
    else:
        code = encode(open(src, "rb").read())
        if out:
            open(out, "w").write(code)
        else:
            print(code)


if __name__ == "__main__":
    main()
