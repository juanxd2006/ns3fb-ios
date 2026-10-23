#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Banco de medicion A/B del port NS3FB.
#
# Genera una matriz de configuraciones, empaqueta cada una para meterla en el
# iPhone con la app Archivos, y convierte los logs que devuelvas en una tabla
# comparativa. La idea es que cada palanca de rendimiento quede MEDIDA, no
# estimada, con el mismo escenario en todos los casos.
#
#   ./scripts/perf-matrix.sh init      # crea perf/matrix/<caso>/
#   ./scripts/perf-matrix.sh list      # que prueba cada caso
#   ./scripts/perf-matrix.sh pack      # .zip por caso, listo para AirDrop
#   ./scripts/perf-matrix.sh parse LOG # parsea un log suelto
#   ./scripts/perf-matrix.sh report    # perf/results/ -> summary.md + .csv
#
# No toca el build ni el repo: solo escribe bajo perf/, que esta en .gitignore.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MATRIX_DIR="${MATRIX_DIR:-$ROOT/perf/matrix}"
RESULTS_DIR="${RESULTS_DIR:-$ROOT/perf/results}"
PARSER="$ROOT/scripts/perf_parse.py"

# id | msaa_override | ancho | alto | render_target_path | keep_pass_open
#
# El orden importa: 00 es la referencia contra la que se comparan las demas, y
# cada bloque aisla una sola variable respecto de ella. Los casos de 540p
# existen porque el coste de fragment y de resolve escala con los pixeles.
CASOS=(
  "00-baseline|0|1280|720|fbo|0"
  "01-msaa2|2|1280|720|fbo|0"
  "02-msaa1|1|1280|720|fbo|0"
  "03-540p|0|960|540|fbo|0"
  "04-msaa2-540p|2|960|540|fbo|0"
  "05-msaa1-540p|1|960|540|fbo|0"
  "06-kpo|0|1280|720|fbo|1"
  "07-kpo-msaa2|2|1280|720|fbo|1"
  "08-fsi|0|1280|720|fsi|0"
)

campo() { printf '%s' "$1" | cut -d'|' -f"$2"; }

todos_los_ids() { for c in "${CASOS[@]}"; do campo "$c" 1; done; }

escribir_toml() {
  local id="$1" msaa="$2" w="$3" h="$4" rt="$5" destino="$6"
  cat > "$destino" <<EOF
# Caso $id — generado por scripts/perf-matrix.sh. No editar a mano:
# vuelve a ejecutar el script para regenerarlo.
#
# Solo se declaran las claves que definen el caso. El resto de ajustes los pone
# la app como valores por defecto en el codigo, asi que todos los casos parten
# de la misma base y solo cambia lo que se esta midiendo.

gpu_plugin = "xenos"

# 0 = lo que pida el juego (4x), 1 / 2 / 4 = forzado.
# Parche: ci/rexglue-msaa-override.patch
msaa_override = $msaa

# Modo de video del invitado: bajar el numero de pixeles abarata fragment,
# resolve y blit a la vez. El presenter escala a la pantalla.
video_mode_width = $w
video_mode_height = $h

# "fbo" = render targets del host (MSAA por hardware).
# "fsi" = EDRAM emulada en el pixel shader: cambia el reparto entre
#         Compute y Fragment, que es justo lo que mide este banco.
render_target_path_vulkan = "$rt"
EOF
}

escribir_case_md() {
  local id="$1" msaa="$2" w="$3" h="$4" rt="$5" kpo="$6" destino="$7"
  local msaa_txt="$msaa"
  [ "$msaa" = "0" ] && msaa_txt="0 (valor del invitado, normalmente 4x)"
  local kpo_txt="no"
  [ "$kpo" = "1" ] && kpo_txt="si (keep_pass_open.txt)"

  local prueba
  case "$id" in
    00-baseline)   prueba="Referencia. Todo lo demas se compara contra este caso." ;;
    01-msaa2)      prueba="Bajar el MSAA del host de 4x a 2x. Deberia recortar el compute de resolve a la mitad y el ancho de banda de color/depth, conservando cobertura (a diferencia de 1x). Mejor relacion ganancia/riesgo de la matriz." ;;
    02-msaa1)      prueba="MSAA 1x: elimina el resolve de 4 muestras y el 75% del ancho de banda de las superficies. Pierdes el antialiasing y puede cambiar cualquier efecto que dependa de cobertura por muestra. Vigila artefactos en pelos, humo y transparencias." ;;
    03-540p)       prueba="Bajar la resolucion interna de 1280x720 a 960x540 con MSAA intacto. 44% menos pixeles: afecta a fragment, resolve y blit por igual." ;;
    04-msaa2-540p) prueba="Combinacion de las dos palancas anteriores (2x + 540p)." ;;
    05-msaa1-540p) prueba="La combinacion mas agresiva que mantiene el render target path normal." ;;
    06-kpo)        prueba="Mantener el render pass abierto (parche keep-pass-open-v2) sin tocar nada mas. En GPU TBDR cada cierre vuelca los tiles a memoria." ;;
    07-kpo-msaa2)  prueba="keep pass open + MSAA 2x: las dos palancas que atacan el camino de render targets." ;;
    08-fsi)        prueba="Ruta fsi: la EDRAM se emula en el pixel shader en vez de resolverse con compute. Mueve coste de Compute a Fragment; sirve para ver si el reparto es mas favorable en Metal." ;;
    *)             prueba="Sin descripcion." ;;
  esac

  cat > "$destino" <<EOF
# Caso $id

| Variable | Valor |
|---|---|
| \`msaa_override\` | $msaa_txt |
| Modo de video | ${w}x${h} |
| \`render_target_path_vulkan\` | \`$rt\` |
| keep pass open | $kpo_txt |

## Que prueba

$prueba

## Que mirar en el log

- La linea \`NS3FB: msaa_override=N\` confirma que el caso se aplico de verdad.
  Si no aparece o el valor no coincide, el caso **no es valido**: normalmente
  queda un marcador \`msaaN.txt\` olvidado en Documents, que pisa el TOML.
- \`NS3FB-PASS ... kept_open=\` debe subir en los casos 06 y 07.
- Los cuatro buckets: Vertex / Fragment / Compute / Blit.
EOF
}

escribir_leeme() {
  cat > "$MATRIX_DIR/README.md" <<'EOF'
# Matriz de rendimiento

Cada carpeta es un caso. Para medirlo, copia **su contenido** en `Documents/`
del iPhone (app Archivos), sustituyendo lo que hubiera:

```
Documents/
├── ns3fb.toml          <- el del caso
├── mvk_perf_log.txt    <- siempre
└── keep_pass_open.txt  <- solo en los casos kpo
```

## Protocolo (importante: igual en todos los casos)

1. **Borra marcadores sueltos** `msaa1.txt`, `msaa2.txt`, `msaa4.txt`,
   `async_on.txt`, `rtt_fsi.txt`, `no_async_present.txt` de `Documents/`.
   Un marcador pisa el TOML y el caso deja de ser el que crees medir.
2. Cierra la app, pon el movil en modo avion, brillo fijo y **quita la funda**.
3. Arranca y deja **30 s de calentamiento**. No midas los primeros segundos:
   ahi se compilan pipelines.
4. Graba **60 s** del mismo escenario en todos los casos (por ejemplo: menu
   principal, luego seleccion de personaje, luego una lucha de practica).
5. Copia `userdata/logs/*.log` a `perf/results/<caso>/` en el Mac.
6. Repite un caso al final. Si el mismo caso da peor que al principio, el movil
   se esta calentando y las comparaciones no valen.

## Verificar que el caso se aplico

En el log tiene que salir:

```
NS3FB: msaa_override=N (el valor del invitado se ignora)
```

Si el valor no coincide con el caso, o no aparece, la fila se descarta. El
parser lo marca solo con `--expect-msaa`.
EOF
}

cmd_init() {
  mkdir -p "$MATRIX_DIR"
  local c
  for c in "${CASOS[@]}"; do
    local id msaa w h rt kpo dir
    id="$(campo "$c" 1)"; msaa="$(campo "$c" 2)"; w="$(campo "$c" 3)"
    h="$(campo "$c" 4)";  rt="$(campo "$c" 5)";   kpo="$(campo "$c" 6)"
    dir="$MATRIX_DIR/$id"
    mkdir -p "$dir"
    escribir_toml "$id" "$msaa" "$w" "$h" "$rt" "$dir/ns3fb.toml"
    : > "$dir/mvk_perf_log.txt"
    if [ "$kpo" = "1" ]; then : > "$dir/keep_pass_open.txt"; fi
    escribir_case_md "$id" "$msaa" "$w" "$h" "$rt" "$kpo" "$dir/CASE.md"
    printf '  %-16s msaa=%s  %sx%s  %s  kpo=%s\n' "$id" "$msaa" "$w" "$h" "$rt" "$kpo"
  done
  escribir_leeme
  cat <<EOF

Listo: $(todos_los_ids | wc -l | tr -d ' ') casos en $MATRIX_DIR

Siguiente paso:
  1. ./scripts/perf-matrix.sh pack
  2. Copia cada .zip a Documents/ en el iPhone (app Archivos)
  3. Arranca, espera 30 s y graba 60 s del MISMO escenario
  4. Copia los logs a perf/results/<caso>/ y ejecuta: ./scripts/perf-matrix.sh report
EOF
}

cmd_list() {
  printf '%-16s %-6s %-10s %-6s %s\n' CASO MSAA RESOLUCION RT KPO
  local c
  for c in "${CASOS[@]}"; do
    printf '%-16s %-6s %-10s %-6s %s\n' "$(campo "$c" 1)" "$(campo "$c" 2)" \
      "$(campo "$c" 3)x$(campo "$c" 4)" "$(campo "$c" 5)" "$(campo "$c" 6)"
  done
}

cmd_pack() {
  local salida="$ROOT/perf/pack"
  mkdir -p "$salida"
  [ -d "$MATRIX_DIR" ] || { echo "primero: ./scripts/perf-matrix.sh init" >&2; exit 1; }
  local c
  for c in "${CASOS[@]}"; do
    local id dir
    id="$(campo "$c" 1)"; dir="$MATRIX_DIR/$id"
    [ -d "$dir" ] || continue
    ( cd "$dir" && zip -qry "$salida/$id.zip" . )
    echo "  $salida/$id.zip"
  done
  echo "Cada .zip se descomprime directamente en Documents/."
}

cmd_parse() {
  [ $# -gt 0 ] || { echo "uso: perf-matrix.sh parse LOG|CARPETA..." >&2; exit 2; }
  python3 "$PARSER" "$@"
}

cmd_report() {
  [ -d "$RESULTS_DIR" ] || {
    echo "no existe $RESULTS_DIR" >&2
    echo "crea perf/results/<caso>/ con los logs de cada caso" >&2
    exit 1
  }
  local csv="$ROOT/perf/summary.csv" md="$ROOT/perf/summary.md"
  : > "$csv"
  printf '# Resumen de la matriz\n\nGenerado por scripts/perf-matrix.sh report\n\n' > "$md"

  local c
  for c in "${CASOS[@]}"; do
    local id msaa dir
    id="$(campo "$c" 1)"; msaa="$(campo "$c" 2)"
    dir="$RESULTS_DIR/$id"
    [ -d "$dir" ] || { echo "  (sin datos) $id" >&2; continue; }
    if [ ! -s "$csv" ]; then
      python3 "$PARSER" --csv --case "$id" --expect-msaa "$msaa" "$dir" >> "$csv"
    else
      python3 "$PARSER" --csv --case "$id" --expect-msaa "$msaa" "$dir" | tail -n +2 >> "$csv"
    fi
    {
      echo "## $id"
      echo
      python3 "$PARSER" --case "$id" --expect-msaa "$msaa" "$dir"
      echo
    } >> "$md"
    echo "  ok $id"
  done
  echo
  echo "Escrito: $csv"
  echo "Escrito: $md"
}

cmd_help() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    init)    cmd_init "$@" ;;
    list)    cmd_list "$@" ;;
    pack)    cmd_pack "$@" ;;
    parse)   cmd_parse "$@" ;;
    report)  cmd_report "$@" ;;
    help|-h|--help) cmd_help ;;
    *) echo "comando desconocido: $cmd (init|list|pack|parse|report)" >&2; exit 2 ;;
  esac
}

main "$@"
