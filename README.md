# sv-enet
SystemVerilog 1G Ethernet stack (RGMII, MAC, ARP, IPv4, UDP) for Artix-7; target: 100 MB/s UDP echo on QMTech Wukong
## Progress

| Date | Module | Test | Status |
| --- | --- | --- | --- |
| 2026-11-10 | `rtl/enet_crc32.sv`: Ethernet CRC-32, one byte per clock | `tb/tb_enet_crc32.sv`, 64 messages vs Python `zlib` | PASS |

Run all tests: `./sim/run_all.sh` (Icarus Verilog 12). Regenerate vectors: `python3 tb/gen_crc32_vectors.py`.