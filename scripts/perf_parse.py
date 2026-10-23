#!/usr/bin/env python3
"""Extrae las metricas de rendimiento de los logs del port NS3FB.

Lee uno o varios logs (el del runtime, la salida de MoltenVK con
`mvk_perf_log.txt`, o un pegado a mano del HUD de Metal) y devuelve una fila
por fichero con los cuatro buckets y los contadores de render pass.

Uso:
    python3 scripts/perf_parse.py LOG [LOG...]
    python3 scripts/perf_parse.py --case 01-msaa2 --expect-msaa 2 LOG
    python3 scripts/perf_parse.py --csv  LOG
    python3 scripts/perf_parse.py --json LOG
    python3 scripts/perf_parse.py --selftest

No falla si un campo no aparece: lo deja vacio. El objetivo es no inventar
numeros nunca; si un log no trae el desglose por bucket, la columna sale "-"
y hay que rellenarla desde el HUD de Metal a mano.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# --- Patrones -------------------------------------------------------------
#
# Cada entrada es (campo, regex). Se aplican en orden sobre todo el texto y se
# queda la ULTIMA coincidencia: los logs repiten los contadores muchas veces y
# lo que interesa es el estado final del tramo medido.
#
# Los tres formatos que se aceptan a proposito:
#   1. El log de MoltenVK (`Frame interval  avg: 63.070 ms, latest: ...`).
#   2. Un pegado del HUD de Metal (`Vertex 3.14 ms`, `GPU: 63.07 ms`).
#   3. Las lineas propias del parche de contadores (`NS3FB-PASS ends=... `).
PATRONES = [
    # Que MSAA aplico de verdad el parche. Sirve para detectar que el caso no
    # es el que se creia medir (un marcador olvidado en Documents, por ejemplo).
    ("msaa_applied", r"NS3FB:\s*msaa_override=(\d+)"),
    # Frame y FPS
    ("frame_ms", r"Frame interval\s+avg:\s*([\d.]+)\s*ms"),
    ("frame_ms", r"milliseconds per frame[:\s]+([\d.]+)"),
    ("fps", r"FPS\s*[:=]\s*([\d.]+)"),
    ("fps", r"([\d.]+)\s*(?:FPS|fps|frames per second)"),
    # Tiempos del lado GPU que publica MoltenVK
    ("gpu_exec_ms", r"Execute a MTLCommandBuffer on GPU\s+avg:\s*([\d.]+)\s*ms"),
    ("encode_ms", r"Encode VkCommandBuffer to MTLCommandBuffer\s+avg:\s*([\d.]+)\s*ms"),
    ("submit_ms", r"vkQueueSubmit\(\) encoding to MTLCommandBuffers\s+avg:\s*([\d.]+)\s*ms"),
    ("present_ms", r"Present swapchains in on GPU\s+avg:\s*([\d.]+)\s*ms"),
    ("drawable_ms", r"Retrieve a CAMetalDrawable\s+avg:\s*([\d.]+)\s*ms"),
    ("pipeline_compile_ms", r"Compile MTLFunctions into a pipeline\s+avg:\s*([\d.]+)\s*ms"),
    ("spirv_to_msl_ms", r"Convert SPIR-V to MSL source code\s+avg:\s*([\d.]+)\s*ms"),
    # GPU total, cuando viene del HUD
    # Solo al principio de linea: si no, "Execute a MTLCommandBuffer on GPU"
    # se colaria como si fuera el GPU total del frame.
    ("gpu_ms", r"(?m)^[ \t]*GPU[^0-9\n]{0,20}([\d.]+)\s*ms"),
    # Los cuatro buckets. Admite "Vertex 3.14 ms", "Vertex Time: 3.14", etc.
    ("vertex_ms", r"\bVertex\b[^0-9\n]{0,24}([\d.]+)\s*ms"),
    ("fragment_ms", r"\bFragment\b[^0-9\n]{0,24}([\d.]+)\s*ms"),
    ("compute_ms", r"\bCompute\b[^0-9\n]{0,24}([\d.]+)\s*ms"),
    ("blit_ms", r"\bBlit\b[^0-9\n]{0,24}([\d.]+)\s*ms"),
]

# Contadores del parche rexglue-pass-stats.patch / keep-pass-open-v2.
RE_PASS = re.compile(
    r"NS3FB-PASS\s+ends=(\d+)\s+begins=(\d+)\s+barrier_ends=(\d+)\s+"
    r"kept_open=(\d+)\s+barriers_in_pass=(\d+)\s+split_by_attachment=(\d+)"
)

CAMPOS = [
    "case", "file", "msaa_applied", "fps", "frame_ms", "gpu_ms",
    "vertex_ms", "fragment_ms", "compute_ms", "blit_ms",
    "encode_ms", "gpu_exec_ms", "pipeline_compile_ms",
    "pass_ends", "pass_ends_delta", "kept_open", "kept_open_delta",
    "barrier_ends_delta", "split_by_attachment", "barrier_ratio", "note",
]


def _num(valor: str) -> float:
    try:
        return float(valor)
    except ValueError:
        return float("nan")


def parsear(texto: str) -> dict:
    """Devuelve un dict con lo que se haya podido extraer. Nunca lanza."""
    fila: dict = {}

    for campo, patron in PATRONES:
        ultimo = None
        for m in re.finditer(patron, texto):
            ultimo = m.group(1)
        if ultimo is not None:
            fila[campo] = _num(ultimo)

    # Contadores de render pass: primera y ultima aparicion, para poder ver el
    # delta del tramo medido y no solo el acumulado desde el arranque.
    apariciones = RE_PASS.findall(texto)
    if apariciones:
        primera = [int(v) for v in apariciones[0]]
        ultima = [int(v) for v in apariciones[-1]]
        ends0, _begins0, barrier0, kept0, _bip0, _split0 = primera
        ends1, _begins1, barrier1, kept1, _bip1, split1 = ultima
        fila["pass_ends"] = ends1
        fila["pass_ends_delta"] = ends1 - ends0
        fila["kept_open"] = kept1
        fila["kept_open_delta"] = kept1 - kept0
        fila["barrier_ends_delta"] = barrier1 - barrier0
        fila["split_by_attachment"] = split1
        if ends1:
            fila["barrier_ratio"] = round(barrier1 / ends1, 3)

    # Si hay frame_ms y no fps (o al reves), se deriva el que falte.
    if "frame_ms" in fila and "fps" not in fila and fila["frame_ms"] > 0:
        fila["fps"] = round(1000.0 / fila["frame_ms"], 2)
    if "fps" in fila and "frame_ms" not in fila and fila["fps"] > 0:
        fila["frame_ms"] = round(1000.0 / fila["fps"], 2)

    return fila


def _fmt(valor) -> str:
    if valor is None or valor == "":
        return "-"
    if isinstance(valor, float):
        if valor != valor:  # NaN
            return "-"
        return f"{valor:.2f}"
    return str(valor)


def _csv(valor) -> str:
    """CSV sin comillas salvo que haga falta. Vacio = campo ausente."""
    if valor is None or valor == "":
        return ""
    if isinstance(valor, float):
        if valor != valor:  # NaN
            return ""
        texto = f"{valor:.3f}".rstrip("0").rstrip(".")
    else:
        texto = str(valor)
    if any(c in texto for c in ',"\n'):
        return '"' + texto.replace('"', '""') + '"'
    return texto


def tabla(filas: list[dict]) -> str:
    cols = ["case", "msaa_applied", "fps", "frame_ms", "vertex_ms",
            "fragment_ms", "compute_ms", "blit_ms", "gpu_exec_ms",
            "pass_ends_delta", "kept_open_delta", "barrier_ratio", "note"]
    cabecera = ["caso", "msaa", "fps", "frame", "vertex", "fragment",
                "compute", "blit", "gpu", "pass-delta", "kept", "barr/end", "nota"]
    lineas = ["| " + " | ".join(cabecera) + " |",
              "|" + "|".join(["---"] * len(cabecera)) + "|"]
    for f in filas:
        lineas.append("| " + " | ".join(_fmt(f.get(c)) for c in cols) + " |")
    return "\n".join(lineas)


def fila_de_fichero(ruta: Path, caso: str | None, esperado: int | None) -> dict:
    texto = ruta.read_text(errors="replace")
    fila = parsear(texto)
    fila["file"] = str(ruta)
    fila["case"] = caso or ruta.parent.name or ruta.name

    notas = []
    if esperado is not None:
        aplicado = fila.get("msaa_applied")
        if aplicado is None:
            if esperado != 0:
                notas.append("sin linea NS3FB: msaa_override (¿parche sin aplicar?)")
        elif int(aplicado) != esperado:
            notas.append(f"msaa aplicado {int(aplicado)} != esperado {esperado}")
    if "frame_ms" not in fila:
        notas.append("sin frame interval")
    if not any(k in fila for k in ("vertex_ms", "fragment_ms", "compute_ms")):
        notas.append("sin buckets: rellenar desde el HUD de Metal")
    if notas:
        fila["note"] = "; ".join(notas)
    return fila


# --- Autotest -------------------------------------------------------------
FIXTURE_MVK = """
[ MVK-Perf ] Frame interval                     avg: 63.070 ms, latest: 62.100 ms, prev: 63.000 ms, min: 58.000 ms, max: 90.000 ms, count: 900
[ MVK-Perf ] Encode VkCommandBuffer to MTLCommandBuffer  avg: 1.400 ms, latest: 1.300 ms, prev: 1.400 ms, min: 1.000 ms, max: 3.000 ms, count: 900
[ MVK-Perf ] Execute a MTLCommandBuffer on GPU  avg: 55.200 ms, latest: 54.000 ms, prev: 55.000 ms, min: 50.000 ms, max: 80.000 ms, count: 900
NS3FB: msaa_override=2 (el valor del invitado se ignora)
NS3FB-PASS ends=300 begins=310 barrier_ends=290 kept_open=0 barriers_in_pass=5 split_by_attachment=10
NS3FB-PASS ends=900 begins=940 barrier_ends=880 kept_open=120 barriers_in_pass=20 split_by_attachment=40
"""

FIXTURE_HUD = """
FPS: 24
GPU: 41.30 ms
Vertex 3.14 ms
Fragment 14.02 ms
Compute 21.10 ms
Blit 5.51 ms
"""


def selftest() -> int:
    fallos = 0

    fila = parsear(FIXTURE_MVK)
    esperado = {
        "msaa_applied": 2, "frame_ms": 63.07, "gpu_exec_ms": 55.2,
        "encode_ms": 1.4, "pass_ends": 900, "pass_ends_delta": 600,
        "kept_open": 120, "kept_open_delta": 120, "barrier_ends_delta": 590,
        "split_by_attachment": 40,
    }
    for k, v in esperado.items():
        if k not in fila or abs(float(fila[k]) - float(v)) > 1e-6:
            print(f"FALLO (mvk) {k}: {fila.get(k)!r} != {v!r}")
            fallos += 1
    if abs(fila.get("fps", 0) - 1000.0 / 63.07) > 0.05:
        print(f"FALLO (mvk) fps derivado: {fila.get('fps')!r}")
        fallos += 1
    if abs(fila.get("barrier_ratio", 0) - 880 / 900) > 1e-3:
        print(f"FALLO (mvk) barrier_ratio: {fila.get('barrier_ratio')!r}")
        fallos += 1

    hud = parsear(FIXTURE_HUD)
    for k, v in {"fps": 24, "gpu_ms": 41.3, "vertex_ms": 3.14,
                 "fragment_ms": 14.02, "compute_ms": 21.1, "blit_ms": 5.51}.items():
        if abs(float(hud.get(k, -1)) - v) > 1e-6:
            print(f"FALLO (hud) {k}: {hud.get(k)!r} != {v!r}")
            fallos += 1

    vacio = parsear("nada que ver aqui")
    if any(k in vacio for k in ("fps", "frame_ms", "msaa_applied")):
        print(f"FALLO (vacio): se inventaron campos {vacio}")
        fallos += 1

    print("selftest OK" if not fallos else f"selftest: {fallos} fallo(s)")
    return 0 if not fallos else 1


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Parsea logs de rendimiento de NS3FB.")
    ap.add_argument("logs", nargs="*", type=Path)
    ap.add_argument("--case", help="nombre del caso (por defecto, carpeta del log)")
    ap.add_argument("--expect-msaa", type=int, choices=[0, 1, 2, 4],
                    help="MSAA que deberia haberse aplicado; se avisa si no coincide")
    ap.add_argument("--json", action="store_true", help="salida JSON")
    ap.add_argument("--csv", action="store_true",
                    help="salida CSV (una fila por log, con cabecera)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_intermixed_args(argv)

    if args.selftest:
        return selftest()
    if not args.logs:
        ap.error("faltan logs (o usa --selftest)")

    rutas: list[Path] = []
    for ruta in args.logs:
        if ruta.is_dir():
            rutas.extend(sorted(p for p in ruta.rglob("*")
                                if p.is_file() and p.suffix.lower() in
                                {".log", ".txt", ".csv", ".md"}))
        elif ruta.is_file():
            rutas.append(ruta)
        else:
            print(f"aviso: no existe {ruta}", file=sys.stderr)
    if not rutas:
        print("no hay ficheros que parsear", file=sys.stderr)
        return 2

    filas = [fila_de_fichero(r, args.case, args.expect_msaa) for r in rutas]
    if args.csv:
        cols = [c for c in CAMPOS if c != "file"]
        print(",".join(cols))
        for f in filas:
            print(",".join(_csv(f.get(c)) for c in cols))
        return 0
    if args.json:
        print(json.dumps(filas, indent=2, ensure_ascii=False))
    else:
        print(tabla(filas))
        avisos = [f for f in filas if f.get("note")]
        if avisos:
            print()
            for f in avisos:
                print(f"  ! {f['file']}: {f['note']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
