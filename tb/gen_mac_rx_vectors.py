#!/usr/bin/env python3
"""Generate test vectors for tb_enet_mac_rx.sv (enet_gmii_rx -> enet_mac_rx).

Stimulus is cycle by cycle on the GMII pins; the expected output is the list of
bytes enet_mac_rx must emit (with tlast/tuser) plus the expected number of
pulses on each stat_* output. The reference is Python's zlib.crc32.

Scenarios (in this order, separated by inter-frame gaps):
  - good frames: 64 bytes (minimum), 65, 100, 1518 (maximum), random sizes
  - preamble lengths 0 (D5 first), 1, 3, 7, 10
  - CRC errors: one flipped bit in the data, one in the FCS
  - rx_er during a frame (bad) and rx_er in the gap only (frame still good)
  - runts with a correct CRC: 63, 20, 5 bytes (output, tuser=1); 4, 1, 0 bytes
    (nothing output, stat_runt only)
  - too long with a correct CRC: 1519 and 3000 bytes (counter must saturate)
  - a frame with a broken preamble and no D5 anywhere: must be ignored
  - a burst of back-to-back frames with the minimum 12-cycle gap

"Bytes" below = everything after the SFD, FCS included (that is what the
design's byte counter counts).

Files (one value per line, hex, read with $readmemh):
  tb/vectors/mac_rx_in.hex    per cycle: {rx_er, rx_dv, rxd[7:0]} (10 bits)
  tb/vectors/mac_rx_exp.hex   per output beat: {tlast, tuser, tdata[7:0]}
  tb/vectors/mac_rx_meta.hex  n_cycles, n_beats, then expected pulse counts:
                              good, crc_err, runt, too_long, rx_er

Run from the repository root:  python3 tb/gen_mac_rx_vectors.py
"""
import os
import random
import struct
import zlib

SEED = 3907
MAX_FRAME = 1518
RESIDUE = 0xDEBB20E3
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")

rng = random.Random(SEED)
cycles = []          # (rx_er, rx_dv, rxd)
beats = []           # (tlast, tuser, data)
stats = dict(good=0, crc_err=0, runt=0, too_long=0, rx_er=0)


def rand_bytes(n, avoid_d5=False):
    out = []
    for _ in range(n):
        b = rng.randrange(256)
        while avoid_d5 and b == 0xD5:
            b = rng.randrange(256)
        out.append(b)
    return bytes(out)


def with_fcs(body: bytes) -> bytes:
    return body + struct.pack("<I", zlib.crc32(body))


def residue_ok(b: bytes) -> bool:
    return (zlib.crc32(b) ^ 0xFFFFFFFF) == RESIDUE


def gap(n, er_in_gap=False):
    for i in range(n):
        cycles.append((1 if (er_in_gap and i == n // 2) else 0, 0, rng.randrange(256)))


def frame(b: bytes, preamble=7, er_at=None, gap_after=12):
    """Send preamble + D5 + b (b already contains the FCS) and record what
    enet_mac_rx must output. er_at = index into b where rx_er is raised."""
    for _ in range(preamble):
        cycles.append((0, 1, 0x55))
    cycles.append((0, 1, 0xD5))
    for i, x in enumerate(b):
        cycles.append((1 if er_at == i else 0, 1, x))
    gap(gap_after)

    n = len(b)
    if n < 5:
        stats["runt"] += 1
        return
    crc_bad = not residue_ok(b)
    er = er_at is not None
    runt = n < 64
    long_ = n > MAX_FRAME
    bad = crc_bad or er or runt or long_
    for i in range(n - 4):
        last = i == n - 5
        beats.append((1 if last else 0, (1 if bad else 0) if last else 0, b[i]))
    if bad:
        stats["crc_err"] += crc_bad
        stats["rx_er"] += er
        stats["runt"] += runt
        stats["too_long"] += long_
    else:
        stats["good"] += 1


def junk_frame(n):
    """rx_dv high with a broken preamble and no D5 anywhere: must be ignored."""
    for x in bytes([0x55, 0x55, 0x12]) + rand_bytes(n, avoid_d5=True):
        cycles.append((0, 1, x))
    gap(12)


def main():
    gap(20)
    # good frames, standard preamble
    for n in [60, 61, 96, 1514]:
        frame(with_fcs(rand_bytes(n)))
    for _ in range(6):
        frame(with_fcs(rand_bytes(rng.randrange(60, 1515))), gap_after=rng.randrange(12, 40))
    # preamble lengths
    for p in [0, 1, 3, 10]:
        frame(with_fcs(rand_bytes(100)), preamble=p)
    # CRC errors
    f = bytearray(with_fcs(rand_bytes(200))); f[50] ^= 0x10; frame(bytes(f))
    f = bytearray(with_fcs(rand_bytes(200))); f[-2] ^= 0x01; frame(bytes(f))
    # rx_er during the frame, and only in the gap
    frame(with_fcs(rand_bytes(150)), er_at=70)
    gap(5, er_in_gap=True)
    frame(with_fcs(rand_bytes(150)))
    # runts with a correct CRC (sizes include the FCS)
    for n in [63, 20, 5]:
        frame(with_fcs(rand_bytes(n - 4)))
    for n in [4, 1, 0]:
        frame(rand_bytes(n))
    # too long with a correct CRC
    for n in [1519, 3000]:
        frame(with_fcs(rand_bytes(n - 4)))
    # broken preamble, ignored
    junk_frame(80)
    # back-to-back burst, minimum gap
    for _ in range(8):
        frame(with_fcs(rand_bytes(rng.randrange(60, 300))), gap_after=12)
    gap(30)

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "mac_rx_in.hex"), "w") as fo:
        for er, dv, d in cycles:
            fo.write(f"{(er << 9) | (dv << 8) | d:03x}\n")
    with open(os.path.join(OUT, "mac_rx_exp.hex"), "w") as fo:
        for last, user, d in beats:
            fo.write(f"{(last << 9) | (user << 8) | d:03x}\n")
    with open(os.path.join(OUT, "mac_rx_meta.hex"), "w") as fo:
        for v in [len(cycles), len(beats), stats["good"], stats["crc_err"],
                  stats["runt"], stats["too_long"], stats["rx_er"]]:
            fo.write(f"{v:08x}\n")
    print(f"{len(cycles)} cycles, {len(beats)} output beats, expected pulses {stats} -> {OUT}")


if __name__ == "__main__":
    main()