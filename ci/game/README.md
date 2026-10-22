# ci/game — el ejecutable del juego para el build en la nube

Aquí va **un solo archivo**:

```
ci/game/default.xex
```

11 218 944 bytes, SHA-1 `f7ad65e26a00df6c29c9d34b291819593e455e9f`, extraído de tu
propio disco NTSC-U de *Naruto Shippuden: Ultimate Ninja Storm 3 Full Burst*.

El codegen necesita este archivo **durante el build**, porque el código C++
recompilado se genera a partir de él. No hay forma de compilar sin él, y no se
puede sustituir por los datos del juego (`data/`, `datafb/`), que son otra cosa.

## Cómo subirlo

El repo tiene que ser **privado**: es un archivo con copyright y solo debe estar
en tu copia personal. El `.gitignore` de la raíz ignora `app/game/`, pero `ci/`
no está ignorado, así que:

```bash
cp "/ruta/a/tu/extraccion/default.xex" ci/game/default.xex
git add ci/game/default.xex
git commit -m "Add game executable for CI"
git push
```

## Lo que NO va aquí

- `data/` y `datafb/` (~7 GB): no se usan para compilar. Se añaden al `.ipa`
  después con `scripts/inject-game-files.sh`, o se copian al iPhone con la app
  Archivos.
- Cualquier otra cosa del disco.
