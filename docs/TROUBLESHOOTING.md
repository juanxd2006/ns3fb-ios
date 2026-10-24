# Solución de problemas

El juego no va a arrancar a la primera. Así se depura, en orden.

## Dónde mirar

| Fuente | Qué contiene |
|---|---|
| `NS3FB/userdata/logs/` en la app Archivos | El log del runtime en el dispositivo |
| Consola de Xcode (Devices → Open Console) | Log en vivo + crash reports |
| Salida del codegen | Funciones no resueltas, warnings de instrucciones |
| `~/Library/Logs/DiagnosticReports/` | Crash reports con backtrace simbólico |

El sistema de logs del SDK escribe **también** en `userdata/logs/`, así que si la
app arranca y muere ya tienes algo que leer. Si ni siquiera llega a escribir,
el fallo es de firma, entitlements o dyld (mira la consola).

## Fallos por fase

### 1. No instala / no abre nada
- Firma caducada (Apple ID gratis = 7 días). Re-firma con AltStore/SideStore.
- `NS3FB_IOS_SDK_LIB_DIR` mal: las tres dylibs (`librexruntime`, `librexgpu-xenos`,
  `libMoltenVK`) tienen que estar en `ns3fb.app/Frameworks/`. Si falta una, dyld
  mata el proceso antes de main.
- Bundle ID sin provisionar: usa uno que tu perfil cubra.

### 2. Abre y cierra inmediatamente
- `game/default.xex` no está directamente dentro de `game/` (no dentro de otra
  subcarpeta).
- Hash del xex distinto.
- `dyld: Library not loaded` → dylib sin firmar. Re-ejecuta `make-ipa.sh`.

### 3. "not enough free address space" al arrancar
Es el entitlement `com.apple.developer.kernel.extended-virtual-addressing`. Sin
él, el mapa de memoria del invitado (~4.5 GB contiguos) no cabe en un iPhone de
3 GB. Solo lo conceden TrollStore, jailbreak o cuenta de pago. En un iPhone de
6/8 GB puede funcionar sin él.

### 4. Tela negra o cuelgue en el primer frame
Casi siempre es el entrypoint del manifest:

- El codegen arranca el análisis en `mainCRTStartup`; si el juego entra por otro
  lado, se queda colgado o revienta. Busca el punto de entrada real en el xex.
- `setjmp_address` / `longjmp_address` mal puestos o ausentes: `longjmp` se
  recompila como una llamada normal que retorna, el epílogo ya lo omitió el
  compilador, y `r1` + registros callee-saved quedan corruptos. Síntoma típico:
  crash al cargar la primera textura PNG/JPEG o al inicializar el filesystem.

### 5. Crashes con "invalid or unregistered function"
El juego saltó a una dirección que el analizador no descubrió. Es lo normal en
las primeras ejecuciones:

1. Apunta la dirección del log.
2. Añádela a `[entrypoint.functions]` del `ns3fb_manifest.toml`:
   ```toml
   0x82ABCDEF = { name = "sub_82ABCDEF" }
   ```
3. Re-ejecuta `./scripts/01-codegen.sh` y prueba otra vez.

Atajo: `[entrypoint.functions]` también acepta los punteros a función que el
escáner de secciones de datos encuentra (`--scan-code-pointers-to`). En el
proyecto de Minecraft eso resolvió 35 800 vtables y callbacks de golpe; sin ello
aparecen como traps uno por ejecución.

### 6. Gráficos raros, texturas negras, bandas
- Prueba `render_target_path_vulkan = "fsi"` y `"fbo"` alternando: algunos
  efectos (EDRAM, MSAA) se comportan distinto en cada ruta.
- `fsi_sample_mask_from_sample_id = true` es obligatorio en MoltenVK si usas
  `fsi`; sin ello la cobertura del sample 0 no existe y cada dos píxeles se queda
  con el frame anterior.
- Shaders que XenosRecomp no cubre: mira los warnings del traductor y las
  pipelines que fallan al compilar en el log.

### 7. Va a tirones / se calienta

#### 7.1 Lo primero es saber quién trabaja: GPU o CPU

Crea en `Documents/` (app Archivos) el archivo vacío **`mvk_perf_log.txt`**. Al
arrancar, MoltenVK escribe en el log, por frame: `FPS`, `GPU`, `Frame interval`,
y el desglose `Vertex / Fragment / Compute / Blit GPU`, además de
`Command Buffer CPU`.

| Lo que veas | Veredicto | Qué tocar |
|---|---|---|
| GPU ≈ frame interval | Limitado por GPU | sección 7.2 |
| `Command Buffer CPU` ≈ frame interval | CPU esperando a la GPU | es lo mismo, consecuencia |
| GPU y CPU muy por debajo del frame | Nadie trabaja | sección 7.3 |

Medición real de referencia (iPhone 11 / A13): **pantalla negra, 30,18 ms de GPU**
con 13,3 ms de compute, 12,5 de fragment y 1,95 de blit. Si una pantalla en negro
cuesta 30 ms, el coste no está en dibujar: está en el camino de render targets.

#### 7.2 El render pass partido (la causa gorda en Storm 3)

En las GPU Apple (TBDR) el renderizado ocurre por tiles en memoria on-chip.
**Cerrar un render pass obliga a volcar esos tiles a memoria y recargarlos al
abrirlo de nuevo.** Xenia cierra el pass en cada barrera pendiente salvo que se
le diga lo contrario, y Storm 3 genera muchas.

El parche `ci/rexglue-keep-pass-open-v2.patch` lo evita. **Hay que activarlo en
el dispositivo**: crear el archivo vacío `Documents/keep_pass_open.txt`. Sin ese
archivo el comportamiento es el de siempre.

Cómo se comprueba: el log imprime cada 300 cierres de pass

```
NS3FB-PASS ends=… begins=… barrier_ends=… kept_open=… barriers_in_pass=… split_by_attachment=…
```

- `barrier_ends` alto frente a `ends` → la mayoría de los cierres son por barrera.
- `kept_open` **debe subir** con el marcador puesto. Si se queda en 0, el gate no
  está dejando pasar nada y el parche no está haciendo su trabajo.
- `split_by_attachment` cuenta los cierres inevitables: barreras que tocan un
  adjunto del pase (transición a/desde layout de attachment). Esos son legales e
  inevitables.

Referencia medida sin el parche (iPhone 11, menú): 722 pass cerrados/s y 2.582
barreras/s, es decir **~35–48 render passes cerrados por frame y ~110–170
barreras por frame**, con `kept_open = 0`.

Si al activarlo aparecen artefactos o basura gráfica, el gate es demasiado
permisivo: quita el marcador y avisa. No se pierde nada, vuelve al
comportamiento anterior sin recompilar.

#### 7.3 Los milisegundos que no aparecen en ningún contador

Si `GPU` y `Command Buffer CPU` suman bastante menos que `Frame interval`, el
invitado (el juego recompilado) está esperando. El sospechoso número uno es el
spin-wait de Direct3D: en la consola `db16cyc` pausaba el hilo de hardware, y
recompilado no hace nada, así que un núcleo gira al 100 %, calienta y el móvil
hace throttling. El parche está escrito y desactivado en `app/src/main.cpp`
(`#if 0`) porque necesita la dirección de la función, que se saca con
`rexglue analyze --scan-calls` sobre tu `default.xex`.

#### 7.4 Otros ajustes

- `framerate_limit = 30` (ya viene así); a 60 la lógica del juego corre al doble.
- `clear_memory_page_state = false` (ya viene así). Si lo activas, se re-sube
  todo a la GPU cada frame.
- `async_shader_compilation` está en `false` a propósito: con `true` los frames
  que usan un pipeline de relleno **no se presentan** y salen en negro. En el log
  se ve como `Skipping Vulkan frame presentation due to async placeholder draw
  usage in this frame`. Para el A/B sin recompilar: `Documents/async_on.txt`.
  La solución de verdad es precompilar las pipelines al cargar, no saltárselas.
- El enemigo real en iPhone: ancho de banda y draw calls. Storm 3 hace muchos más
  que Minecraft 360. Si con todo optimizado no llega a 30 fps estables, no hay
  cvar que lo arregle.

### 8. Audio entrecortado
Sube `audio_maxqframes` a 24–32. Baja si la latencia molesta.

### 9. El 3D sale negro con los menús y el HUD perfectos

Ese síntoma (mundo negro, UI y partículas bien, audio y lógica correctos, cero
errores en el log) tiene cuatro causas posibles y el log las separa sin captura
de GPU. Todo lo que sigue lo escriben los parches de diagnóstico
(`rexglue-draw-stats`, `rexglue-rt-stats`, `rexglue-guest-state`) y es **de solo
lectura**: no cambian el comportamiento del renderer.

**Primero, ¿se envía la geometría?**

```
NS3FB-DRAW next300 indexed=… verts=… prims: p4=… p6=…
```

Si en pelea aparecen `p4`/`p6` con cientos de miles de vértices, el mundo se
envía y el problema es de estado, formato o composite. Si solo hay `p8`/`p1`, el
juego no está emitiendo el mundo y el fallo es de lógica del invitado.

**Segundo, ¿a qué tipo de pase van esos vértices?**

Tabla acumulativa, volcada cada 1500 draws clasificados:

```
NS3FB-KEYS n=… slots=… dropped=… lost=… lost_cum=…
NS3FB-KEYSK slot=0 key=14 hex=0xE draws=… verts=… indexed=…
```

Cada `NS3FB-KEYSK` es un tipo de pase. Busca la línea con los **vértices del
mundo** (decenas de miles) y lee su `key`:

- `key=14` (0x0E, depth + 8:8:8:8, 4x) → el mundo usa un target normal con
  depth; el fallo está en el shader o en el composite posterior.
- `key=1802` / `1800` (0x70A / 0x708, HDR 16F) → el mundo va al target HDR sin
  depth, el que MoltenVK no sabe mezclar.
- `key=6` (0x06, solo depth) → el color del mundo no se escribe a ningún target
  visible.

`lost_cum` es la clave del diagnóstico: cuenta draws que el contador global vio
y que **nunca llegaron a la fase de render targets**, es decir que murieron en
`IssueDraw`. Si no es 0, el problema es anterior a cualquier formato y hay que
mirar los `draw_fail` (que sí imprimen `error`). `dropped` solo sube si hay más
de 16 tipos de pase en una sesión, cosa que hoy no pasa.

**Tercero, ¿el pase puede escribir color?**

**No hay «un estado del pase».** Un mismo pase se usa para varias cosas y su
estado cambia dentro del propio frame: en este juego la clave `0x1C` aparece con
tres estados distintos (contenido con blend y z test, overlay 2D con z test
apagado, y clear con `cmask=0` y scissor 16×16). Registrarlo una vez, o por
«revisiones» con tope, deja el resto de la sesión a ciegas.

Lo que se registra es el **conjunto de estados distintos** de cada clave, sin
tope por clave:

```
NS3FB-STATE   key=0x… sig=0x… t_ms=… at=… cmask=0x… bl=src/op/dst
              z=en/wr/func clip_dis=… dxclip=… cull_f=… cull_b=… face=…
              vp=xs,xo,ys,yo sci=tl_x,tl_y br_x,br_y
NS3FB-TGT     key=0x… sig=0x… c0_base=… c0_fmt=… c1_base=… c1_fmt=…
              d_base=… d_fmt=… pitch=… msaa=…

NS3FB-SIGSTAT key=0x… sig=0x… draws=… verts=… vmin=… vmax=…
```

`NS3FB-STATE` y `NS3FB-TGT` salen **una sola vez por cada estado distinto**. Si
la tabla se llena (128 estados), `NS3FB-SIGSTAT overflow=N` lo dice en vez de
perderlo en silencio.

**`NS3FB-SIGSTAT` es la línea que hay que mirar.** Cada 1500 draws cuenta, por
estado, cuántos draws y vértices lleva y el **mínimo y máximo de vértices por
draw**. Eso atribuye cada estado a su función sin adivinar:

- `vmax` de miles → es el **mundo**.
- `vmax` de 3–4 → es **HUD o post-proceso**.

Cruza el `sig=` que tenga `vmax` grande con su `NS3FB-STATE` y ese es el estado
real del mundo, en la pantalla que sea. `t_ms` (ms desde el arranque) y `at`
(número de draw global) dicen cuándo se vio por primera vez.

- `cmask` a 0 en el RT0 → el pase dibuja y no escribe nada.
- `z=0/0/…` o un `func` que rechaza todo → nada llega al color.
- `clip_dis=1` o un `vp`/`sci` de tamaño cero o desplazado → la geometría queda
  fuera de pantalla aunque los vértices se envíen.
- `cull_f`/`cull_b` con `face` invertido → se descarta la malla entera.

`vp` va en punto fijo ×16 (el `int` es el valor real multiplicado por 16).

**Cuarto, ¿ese pase llega a memoria del invitado?**

```
NS3FB-RES     n=… c_base=… c_fmt=… c64=… c_msaa=… d_base=… w8=… h8=…
              dst_base=0x… dst_start=0x… dst_len=0x… orig=… cc=0x…
NS3FB-RES-SUM n=… signatures=… discarded=…
```

Una línea **por firma distinta** (no por resolve: un juego resuelve decenas de
veces por frame). Cruza `c_base` con el `c0_base` del `NS3FB-TGT` del pase del
mundo:

- Si el rango EDRAM donde escribe el mundo **no aparece** en ningún `NS3FB-RES`,
  ese pase nunca se copia a memoria del invitado: se dibuja bien y no se ve
  nunca. El culpable es el camino de resolve, no el shader.
- `w8=0` o `h8=0` → el resolve se descarta por geometría inválida (lo cuenta
  `discarded` en el resumen).
- `dst_len=0` → no hay copia, solo clear.

**Y los clears, con su valor y su rango:**

```
NS3FB-CLEAR n=… depth=1 color=0 d_value=0x… c_value=0x…{:08X}
            d_base=… d_pitch=… d_fmt=… d_span=base+rowlen x rows
            c_base=… c_pitch=… c_fmt=… c_span=… w8=… h8=…
```

Una línea por cada clear distinto. `d_value` es **`RB_DEPTH_CLEAR`**, y
`d_span` / `c_span` el rango exacto de tiles EDRAM que se limpia
(`GetResolveEdramTileSpan`): base, longitud de fila y número de filas. Es el dato
que permite responder a «¿la profundidad contra la que testea el mundo está
limpia a 0 (cerca) o a 1 (lejos)?». Con `zfunc=lessEqual`, limpiarla a 0 hace
que no pase ni un fragmento y el target sale negro sin un solo error.

**Quinto: los dos experimentos que cierran la pregunta.**

Cuando el pase del mundo escribe color, tiene `cmask` distinto de 0 y su rango
EDRAM sí se resuelve, quedan dos causas y se separan con un marcador cada una.
Se copia uno **solo**, se entra a la pantalla del fallo y se mira:

| marcador en `Documents/` | qué fuerza | si con esto aparece la imagen |
|---|---|---|
| `ztest_off.txt` | `z_enable = 0` en todos los draws | era el **depth test**: el buffer de profundidad contra el que testea el pase tenía contenido inesperado |
| `blend_off.txt` | `src=One`, `dst=Zero`, `op=Add` (o sea `blendEnable = VK_FALSE`) | era el **blending**: el alpha del shader se mezclaba contra un destino negro |

Ambos se aplican al leer `RB_DEPTHCONTROL` y `RB_BLENDCONTROL`, que es de donde
derivan a la vez el estado del draw, la clave de las pipelines y el pipeline
creado: no puede quedar un estado incoherente entre capas.

**Uno a uno, nunca los dos a la vez.** Con los dos puestos no se sabe cuál
arregló la imagen. Y ninguno de los dos es una solución: si uno hace aparecer el
mundo, lo que toca es arreglar el origen, no dejarlo forzado.

Que el marcador se aplicó se comprueba en dos sitios del log:

```
NS3FB-CONFIG … zoff=1 blendoff=0
NS3FB: ztest_off=1 (z test forzado a OFF en todos los draws)
```

Si `zoff` no sale a 1, el marcador no se aplicó y la prueba no vale.

**Lo que NO dice el log.** No hay forma de saber desde el log si un píxel
concreto salió negro por el shader: eso requiere capturar un frame en Xcode con
Mac. Estas preguntas acotan el problema a un subsistema, no lo sustituyen.

## Cómo pedir ayuda

En una issue incluye: modelo de iPhone, versión de iOS, el log `ns3fb_*.log` más
reciente, el backtrace del crash report y qué cvars cambiaste.
