#!/usr/bin/env bash
# Extrae automáticamente las semillas pendientes de un log de codegen de ReXGlue.
#
# Cada vez que el analizador no encuentra una función en .pdata, el codegen
# aborta con una línea como:
#
#   UnresolvedCall  b 0x82861BE0 from 0x826EB9B4 - target not in any function
#
# La dirección a sembrar es el DESTINO (0x82861BE0). Este script las recoge
# todas, quita las que ya están en ci/entrypoint_seeds.txt y las imprime listas
# para pegar. Con --write las añade al fichero (sin duplicar, en orden).
#
# Uso:
#   scripts/seeds-pending.sh                       # solo imprime
#   scripts/seeds-pending.sh --write                # añade al seeds.txt
#   scripts/seeds-pending.sh <log> [--write]        # con otro log
#   scripts/seeds-pending.sh --self                 # se auto-corrige: extrae,
#                                                   # escribe y reintenta codegen
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SEEDS="$ROOT/ci/entrypoint_seeds.txt"

LOG=""
WRITE=0
for arg in "$@"; do
  case "$arg" in
    --write) WRITE=1 ;;
    --self)
      # Modo automatico: saca las pendientes, las escribe y vuelve a compilar.
      WRITE=1
      SELF=1
      ;;
    -*) echo "opcion desconocida: $arg" >&2; exit 2 ;;
    *) LOG="$arg" ;;
  esac
done

if [ -z "$LOG" ]; then
  # Busca el log mas reciente de los sitios donde lo dejan los scripts.
  for candidate in \
    "$ROOT/app/generated/codegen.log" \
    "$ROOT/app/out/build/ios-arm64-release/codegen.log" \
    "$ROOT/ci/codegen.log"
  do
    [ -f "$candidate" ] && LOG="$candidate" && break
  done
fi

if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
  echo "No encuentro el log de codegen. Pasa la ruta: scripts/seeds-pending.sh <log>" >&2
  exit 1
fi

echo "Log: $LOG"

# Destinos que el codegen no pudo resolver.
PENDING="$(
  grep -oE 'UnresolvedCall[[:space:]]+b[[:space:]]+0x[0-9A-Fa-f]{6,8}[^\n]*target not in any function' "$LOG" \
    | awk '{print $3}' \
    | tr 'a-f' 'A-F' \
    | sed -E 's/^0x0*/0x/' \
    | sort -u || true
)"

if [ -z "$PENDING" ]; then
  echo "No hay semillas pendientes: el codegen resolvio todas las ramas."
  exit 0
fi

# Quita las que ya estan sembradas.
ALREADY="$SEEDS"
if [ -f "$SEEDS" ]; then
  ALREADY="$(grep -oE '0x[0-9A-Fa-f]{6,8}' "$SEEDS" | tr 'a-f' 'A-F' | sed -E 's/^0x0*/0x/' | sort -u)"
fi

MISSING="$(comm -23 <(printf '%s\n' "$PENDING") <(printf '%s\n' "$ALREADY") || true)"

COUNT_ALL="$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')"
COUNT_NEW="$(printf '%s\n' "$MISSING" | grep -c . || true)"

echo "Direcciones sin resolver en el log: $COUNT_ALL"
echo "De ellas, nuevas (no sembradas):    $COUNT_NEW"

if [ "$COUNT_NEW" -eq 0 ]; then
  echo "Nada que anadir: todas estaban ya en ci/entrypoint_seeds.txt."
  exit 0
fi

echo
echo "--- pega esto al final de ci/entrypoint_seeds.txt ---"
printf '%s\n' "$MISSING"
echo "--- fin ---"

if [ "$WRITE" -eq 1 ]; then
  # Se anaden al final, una por linea, manteniendo el comentario de cabecera.
  {
    echo "# Anadidas automaticamente por scripts/seeds-pending.sh $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$MISSING"
  } >> "$SEEDS"
  echo
  echo "Escritas $COUNT_NEW semillas en ci/entrypoint_seeds.txt"
fi

# Modo --self: reintenta el codegen con las semillas nuevas ya aplicadas.
if [ "${SELF:-0}" -eq 1 ] && [ "$WRITE" -eq 1 ]; then
  echo "Relanzando codegen con las semillas nuevas..."
  "$ROOT/scripts/01-codegen.sh"
fi
