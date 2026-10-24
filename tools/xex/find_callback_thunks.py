#!/usr/bin/env python3
"""Enumera los thunks de llamada virtual del .text de NS3FB.

Contexto: el juego llama a cientos de funciones pequenas que el codegen no
descubre (no estan en .pdata, no aparecen como dato en la imagen y no se
materializan con lis/ori): se alcanzan por punteros construidos en tiempo de
ejecucion. Cada una es un thunk de 4 instrucciones:

    lwz  r12, 0(r3)          # 81 83 00 00
    lwz  r11, OFFSET(r12)    # 81 6C xx xx
    mtctr r11                # 7D 69 03 A6
    bctr                     # 4E 80 04 20

Sembrar esas direcciones en ci/entrypoint_seeds.txt hace que el codegen las
compile como funciones reales en vez de caer en el stub vacio (NS3FB-TRAP).

Uso:
    python3 tools/xex/unxex.py ci/game/default.xex /tmp/image.bin
    python3 tools/xex/find_callback_thunks.py /tmp/image.bin [--lo 825A7000 --hi 825A8000]
"""
import argparse
import struct

TEXT_VA, TEXT_RAW, TEXT_SZ = 0x821B0000, 0x1AFE00, 0x74DA00


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--lo", default="825A7000")
    ap.add_argument("--hi", default="825A8000")
    args = ap.parse_args()
    lo, hi = int(args.lo, 16), int(args.hi, 16)

    img = open(args.image, "rb").read()
    text = img[TEXT_RAW:TEXT_RAW + TEXT_SZ]
    found = []
    for i in range(0, len(text) - 16, 4):
        w0, w1, w2, w3 = struct.unpack(">IIII", text[i:i + 16])
        if (w0 == 0x81830000 and (w1 & 0xFFFF0000) == 0x816C0000
                and w2 == 0x7D6903A6 and w3 == 0x4E800420):
            addr = TEXT_VA + i
            if lo <= addr < hi:
                found.append(addr)
    for addr in found:
        print(f"0x{addr:08X}")
    print(f"# {len(found)} thunks en 0x{lo:08X}-0x{hi:08X}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
