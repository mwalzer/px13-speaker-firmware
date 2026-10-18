#!/usr/bin/env python3
"""
Extract the TAS2783 calibration firmware from ASUS's "TI SmartAMP" Windows
driver installer, using only the Python standard library (no 7z, cabextract
or Wine needed).

The installer EXE carries its payload as a plain 7z archive appended near the
end of the file. This script locates that archive, reads its file list,
decompresses it with the stdlib `lzma` module, and writes out the firmware
blobs for the requested PCI subsystem id - renamed to the names the Linux
tas2783 driver requests (the "0x" is dropped: 1714-1-0x8.bin -> 1714-1-8.bin).

Nothing from the installer is executed.

Usage:
    python3 extract-firmware.py SmartAMP_TI_*.exe [--outdir DIR] [--subsys 1714]
    python3 extract-firmware.py SmartAMP_TI_*.exe --list
"""

import argparse
import hashlib
import lzma
import os
import re
import struct
import sys
import zlib

SIGNATURE = b"7z\xbc\xaf\x27\x1c"

# 7z property ids
K_END, K_HEADER, K_MAIN_STREAMS, K_FILES_INFO = 0x00, 0x01, 0x04, 0x05
K_PACK_INFO, K_UNPACK_INFO, K_SUBSTREAMS = 0x06, 0x07, 0x08
K_SIZE, K_CRC, K_FOLDER, K_CODERS_UNPACK_SIZE = 0x09, 0x0A, 0x0B, 0x0C
K_NUM_UNPACK_STREAM, K_EMPTY_STREAM, K_NAME, K_ENCODED_HEADER = 0x0D, 0x0E, 0x11, 0x17

# 7z coder ids -> lzma filter
CODER_COPY, CODER_LZMA, CODER_LZMA2, CODER_BCJ_X86 = "00", "030101", "21", "03030103"


class Reader:
    def __init__(self, buf):
        self.buf, self.pos = buf, 0

    def byte(self):
        v = self.buf[self.pos]
        self.pos += 1
        return v

    def take(self, n):
        v = self.buf[self.pos:self.pos + n]
        self.pos += n
        return v

    def number(self):
        """7z variable-length integer."""
        first, mask = self.byte(), 0x80
        for i in range(8):
            if not first & mask:
                low = int.from_bytes(self.take(i), "little")
                return low | ((first & (mask - 1)) << (8 * i))
            mask >>= 1
        return int.from_bytes(self.take(8), "little")

    def bits(self, n):
        out, cur, mask = [], 0, 0
        for _ in range(n):
            if mask == 0:
                cur, mask = self.byte(), 0x80
            out.append(bool(cur & mask))
            mask >>= 1
        return out

    def skip_digests(self, n):
        defined = [True] * n if self.byte() else self.bits(n)
        self.take(4 * sum(defined))


def unpack_size(folder):
    """Size of the folder's final output (the coder output nobody consumes)."""
    bound = {out_index for _, out_index in folder["bind_pairs"]}
    return next(s for i, s in enumerate(folder["sizes"]) if i not in bound)


def read_streams_info(r):
    info = {"pack_pos": 0, "pack_sizes": [], "folders": [], "sub_sizes": None}
    while True:
        prop = r.byte()
        if prop == K_END:
            return info
        if prop == K_PACK_INFO:
            info["pack_pos"] = r.number()
            n = r.number()
            while (sub := r.byte()) != K_END:
                if sub == K_SIZE:
                    info["pack_sizes"] = [r.number() for _ in range(n)]
                elif sub == K_CRC:
                    r.skip_digests(n)
        elif prop == K_UNPACK_INFO:
            if r.byte() != K_FOLDER:
                raise ValueError("unexpected 7z folder layout")
            nfolders = r.number()
            if r.byte() != 0:
                raise ValueError("external 7z folders are not supported")
            for _ in range(nfolders):
                coders = []
                for _ in range(r.number()):
                    flags = r.byte()
                    coder_id = r.take(flags & 0x0F).hex()
                    if flags & 0x10:
                        raise ValueError("complex 7z coders are not supported")
                    props = r.take(r.number()) if flags & 0x20 else b""
                    coders.append((coder_id, props))
                bind_pairs = [(r.number(), r.number()) for _ in range(len(coders) - 1)]
                info["folders"].append({"coders": coders, "bind_pairs": bind_pairs})
            if r.byte() != K_CODERS_UNPACK_SIZE:
                raise ValueError("missing 7z unpack sizes")
            for folder in info["folders"]:
                folder["sizes"] = [r.number() for _ in folder["coders"]]
            sub = r.byte()
            if sub == K_CRC:
                r.skip_digests(nfolders)
                sub = r.byte()
            if sub != K_END:
                raise ValueError("malformed 7z unpack info")
        elif prop == K_SUBSTREAMS:
            counts = [1] * len(info["folders"])
            sub = r.byte()
            if sub == K_NUM_UNPACK_STREAM:
                counts = [r.number() for _ in info["folders"]]
                sub = r.byte()
            sizes = []
            for folder, count in zip(info["folders"], counts):
                if count == 0:
                    continue
                part = [r.number() for _ in range(count - 1)] if sub == K_SIZE else []
                part.append(unpack_size(folder) - sum(part))
                sizes += part
            if sub == K_SIZE:
                sub = r.byte()
            if sub == K_CRC:
                r.skip_digests(sum(counts))
                sub = r.byte()
            if sub != K_END:
                raise ValueError("malformed 7z substreams info")
            info["sub_sizes"] = sizes


def decode_folder(folder, packed):
    chain = []
    for coder_id, props in folder["coders"]:
        if coder_id == CODER_LZMA:
            lc, rest = props[0] % 9, props[0] // 9
            chain.append({"id": lzma.FILTER_LZMA1, "lc": lc, "lp": rest % 5, "pb": rest // 5,
                          "dict_size": struct.unpack("<I", props[1:5])[0]})
        elif coder_id == CODER_LZMA2:
            chain.append({"id": lzma.FILTER_LZMA2,
                          "dict_size": (2 | (props[0] & 1)) << (props[0] // 2 + 11)})
        elif coder_id == CODER_BCJ_X86:
            chain.append({"id": lzma.FILTER_X86})
        elif coder_id != CODER_COPY:
            raise ValueError(f"unsupported 7z coder {coder_id}")
    size = unpack_size(folder)
    if not chain:
        return packed[:size]
    # liblzma wants the compressor as the last filter in a raw chain
    chain.sort(key=lambda f: f["id"] in (lzma.FILTER_LZMA1, lzma.FILTER_LZMA2))
    return lzma.LZMADecompressor(lzma.FORMAT_RAW, filters=chain).decompress(packed, max_length=size)


def decode_streams(data, base, info):
    offset = base + 32 + info["pack_pos"]
    for folder, pack_size in zip(info["folders"], info["pack_sizes"]):
        yield decode_folder(folder, data[offset:offset + pack_size])
        offset += pack_size


def find_archive(data):
    """Return the offset of the first 7z signature with a valid start header."""
    for m in re.finditer(re.escape(SIGNATURE), data):
        o = m.start()
        header = data[o:o + 32]
        if len(header) == 32 and zlib.crc32(header[12:32]) == struct.unpack("<I", header[8:12])[0]:
            return o
    raise SystemExit("no embedded 7z archive found in this file")


def read_archive(data):
    base = find_archive(data)
    next_offset, next_size = struct.unpack("<QQ", data[base + 12:base + 28])
    r = Reader(data[base + 32 + next_offset:base + 32 + next_offset + next_size])
    prop = r.byte()
    if prop == K_ENCODED_HEADER:
        r = Reader(next(decode_streams(data, base, read_streams_info(r))))
        prop = r.byte()
    if prop != K_HEADER:
        raise ValueError("unexpected 7z header")

    main, names, empty = None, [], []
    while (prop := r.byte()) != K_END:
        if prop == K_MAIN_STREAMS:
            main = read_streams_info(r)
        elif prop == K_FILES_INFO:
            nfiles = r.number()
            while (ptype := r.byte()) != K_END:
                blob = r.take(r.number())
                if ptype == K_EMPTY_STREAM:
                    empty = Reader(blob).bits(nfiles)
                elif ptype == K_NAME:
                    names = blob[1:].decode("utf-16-le").split("\x00")[:nfiles]
    empty += [False] * (len(names) - len(empty))
    files = [n for n, e in zip(names, empty) if not e]
    sizes = main["sub_sizes"] or [unpack_size(f) for f in main["folders"]]
    return base, main, list(zip(files, sizes))


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("installer", help="ASUS SmartAMP_TI_*.exe")
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)),
                    help="where to write the .bin files (default: this script's directory)")
    ap.add_argument("--subsys", default="1714",
                    help="PCI subsystem id prefix of the blobs to extract (default: 1714 = PX13)")
    ap.add_argument("--list", action="store_true", help="only list the archive contents")
    args = ap.parse_args()

    with open(args.installer, "rb") as f:
        data = f.read()
    base, streams, files = read_archive(data)

    if args.list:
        for name, size in files:
            print(f"{size:10}  {name}")
        return

    pattern = re.compile(rf"(?:^|[\\/]){re.escape(args.subsys)}-(\d+)-0x([0-9a-f]+)\.bin$", re.I)
    wanted = {name for name, _ in files if pattern.search(name)}
    if not wanted:
        raise SystemExit(f"no {args.subsys}-*.bin firmware in this installer (try --list)")

    payload = b"".join(decode_streams(data, base, streams))
    pos = 0
    for name, size in files:
        blob = payload[pos:pos + size]
        pos += size
        if name not in wanted:
            continue
        link, addr = pattern.search(name).groups()
        out = os.path.join(args.outdir, f"{args.subsys}-{link}-{addr.upper()}.bin")
        with open(out, "wb") as f:
            f.write(blob)
        print(f"{hashlib.sha256(blob).hexdigest()}  {out}  ({size} bytes, from {name})")


if __name__ == "__main__":
    sys.exit(main())
