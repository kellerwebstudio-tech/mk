#!/usr/bin/env python3
"""Generates tests/fixtures/CodecVectors.luau: byte-exact test vectors for the pure-Luau codecs
(Util/Base64, Util/Inflate, Util/PngDecoder, MeshData/MeshPack).

Run with:  python3 -I tools/make_codec_fixtures.py
Requires numpy + PIL (same as tools/mesh_embed.py, which is imported for the DDCM packer).

Every vector is a base64 string plus the values the spec recomputes in Luau (lengths, Adler-32 of
the expected output, exact bytes for the small cases). The `embedded` section is derived from the
REAL data modules under src/shared/MeshData/<Id>/ (checksums of the texture's inflated PNG
stream, of its RGBA pixels as PIL decodes them, and of every part's geometry blob) so the end-to-end
specs can verify the production data without shipping a second copy of it. The index files
(src/shared/MeshData/<Id>/init.luau, index version 2) are parsed with a tiny Luau table reader.
"""
import base64
import io
import os
import random
import re
import struct
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mesh_embed  # noqa: E402  (tools/mesh_embed.py: pack_geometry)

from PIL import Image  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join(ROOT, "tests", "fixtures", "CodecVectors.luau")

rng = random.Random(20261007)


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def adler(b: bytes) -> int:
    return zlib.adler32(b) & 0xFFFFFFFF


def crc(b: bytes) -> int:
    return zlib.crc32(b) & 0xFFFFFFFF


# ----------------------------------------------------------------------------------------------
# Luau emission
# ----------------------------------------------------------------------------------------------
def lua_str(s: str) -> str:
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return '"' + re.sub(r"[\x00-\x1f\x7f]", lambda m: "\\%d" % ord(m.group(0)), s) + '"'


def lua_val(v, indent=1) -> str:
    pad = "\t" * indent
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, bytes):
        return lua_str(b64(v))
    if isinstance(v, (list, tuple)):
        items = [lua_val(x, indent + 1) for x in v]
        if sum(len(x) for x in items) < 100 and all("\n" not in x for x in items):
            return "{ " + ", ".join(items) + " }"
        return "{\n" + "".join(pad + "\t" + x + ",\n" for x in items) + pad + "}"
    if isinstance(v, dict):
        parts = []
        for k, val in v.items():
            key = k if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k) else "[" + lua_str(k) + "]"
            parts.append(pad + "\t" + key + " = " + lua_val(val, indent + 1) + ",\n")
        return "{\n" + "".join(parts) + pad + "}"
    raise TypeError(type(v))


# ----------------------------------------------------------------------------------------------
# zlib vectors
# ----------------------------------------------------------------------------------------------
def zvec(name, raw: bytes, stream: bytes, keep_bytes: bool):
    v = {"name": name, "data": stream, "length": len(raw), "adler": adler(raw)}
    if keep_bytes:
        v["expected"] = raw
    return v


def zlib_vectors():
    out = []
    out.append(zvec("empty input", b"", zlib.compress(b"", 9), True))
    out.append(zvec("one byte", b"A", zlib.compress(b"A", 9), True))
    stored_raw = bytes(rng.getrandbits(8) for _ in range(300))
    out.append(zvec("stored block (level 0)", stored_raw, zlib.compress(stored_raw, 0), True))
    text = b"The quick brown fox jumps over the lazy dog. The quick brown fox jumps again!"
    fixed = zlib.compressobj(level=6, strategy=zlib.Z_FIXED)
    fixed_stream = fixed.compress(text) + fixed.flush()
    out.append(zvec("fixed Huffman small text", text, fixed_stream, True))
    dyn_text = (b"Delivery Dash City: " + b"pedal, scoot, drive. " * 40 + b"Lunch rush at the plaza!\n") * 6
    out.append(zvec("dynamic Huffman text", dyn_text, zlib.compress(dyn_text, 9), True))
    rnd = bytes(rng.getrandbits(8) for _ in range(4096))
    out.append(zvec("random bytes", rnd, zlib.compress(rnd, 9), True))
    # a run of one byte (distance-1 matches), short periodic patterns (overlapping copies of every
    # small distance) and the maximum match length 258 appear here
    pattern = b"\x00" * 1000
    for d in range(2, 20):
        pattern += (bytes(range(d)) * (600 // d + 1))[:600]
    pattern += b"ab" * 500 + b"xyz" * 400 + b"\xff" * 258 + b"q" * 259 + b"ABCD" * 300
    out.append(zvec("repeated patterns", pattern, zlib.compress(pattern, 9), True))
    # skewed symbol frequencies: one byte dominates, ~200 others are rare, so the literal tree
    # has codes longer than the 10-bit fast lookup (exercises the slow canonical path)
    rare = list(range(1, 256))
    skewed = bytes(0 if rng.random() < 0.9 else rng.choice(rare) for _ in range(60_000))
    out.append(zvec("skewed symbols (long Huffman codes)", skewed, zlib.compress(skewed, 9), False))
    # 200 KB mixed: text, random, patterns, long-distance repeats (up to the 32 KB window)
    chunks = []
    words = [b"delivery", b"dash", b"city", b"van", b"bicycle", b"scooter", b"order", b"depot", b"plaza", b"rush"]
    while sum(len(c) for c in chunks) < 200_000:
        kind = rng.randrange(4)
        if kind == 0:
            chunks.append(b" ".join(rng.choice(words) for _ in range(400)) + b"\n")
        elif kind == 1:
            chunks.append(bytes(rng.getrandbits(8) for _ in range(rng.randrange(200, 3000))))
        elif kind == 2:
            chunks.append(bytes([rng.randrange(256)]) * rng.randrange(1, 2000))
        else:
            if chunks:
                src = chunks[rng.randrange(len(chunks))]
                chunks.append(src[: rng.randrange(1, len(src) + 1)])
    mixed = b"".join(chunks)[:200_000]
    out.append(zvec("200 KB mixed", mixed, zlib.compress(mixed, 9), False))
    out.append(zvec("200 KB mixed (level 1)", mixed, zlib.compress(mixed, 1), False))
    # multi-block: compress in pieces with full flushes so several blocks (incl. stored) appear
    co = zlib.compressobj(level=9)
    multi = co.compress(dyn_text) + co.flush(zlib.Z_FULL_FLUSH) + co.compress(rnd) + co.flush(zlib.Z_FULL_FLUSH) + co.compress(pattern) + co.flush()
    out.append(zvec("multiple blocks with flushes", dyn_text + rnd + pattern, multi, False))
    return out


def zlib_errors():
    good = zlib.compress(b"hello hello hello hello", 9)
    bad_header = bytes([0x00]) + good[1:]
    bad_check = bytes([0x78, 0x9D]) + good[2:]  # FCHECK wrong (0x789C is valid)
    adler_bad = good[:-1] + bytes([good[-1] ^ 0x01])
    truncated = good[: len(good) // 2]
    trailing = good + b"TRAILING"
    dict_flag = bytes([0x78, 0xBB]) + good[2:]  # FDICT set with a valid FCHECK
    raw_consumed = len(good) - 2 - 4
    return {
        "good": good,
        "goodExpected": b"hello hello hello hello",
        "badHeader": bad_header,
        "badCheck": bad_check,
        "adlerMismatch": adler_bad,
        "truncated": truncated,
        "withTrailing": trailing,
        "presetDict": dict_flag,
        "rawConsumedBytes": raw_consumed,
    }


# ----------------------------------------------------------------------------------------------
# PNG vectors
# ----------------------------------------------------------------------------------------------
def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc(kind + data))


def build_png(width, height, color_type, bit_depth, interlace, idat_payload: bytes, split=1) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, bit_depth, color_type, 0, 0, interlace)
    out = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr)
    if split > 1:
        n = max(1, len(idat_payload) // split)
        pieces = [idat_payload[i : i + n] for i in range(0, len(idat_payload), n)]
    else:
        pieces = [idat_payload]
    for p in pieces:
        out += png_chunk(b"IDAT", p)
    return out + png_chunk(b"IEND", b"")


def filter_rows(rows, bpp, filters):
    """rows: list of bytes (raw scanlines); filters: filter type per row. Returns the filtered data."""
    out = bytearray()
    prev = bytes(len(rows[0]))
    for row, ft in zip(rows, filters):
        out.append(ft)
        for i, x in enumerate(row):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ft == 0:
                pred = 0
            elif ft == 1:
                pred = a
            elif ft == 2:
                pred = b
            elif ft == 3:
                pred = (a + b) // 2
            else:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            out.append((x - pred) & 0xFF)
        prev = row
    return bytes(out)


def to_rgba(im: Image.Image) -> bytes:
    return im.convert("RGBA").tobytes()


def pil_png(im: Image.Image, **kw) -> bytes:
    buf = io.BytesIO()
    im.save(buf, format="PNG", **kw)
    return buf.getvalue()


def pvec(name, png: bytes, width, height, rgba: bytes, color_type):
    assert len(rgba) == width * height * 4
    v = {"name": name, "data": png, "width": width, "height": height, "colorType": color_type, "rgba": rgba, "rgbaAdler": adler(rgba)}
    # PIL cross-check of every vector (the decoder must agree with PIL)
    assert to_rgba(Image.open(io.BytesIO(png))) == rgba, name
    return v


def png_vectors():
    out = []
    im = Image.new("RGB", (1, 1), (200, 100, 50))
    out.append(pvec("1x1 RGB", pil_png(im), 1, 1, to_rgba(im), 2))

    im = Image.new("RGB", (7, 5))
    px = im.load()
    for y in range(5):
        for x in range(7):
            px[x, y] = (x * 36, y * 60, 255 - x * 20 - y * 10)
    out.append(pvec("7x5 RGB gradient", pil_png(im, optimize=True), 7, 5, to_rgba(im), 2))

    im = Image.new("RGBA", (16, 16))
    px = im.load()
    for y in range(16):
        for x in range(16):
            px[x, y] = ((x * 16) % 256, (y * 16) % 256, ((x + y) * 8) % 256, (x * y * 2) % 256)
    out.append(pvec("16x16 RGBA with alpha", pil_png(im, optimize=True), 16, 16, to_rgba(im), 6))

    im = Image.new("L", (9, 9))
    px = im.load()
    for y in range(9):
        for x in range(9):
            px[x, y] = (x * 29 + y * 13) % 256
    out.append(pvec("9x9 grey", pil_png(im, optimize=True), 9, 9, to_rgba(im), 0))

    im = Image.new("LA", (5, 4))
    px = im.load()
    for y in range(4):
        for x in range(5):
            px[x, y] = ((x * 50 + y) % 256, (255 - y * 60) % 256)
    out.append(pvec("5x4 grey+alpha", pil_png(im, optimize=True), 5, 4, to_rgba(im), 4))

    im = Image.new("RGB", (33, 17))
    px = im.load()
    for y in range(17):
        for x in range(33):
            px[x, y] = (rng.randrange(256), rng.randrange(256), rng.randrange(256))
    out.append(pvec("33x17 RGB noise", pil_png(im, optimize=True), 33, 17, to_rgba(im), 2))

    # hand-made PNGs with every filter type on different rows, one per colour type, raw pixels
    # known exactly; also split over several IDAT chunks
    for color_type, bpp, label in ((2, 3, "RGB"), (6, 4, "RGBA"), (0, 1, "grey"), (4, 2, "grey+alpha")):
        width, height = 6, 10
        rows = []
        for y in range(height):
            row = bytearray()
            for x in range(width):
                for ch in range(bpp):
                    row.append((x * 37 + y * 91 + ch * 55 + (x * y) % 7 * 23) % 256)
            rows.append(bytes(row))
        filters = [0, 1, 2, 3, 4, 4, 3, 2, 1, 0]
        payload = zlib.compress(filter_rows(rows, bpp, filters), 9)
        png = build_png(width, height, color_type, 8, 0, payload, split=3)
        im = Image.open(io.BytesIO(png))
        rgba = to_rgba(im)
        out.append(pvec("all filters %s (3 IDAT chunks)" % label, png, width, height, rgba, color_type))
    return out


def png_errors():
    im = Image.new("P", (4, 4))
    im.putpalette([i for i in range(256)] * 3)
    palette = pil_png(im)
    rgb_rows = [bytes(range(12))] * 2
    payload = zlib.compress(filter_rows(rgb_rows, 3, [0, 0]), 9)
    interlaced = build_png(4, 2, 2, 8, 1, payload)
    sixteen = build_png(4, 2, 2, 16, 0, payload)
    good = build_png(4, 2, 2, 8, 0, payload)
    bad_sig = b"\x88PNG\r\n\x1a\n" + good[8:]
    short_data = build_png(4, 3, 2, 8, 0, payload)  # declares 3 rows, stream holds 2
    bad_adler = build_png(4, 2, 2, 8, 0, payload[:-1] + bytes([payload[-1] ^ 1]))
    return {
        "palette": palette,
        "interlaced": interlaced,
        "sixteenBit": sixteen,
        "badSignature": bad_sig,
        "shortData": short_data,
        "adlerMismatch": bad_adler,
        "goodRgba": to_rgba(Image.open(io.BytesIO(good))),
        "good": good,
    }


# ----------------------------------------------------------------------------------------------
# DDCM geometry
# ----------------------------------------------------------------------------------------------
CUBE_OBJ = """# unit cube, 8 positions, 4 uvs, 6 normals, 6 quads (triangulated by the packer)
v -1 -1 1
v 1 -1 1
v 1 1 1
v -1 1 1
v -1 -1 -1
v 1 -1 -1
v 1 1 -1
v -1 1 -1
vt 0 0
vt 1 0
vt 1 1
vt 0 1
vn 0 0 1
vn 0 0 -1
vn 1 0 0
vn -1 0 0
vn 0 1 0
vn 0 -1 0
f 1/1/1 2/2/1 3/3/1 4/4/1
f 6/1/2 5/2/2 8/3/2 7/4/2
f 2/1/3 6/2/3 7/3/3 3/4/3
f 5/1/4 1/2/4 4/3/4 8/4/4
f 4/1/5 3/2/5 7/3/5 8/4/5
f 5/1/6 6/2/6 2/3/6 1/4/6
"""


def ddcm_vector():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "cube.obj")
        with open(path, "w") as w:
            w.write(CUBE_OBJ)
        V, VT, VN, F = mesh_embed.load_obj(path)
        blob, meta = mesh_embed.pack_geometry(V, VT, VN, F)
    # parse the blob back with struct (the same interpretation MeshPack must use)
    assert blob[:4] == b"DDCM"
    version, flags, vc, tc = struct.unpack_from("<HHII", blob, 4)
    bmin = struct.unpack_from("<3f", blob, 16)
    bmax = struct.unpack_from("<3f", blob, 28)
    off = 40
    positions = [struct.unpack_from("<3f", blob, off + i * 12) for i in range(vc)]
    off += vc * 12
    normals = [struct.unpack_from("<3b", blob, off + i * 3) for i in range(vc)]
    off += vc * 3
    uvs = [struct.unpack_from("<2H", blob, off + i * 4) for i in range(vc)]
    off += vc * 4
    tris = [struct.unpack_from("<3H", blob, off + i * 6) for i in range(tc)]
    off += tc * 6
    assert off == len(blob)
    return {
        "data": blob,
        "length": len(blob),
        "vertexCount": vc,
        "triangleCount": tc,
        "bboxMin": [float(x) for x in bmin],
        "bboxMax": [float(x) for x in bmax],
        "positions": [[float(x) for x in p] for p in positions],
        "normalsRaw": [list(n) for n in normals],  # i8 values; MeshPack divides by 127
        "uvsRaw": [list(u) for u in uvs],  # u16 values; MeshPack divides by 65535
        "triangles": [i + 1 for t in tris for i in t],  # 1-based, flat
        "badMagic": b"DDCX" + blob[4:],
        "badVersion": blob[:4] + struct.pack("<H", 2) + blob[6:],
        "truncated": blob[: len(blob) - 7],
    }


# ----------------------------------------------------------------------------------------------
# checksums of the real embedded data (src/shared/MeshData/<Id>/, index version 2)
# ----------------------------------------------------------------------------------------------
class _LuauTable:
    """Reads the table literal returned by a generated index module: `{ key = value, ... }` with
    string / number / nil / boolean / nested table values (keyed tables become dicts, lists stay
    lists). Just enough for tools/mesh_embed.py's output; not a general Luau parser."""

    def __init__(self, text: str):
        self.text = text
        self.pos = 0

    def skip(self):
        while True:
            m = re.compile(r"\s+|--[^\n]*").match(self.text, self.pos)
            if not m or m.end() == self.pos:
                return
            self.pos = m.end()

    def value(self):
        self.skip()
        t = self.text
        if t.startswith("{", self.pos):
            return self.table()
        if t.startswith('"', self.pos):
            m = re.compile(r'"((?:[^"\\]|\\.)*)"').match(t, self.pos)
            self.pos = m.end()
            return m.group(1)
        for word, val in (("nil", None), ("true", True), ("false", False)):
            if re.compile(word + r"\b").match(t, self.pos):
                self.pos += len(word)
                return val
        m = re.compile(r"-?\d+(\.\d+)?([eE][-+]?\d+)?").match(t, self.pos)
        if not m:
            raise ValueError("bad Luau value at %d: %r" % (self.pos, t[self.pos : self.pos + 30]))
        self.pos = m.end()
        return float(m.group(0)) if (m.group(1) or m.group(2)) else int(m.group(0))

    def table(self):
        assert self.text[self.pos] == "{"
        self.pos += 1
        items, keyed = [], {}
        while True:
            self.skip()
            if self.text.startswith("}", self.pos):
                self.pos += 1
                break
            m = re.compile(r"([A-Za-z_]\w*)\s*=(?!=)").match(self.text, self.pos)
            if m:
                self.pos = m.end()
                keyed[m.group(1)] = self.value()
            else:
                items.append(self.value())
            self.skip()
            if self.text.startswith(",", self.pos) or self.text.startswith(";", self.pos):
                self.pos += 1
        if keyed and items:
            raise ValueError("mixed table at %d" % self.pos)
        return keyed if keyed else items


def read_index(path: str) -> dict:
    text = open(path, encoding="utf-8").read()
    m = re.search(r"^return\s*", text, re.M)
    if not m:
        raise ValueError(f"{path}: no `return` statement")
    index = _LuauTable(text[m.end() :]).value()
    if not isinstance(index, dict) or index.get("version") != 2:
        raise ValueError(f"{path}: not a version-2 MeshData index")
    return index


def read_chunk(path: str) -> str:
    m = re.search(r'return "([A-Za-z0-9+/=]*)"', open(path, encoding="utf-8").read())
    if not m:
        raise ValueError(f"{path}: no base64 string")
    return m.group(1)


def read_named_chunks(vdir: str, names) -> bytes:
    return base64.b64decode("".join(read_chunk(os.path.join(vdir, f"{n}.luau")) for n in names))


def png_idat(png: bytes) -> bytes:
    pos = 8
    data = b""
    while pos + 8 <= len(png):
        length = struct.unpack_from(">I", png, pos)[0]
        kind = png[pos + 4 : pos + 8]
        if kind == b"IDAT":
            data += png[pos + 8 : pos + 8 + length]
        pos += 12 + length
    return data


def embedded_vectors():
    out = {}
    base = os.path.join(ROOT, "src", "shared", "MeshData")
    for eid in sorted(os.listdir(base)):
        vdir = os.path.join(base, eid)
        index_path = os.path.join(vdir, "init.luau")
        if not os.path.isdir(vdir) or not os.path.exists(index_path):
            continue
        index = read_index(index_path)
        assert index["id"] == eid, (eid, index["id"])
        entry = {
            "kind": index["kind"],
            "textured": index.get("texture") is not None,
            "bboxMin": index["bboxMin"],
            "bboxMax": index["bboxMax"],
        }
        tex_index = index.get("texture")
        if tex_index is not None:
            tex = read_named_chunks(vdir, [f"T{i}" for i in range(1, tex_index["chunks"] + 1)])
            assert len(tex) == tex_index["bytes"], (eid, len(tex), tex_index["bytes"])
            im = Image.open(io.BytesIO(tex))
            assert im.size == (tex_index["width"], tex_index["height"]), (eid, im.size)
            raw = zlib.decompress(png_idat(tex))
            rgba = to_rgba(im)
            entry.update(
                {
                    "textureBytes": len(tex),
                    "textureChunks": tex_index["chunks"],
                    "textureAdler": adler(tex),
                    "width": im.size[0],
                    "height": im.size[1],
                    "idatAdler": adler(raw),  # the Adler-32 the zlib trailer carries
                    "rgbaAdler": adler(rgba),  # Adler-32 of the RGBA8 pixels (as PIL decodes them)
                }
            )
        parts = []
        for part in index["parts"]:
            blob = read_named_chunks(vdir, part["chunks"])
            assert len(blob) == part["bytes"], (eid, part["name"], len(blob), part["bytes"])
            assert blob[:4] == b"DDCM", (eid, part["name"])
            version, flags, vc, tc = struct.unpack_from("<HHII", blob, 4)
            assert version == 1 and vc == part["vertexCount"] and tc == part["triangleCount"], (eid, part["name"])
            bmin = struct.unpack_from("<3f", blob, 16)
            bmax = struct.unpack_from("<3f", blob, 28)
            pivot = part.get("pivot")
            # the index bbox is in entry coordinates; the blob's own bbox is relative to the pivot
            for k in range(3):
                shift = pivot[k] if pivot else 0.0
                assert abs(bmin[k] + shift - part["bboxMin"][k]) < 2e-3, (eid, part["name"], "bboxMin", k)
                assert abs(bmax[k] + shift - part["bboxMax"][k]) < 2e-3, (eid, part["name"], "bboxMax", k)
            p = {
                "name": part["name"],
                "bytes": len(blob),
                "chunks": len(part["chunks"]),
                "adler": adler(blob),
                "vertexCount": vc,
                "triangleCount": tc,
                "bboxMin": part["bboxMin"],
                "bboxMax": part["bboxMax"],
                "blobBboxMin": [float(x) for x in bmin],  # as stored in the DDCM header
                "blobBboxMax": [float(x) for x in bmax],
            }
            if pivot is not None:
                p["pivot"] = pivot
            parts.append(p)
        entry["parts"] = parts
        out[eid] = entry
    return out


# ----------------------------------------------------------------------------------------------
def base64_vectors():
    out = []
    for raw in (b"", b"f", b"fo", b"foo", b"foob", b"fooba", b"foobar", bytes(range(256)), bytes(rng.getrandbits(8) for _ in range(1001))):
        out.append({"raw": raw, "encoded": b64(raw)})
    return {
        "vectors": out,
        "whitespace": "Zm9v\nYmFy\r\n  Zm9v ",  # "foobarfoo" with whitespace
        "whitespaceExpected": b"foobarfoo",
        "unpadded": "Zm9vYg",  # "foob" without padding
        "unpaddedExpected": b"foob",
        "badChar": "Zm9v$mFy",
        "badLength": "Zm9vY",
    }


def main():
    vectors = {
        "base64": base64_vectors(),
        "zlib": zlib_vectors(),
        "zlibErrors": zlib_errors(),
        "png": png_vectors(),
        "pngErrors": png_errors(),
        "ddcm": ddcm_vector(),
        "embedded": embedded_vectors(),
    }
    header = (
        "--!nocheck\n"
        "-- GENERATED by tools/make_codec_fixtures.py (python3 -I tools/make_codec_fixtures.py); do not edit.\n"
        "-- Test vectors for Util/Base64, Util/Inflate, Util/PngDecoder and MeshData/MeshPack: every binary\n"
        "-- field is a base64 string; `adler` fields are Adler-32 values of the expected output.\n"
        "return "
    )
    text = header + lua_val(vectors, 0) + "\n"
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as w:
        w.write(text)
    print(f"wrote {os.path.relpath(OUT, ROOT)} ({len(text):,} chars; {len(vectors['zlib'])} zlib, {len(vectors['png'])} png vectors; embedded: {', '.join(vectors['embedded'])})")


if __name__ == "__main__":
    main()
