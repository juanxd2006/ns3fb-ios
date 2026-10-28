# metal-720p

Banco de decisión: mide en tu móvil si un backend Metal nativo puede dejar el
frame de 720p dentro del presupuesto de 30 fps.

No es el port ni usa el SDK de ReXGlue: un solo `.mm`, ~1 minuto de build, sin
necesidad de `default.xex`.

```bash
./spike/metal-720p/build-ipa.sh     # -> Metal720p.ipa
```

En Codemagic: workflow **«Metal 720p (budget)»**, que se dispara solo desde la
rama `experiment/metal-720p`.

El resultado sale en pantalla, en `Documents/spike_metal_720p.txt` y por `NSLog`
con el prefijo `[metal-720p]`.

Qué mide y cómo se interpreta: [`docs/METAL_720P_EXPERIMENT.md`](../../docs/METAL_720P_EXPERIMENT.md).
