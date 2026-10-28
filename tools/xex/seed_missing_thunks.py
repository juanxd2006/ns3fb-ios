#!/usr/bin/env python3
"""Sembrar de una vez TODOS los thunks de vtable del .text que falten.

`find_callback_thunks.py` recorre por defecto 0x825A7000-0x825A8000, que es
donde vive la familia de callbacks de evento que tantas veces ha hecho falta.
Pero el .text entero tiene mas, y cada uno sin sembrar es un NS3FB-TRAP
esperando a que alguien entre en la pantalla que lo usa.

Este script:
  1. descifra el xex con tools/xex/unxex.py (si hace falta),
  2. enumera el patron de thunk en TODO el .text,
  3. compara con ci/entrypoint_seeds.txt,
  4. y añade al final las direcciones que falten, con el slot virtual al lado.

Es idempotente: si no falta ninguna, no toca el archivo.

Uso:
    python3 tools/xex/seed_missing_thunks.py ci/game/default.xex
    python3 tools/xex/seed_missing_thunks.py ci/game/default.xex --dry-run
    python3 tools/xex/seed_missing_thunks.py /tmp/image.bin --image
"""
import argparse
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
SEEDS = REPO_ROOT / "ci" / "entrypoint_seeds.txt"

TEXT_VA, TEXT_RAW, TEXT_SZ = 0x821B0000, 0x1AFE00, 0x74DA00
SEED_RE = re.compile(r"0x[0-9A-Fa-f]{1,8}")


def load_image(path: Path, is_image: bool) -> bytes:
    if is_image:
        return path.read_bytes()
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        out = Path(tmp.name)
    subprocess.run([sys.executable, str(SCRIPT_DIR / "unxex.py"), str(path), str(out)],
                   check=True, stdout=subprocess.DEVNULL)
    return out.read_bytes()


def find_thunks(img: bytes) -> list[tuple[int, int]]:
    """Devuelve [(direccion, slot_virtual)] de cada thunk del .text."""
    text = img[TEXT_RAW:TEXT_RAW + TEXT_SZ]
    found = []
    for i in range(0, len(text) - 16, 4):
        w0, w1, w2, w3 = struct.unpack(">IIII", text[i:i + 16])
        if (w0 == 0x81830000 and (w1 & 0xFFFF0000) == 0x816C0000
                and w2 == 0x7D6903A6 and w3 == 0x4E800420):
            found.append((TEXT_VA + i, w1 & 0xFFFF))
    return found


def read_seeds(path: Path) -> set[int]:
    seeds = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if SEED_RE.fullmatch(line):
            seeds.add(int(line, 16))
    return seeds


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("binary", type=Path, help="default.xex o imagen ya descifrada")
    ap.add_argument("--image", action="store_true", help="el archivo ya es la imagen descifrada")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--seeds", type=Path, default=SEEDS)
    args = ap.parse_args()

    img = load_image(args.binary, args.image)
    thunks = find_thunks(img)
    seeds = read_seeds(args.seeds)
    missing = [(a, s) for a, s in thunks if a not in seeds]

    print(f"thunks en .text: {len(thunks)} | ya sembrados: {len(thunks) - len(missing)} | faltan: {len(missing)}")
    for addr, slot in missing:
        print(f"  0x{addr:08x}  slot 0x{slot:X}")

    if not missing:
        print("nada que hacer")
        return 0
    if args.dry_run:
        print("--dry-run: no se ha tocado el archivo")
        return 0

    block = [
        "",
        "# --- thunks de vtable añadidos por tools/xex/seed_missing_thunks.py ------",
        f"# Cosecha completa de .text: {len(thunks)} thunks, faltaban {len(missing)}.",
        "",
    ]
    block += [f"0x{addr:08x}  # slot 0x{slot:X}" for addr, slot in missing]
    text = args.seeds.read_text(encoding="utf-8").rstrip("\n")
    args.seeds.write_text(text + "\n" + "\n".join(block) + "\n", encoding="utf-8")
    print(f"añadidas {len(missing)} semillas a {args.seeds}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
