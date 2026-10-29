#!/usr/bin/env python3
"""Escribe setjmp_address / longjmp_address en [entrypoint] del manifiesto.

Por que hace falta
------------------
Si el manifiesto no declara estas dos direcciones, el codegen compila
`longjmp` como una llamada normal que retorna. Pero el epilogo de la funcion
ya lo omitio el compilador, asi que r1 y los registros callee-saved quedan
corruptos. El sintoma tipico es que el invitado termina *llamando a trozos de
epilogo* en vez de saltar: direcciones como 0x825A72D8 (`ld r30 / ld r31 /
blr`) o 0x825A7378 (un `blr` suelto), que en el log aparecen como NS3FB-TRAP.

Todo lo que va por fibras/coroutines deja de funcionar: combos de mob battle,
transiciones de capitulo, secuencias con prompt en pantalla. El juego libre
(mover, pelear, menus) no usa fibras y por eso sigue yendo bien.

De donde salen los valores
--------------------------
Del default.xex NTSC-U (SHA-1 f7ad65e2...), buscando la pareja del CRT por su
firma inconfundible: guardan y restauran los no volatiles en el MISMO reparto
de offsets.

    _setjmp  0x828A7F20   stfd f14..f31 en 0x00-0x88, std r13..r31 en 0x98-0x128
    longjmp  0x828A81F0   lfd  f14..f31 en 0x00-0x88, ld  r13..r31 en 0x98-0x128

Los dos empiezan con un gancho global (lis/lwz de 0x82B6718C) que es el
mecanismo de setjmp del CRT de 360.

Es idempotente: se puede ejecutar en cada build.
"""

import re
import sys
from pathlib import Path

SETJMP = 0x828A7F20
LONGJMP = 0x828A81F0

SECTION = "[entrypoint]"
SUBTABLE = "[entrypoint.functions]"
KEY_RE = re.compile(r"^\s*(setjmp_address|longjmp_address)\s*=")


def main() -> int:
    manifest = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("ns3fb_manifest.toml")
    if not manifest.exists():
        print(f"ERROR: no existe {manifest}; ejecuta 'rexglue init' primero.", file=sys.stderr)
        return 1

    lines = manifest.read_text(encoding="utf-8").splitlines()

    # Localizar [entrypoint]; si no esta, crearla justo antes de la subtabla.
    try:
        header = next(i for i, l in enumerate(lines) if l.strip() == SECTION)
    except StopIteration:
        try:
            sub = next(i for i, l in enumerate(lines) if l.strip() == SUBTABLE)
        except StopIteration:
            lines.extend(["", SECTION])
            header = len(lines) - 1
        else:
            lines[sub:sub] = [SECTION, ""]
            header = sub

    # Borrar claves previas que esten DENTRO de [entrypoint] (antes de la
    # siguiente cabecera), para poder reescribirlas sin duplicar.
    end = len(lines)
    for i in range(header + 1, len(lines)):
        if lines[i].lstrip().startswith("["):
            end = i
            break
    kept = [l for l in lines[header + 1 : end] if not KEY_RE.match(l)]

    block = [
        f"setjmp_address = 0x{SETJMP:08X}",
        f"longjmp_address = 0x{LONGJMP:08X}",
        "",
    ]
    new_lines = lines[: header + 1] + block + kept + lines[end:]

    # Limpiar lineas en blanco duplicadas que pueda dejar el reemplazo.
    out = []
    for l in new_lines:
        if l == "" and out and out[-1] == "":
            continue
        out.append(l)

    manifest.write_text("\n".join(out) + "\n", encoding="utf-8")

    # Verificar de verdad: releer y comprobar que quedaron en [entrypoint].
    check = manifest.read_text(encoding="utf-8").splitlines()
    h = next((i for i, l in enumerate(check) if l.strip() == SECTION), -1)
    got_s = got_l = None
    for l in check[h + 1 :]:
        if l.lstrip().startswith("["):
            break
        m = re.match(r"^\s*setjmp_address\s*=\s*(0x[0-9A-Fa-f]+)", l)
        if m:
            got_s = int(m.group(1), 16)
        m = re.match(r"^\s*longjmp_address\s*=\s*(0x[0-9A-Fa-f]+)", l)
        if m:
            got_l = int(m.group(1), 16)

    if got_s != SETJMP or got_l != LONGJMP:
        print(
            f"ERROR: no se pudieron fijar en [entrypoint] (setjmp={got_s}, longjmp={got_l})",
            file=sys.stderr,
        )
        return 1

    print(f"  setjmp_address  = 0x{SETJMP:08X}")
    print(f"  longjmp_address = 0x{LONGJMP:08X}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
