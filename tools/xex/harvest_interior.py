#!/usr/bin/env python3
"""Cosecha estática de entradas interiores, sin encender el iPhone.

Para qué sirve
--------------
El invitado llama por puntero a direcciones que caen DENTRO de una función (colas
compartidas: lógica final + epílogo). Compiladas desde ahí, el cuerpo desapila un
frame que nunca apiló. Este script las encuentra en el `.xex`, sin dispositivo.

Qué encuentra y qué no (importante)
-----------------------------------
* **Sí encuentra** los punteros que están en tablas de datos (`.rdata` / `.data`).
  Esas tablas están en la imagen y se pueden leer.
* **No encuentra** las direcciones que el juego calcula en runtime. La familia de
  callbacks `0x825A7xxx` es justo eso: sus direcciones NO existen como datos en
  el `.xex` (verificado: 0 referencias). Para esas, el arreglo es el detector en
  runtime de `ci/rexglue-alias-interior.patch`, que no necesita cosecha previa.

Uso
---
    python3 tools/xex/unxex.py ci/game/default.xex /tmp/image.bin
    python3 tools/xex/harvest_interior.py /tmp/image.bin
    python3 tools/xex/harvest_interior.py /tmp/image.bin --cpp   # tabla para el parche
"""
import argparse
import struct
import sys

# Layout del .text de este ejecutable (NTSC-U, ver ci/game/README.md).
TEXT_VA, TEXT_RAW, TEXT_SZ = 0x821B0000, 0x1AFE00, 0x74DA00
LOAD = 0x82000000

# Terminadores: lo que hay justo antes de un inicio de función de verdad.
TERMINATORS = {0x4E800020, 0x4E800420, 0x00000000, 0x60000000}  # blr, bctr, relleno, nop


def load32(img, addr):
    off = TEXT_RAW + (addr - TEXT_VA)
    if off < 0 or off + 4 > len(img):
        return None
    return struct.unpack(">I", img[off:off + 4])[0]


def is_terminator(w):
    if w is None:
        return True
    return w in TERMINATORS or (w & 0xFC000003) == 0x48000000  # b


def is_thunk(img, addr):
    """Thunk de llamada virtual de 16 bytes: lwz r12,0(r3) / lwz r11,OFF(r12) / mtctr / bctr."""
    w = [load32(img, addr + i * 4) for i in range(4)]
    if None in w:
        return False
    return (w[0] == 0x81830000 and (w[1] & 0xFFFF0000) == 0x816C0000
            and w[2] == 0x7D6903A6 and w[3] == 0x4E800420)


def is_function_start(img, addr):
    w0, w1 = load32(img, addr), load32(img, addr + 4)
    if w0 is None or not is_terminator(load32(img, addr - 4)):
        return False
    return ((w0 == 0x7D8802A6 and w1 == 0x9181FFF8)   # mflr r12 / stw r12,-8(r1)
            or (w0 & 0xFFFF0000) == 0x94210000         # stwu r1,-N(r1)
            or w0 == 0x7C0802A6                        # mflr r0
            or w0 == 0x4E800020)                       # blr suelto


def containing_start(img, addr, limit=0x1400):
    """Inicio de la función que contiene `addr`, exigiendo que la contenga."""
    for back in range(4, limit + 1, 4):
        cand = addr - back
        w0, w1 = load32(img, cand), load32(img, cand + 4)
        if w0 is None:
            return None
        prologue = ((w0 == 0x7D8802A6 and w1 == 0x9181FFF8)
                    or (w0 & 0xFFFF0000) == 0x94210000
                    or w0 == 0x7C0802A6)
        if not prologue or not is_terminator(load32(img, cand - 4)):
            continue
        for fwd in range(0, limit + 1, 4):
            if load32(img, cand + fwd) == 0x4E800020:      # primer blr
                return cand if (cand + fwd) >= addr else None
        return None
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("image", help="imagen descifrada (unxex.py) o el propio .xex")
    ap.add_argument("--cpp", action="store_true", help="emitir la tabla C++ del parche")
    ap.add_argument("--min-run", type=int, default=4,
                    help="palabras seguidas apuntando a .text para considerar tabla (def. 4)")
    args = ap.parse_args()

    raw = open(args.image, "rb").read()
    if raw[:4] == b"XEX2":
        print("Esto es un .xex cifrado: descífralo antes con tools/xex/unxex.py", file=sys.stderr)
        return 1
    img = raw  # ventana del .text: los offsets se calculan con TEXT_RAW

    text_end = TEXT_VA + TEXT_SZ
    interiors = {}
    starts = thunks = 0

    # Recorrer los datos que hay antes y después del .text buscando rachas de
    # punteros. Fuera de las rachas, cualquier valor de 32 bits parece un puntero.
    regions = [(0, TEXT_RAW), (TEXT_RAW + TEXT_SZ, len(img))]
    for lo, hi in regions:
        run = []
        for off in range(lo, hi - 3, 4):
            v = struct.unpack(">I", img[off:off + 4])[0]
            if TEXT_VA <= v < text_end and v % 4 == 0:
                run.append((LOAD + off, v))
                continue
            if len(run) >= args.min_run:
                for where, target in run:
                    if is_thunk(img, target):
                        thunks += 1
                    elif is_function_start(img, target):
                        starts += 1
                    else:
                        start = containing_start(img, target)
                        if start is not None:
                            interiors[target] = (start, where)
            run = []

    print(f"tablas encontradas con rachas de >= {args.min_run}: {starts + thunks + len(interiors)} punteros")
    print(f"  inicios de funcion : {starts}")
    print(f"  thunks de vtable   : {thunks}")
    print(f"  ENTRADAS INTERIORES: {len(interiors)}")
    print()
    if interiors:
        print(f"{'entrada':>12}  {'funcion':>12}  {'desfase':>8}   tabla")
        for target in sorted(interiors):
            start, where = interiors[target]
            print(f"  0x{target:08X}    0x{start:08X}    +0x{target - start:<6X}  @0x{where:08X}")

    print()
    print("NOTA: las direcciones que el juego calcula en runtime (familia 0x825A7xxx)")
    print("no salen aqui, porque no existen como datos en la imagen. Para esas esta el")
    print("detector en runtime de ci/rexglue-alias-interior.patch (NS3FB-ALIAS-AUTO),")
    print("que no necesita cosecha previa.")

    if args.cpp:
        print()
        print("static constexpr uint32_t kNs3fbInteriorAlias[][2] = {")
        for target in sorted(interiors):
            print(f"    {{0x{target:08X}, 0x{interiors[target][0]:08X}}},")
        print("};")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
