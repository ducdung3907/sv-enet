#!/usr/bin/env python3
"""Generate test vectors for tb_enet_crc32.sv.

Reference: Python's zlib.crc32, which is the Ethernet CRC-32. The design's
`crc` output is the raw register (reflected, not inverted), so the expected
value after a message is  zlib.crc32(msg) ^ 0xFFFFFFFF.

Messages:
  - the classic check string "123456789" (zlib 0xCBF43926)
  - an empty message (state stays 0xFFFFFFFF)
  - every length 1..16, then random lengths up to 1518, random bytes
  - frames with their FCS appended (low byte first), which must leave the
    residue state 0xDEBB20E3

Output (one value per line, hex, read with $readmemh):
  tb/vectors/crc32_data.hex  all message bytes, concatenated
  tb/vectors/crc32_len.hex   first line = number of messages, then one length each
  tb/vectors/crc32_exp.hex   expected `crc` after each message

Deterministic (fixed seed), so the files only change when this script does.
Run from the repository root:  python3 tb/gen_crc32_vectors.py
"""
import os
import random
import struct
import zlib

SEED = 3907
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")
RESIDUE = 0xDEBB20E3


def state_after(msg: bytes) -> int:
    return zlib.crc32(msg) ^ 0xFFFFFFFF


def with_fcs(frame: bytes) -> bytes:
    return frame + struct.pack("<I", zlib.crc32(frame))


def main() -> None:
    rng = random.Random(SEED)
    msgs = [b"123456789", b""]
    msgs += [bytes(rng.randrange(256) for _ in range(n)) for n in range(1, 17)]
    msgs += [bytes(rng.randrange(256) for _ in range(rng.randrange(17, 1519)))
             for _ in range(30)]
    # Frames with FCS appended: minimum (60 + 4), maximum (1514 + 4), random
    fcs_lens = [60, 1514] + [rng.randrange(60, 1515) for _ in range(14)]
    fcs_msgs = [with_fcs(bytes(rng.randrange(256) for _ in range(n))) for n in fcs_lens]
    msgs += fcs_msgs

    # Self-checks on the reference itself
    assert state_after(b"123456789") == 0xCBF43926 ^ 0xFFFFFFFF
    assert state_after(b"") == 0xFFFFFFFF
    for m in fcs_msgs:
        assert state_after(m) == RESIDUE

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "crc32_data.hex"), "w") as f:
        for m in msgs:
            for b in m:
                f.write(f"{b:02x}\n")
    with open(os.path.join(OUT, "crc32_len.hex"), "w") as f:
        f.write(f"{len(msgs):08x}\n")
        for m in msgs:
            f.write(f"{len(m):08x}\n")
    with open(os.path.join(OUT, "crc32_exp.hex"), "w") as f:
        for m in msgs:
            f.write(f"{state_after(m):08x}\n")

    total = sum(len(m) for m in msgs)
    print(f"{len(msgs)} messages, {total} bytes, "
          f"{len(fcs_msgs)} with FCS (expect residue {RESIDUE:08x}) -> {OUT}")


if __name__ == "__main__":
    main()