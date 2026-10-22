#!/usr/bin/env python3
"""Sembrar entrypoints en ns3fb_manifest.toml antes del codegen.

ReXGlue descubre funciones por .pdata y por escaneo de código, pero los títulos
reales siempre tienen ramas directas a direcciones que ninguno de los dos ve. El
codegen aborta con:

    UnresolvedCall  b 0x82861BE0 from 0x826EB9B4 - target not in any function

La solución es declararlas en [entrypoint.functions]. Este script lee
ci/entrypoint_seeds.txt y añade las que falten, sin tocar las que ya estén.

Es idempotente: se puede ejecutar en cada build.
"""

import os
import re
import sys
from pathlib import Path

SECTION = "[entrypoint.functions]"
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent

# El manifest lo genera `rexglue init` en el directorio del proyecto (app/), que
# es el CWD cuando este script se ejecuta desde 01-codegen.sh.
MANIFEST = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("ns3fb_manifest.toml")

ENTRY_RE = re.compile(r"^\s*(0x[0-9A-Fa-f]{1,8})\s*=")


def find_seeds() -> Path | None:
    """Localiza entrypoint_seeds.txt sin depender del directorio actual."""
    candidates = [
        Path(os.environ["NS3FB_SEEDS"]) if os.environ.get("NS3FB_SEEDS") else None,
        REPO_ROOT / "ci" / "entrypoint_seeds.txt",
        Path("../ci/entrypoint_seeds.txt"),
        Path("ci/entrypoint_seeds.txt"),
        SCRIPT_DIR / "entrypoint_seeds.txt",
    ]
    for c in candidates:
        if c and c.exists():
            return c
    return None


def read_seeds(path: Path) -> list[str]:
    seeds = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if not re.fullmatch(r"0x[0-9A-Fa-f]{1,8}", line):
            print(f"  aviso: direccion ignorada en {path}: {line!r}", file=sys.stderr)
            continue
        seeds.append(line.upper().replace("0X", "0x"))
    return seeds


def main() -> int:
    if not MANIFEST.exists():
        print(f"ERROR: no existe {MANIFEST}; ejecuta 'rexglue init' primero.", file=sys.stderr)
        return 1

    seeds_path = find_seeds()
    if seeds_path is None:
        print("  aviso: no se encontro ci/entrypoint_seeds.txt; se omite el sembrado",
              file=sys.stderr)
        return 0
    seeds = read_seeds(seeds_path)
    if not seeds:
        print("  sin seeds que aplicar")
        return 0

    text = MANIFEST.read_text(encoding="utf-8")
    lines = text.splitlines()

    # Direcciones ya declaradas en todo el archivo (cualquier tabla).
    existing = {m.group(1).upper().replace("0X", "0x") for m in map(ENTRY_RE.match, lines) if m}

    missing = [s for s in seeds if s not in existing]
    if not missing:
        print(f"  {len(seeds)} entrypoints ya sembrados")
        return 0

    # Insertar justo debajo de la cabecera de la tabla, para que las claves
    # queden dentro de [entrypoint.functions] y no al final del archivo (donde
    # pertenecerían a la última sección, sea cual sea).
    try:
        header = next(i for i, l in enumerate(lines) if l.strip() == SECTION)
    except StopIteration:
        lines.extend(["", SECTION])
        header = len(lines) - 1

    block = [f'{addr} = {{ name = "sub_{addr[2:]}" }}' for addr in missing]
    lines[header + 1 : header + 1] = block

    MANIFEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"  +{len(block)} entrypoints sembrados ({len(seeds)} en total)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
