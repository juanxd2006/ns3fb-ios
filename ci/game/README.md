# ci/game — aquí NO va el ejecutable del juego

Esta carpeta está **vacía a propósito**.

En algún momento de este proyecto el repo era privado y aquí vivía `default.xex`
para que la CI pudiera compilar. Ya no: el repositorio es público y este
directorio no contiene ni contendrá nada de Bandai Namco / CyberConnect2.

## Si vas a compilar en la nube (Codemagic / GitHub Actions)

El CI necesita el ejecutable **en el árbol de trabajo**, así que tiene que estar
en un repo privado. La forma correcta:

```bash
# 1. Trabaja siempre sobre una copia privada del repo
#    (clone + Settings → Change visibility → Private, o importa como privado)

# 2. Añade tu ejecutable SOLO a esa copia privada
cp "/ruta/a/tu/extraccion/default.xex" ci/game/default.xex
git add -f ci/game/default.xex        # -f: está en .gitignore
git commit -m "Game executable for CI (copia privada)"
git push
```

`-f` es necesario porque `.gitignore` ignora `ci/game/*.xex` justamente para que
no se suba por accidente a un repo público.

## Si compilas en tu Mac

No necesitas nada aquí. Pon el juego directamente en `app/game/`:

```bash
extract-xiso -x "Naruto Storm 3 Full Burst.iso" -d app/game
shasum -a 1 app/game/default.xex
# f7ad65e26a00df6c29c9d34b291819593e455e9f
```

`app/game/` está ignorado por git: nunca se commitea.

## Requisitos del archivo

| Campo | Valor |
|---|---|
| Nombre | `default.xex` |
| Tamaño | 11 218 944 bytes |
| SHA-1 | `f7ad65e26a00df6c29c9d34b291819593e455e9f` |
| Región | NTSC-U, *Storm 3 Full Burst* |

`scripts/01-codegen.sh` aborta si el hash no coincide.

## Lo que tampoco va aquí

- `data/` y `datafb/` (~7 GB): no se usan para compilar. Van al iPhone con la app
  Archivos, o dentro del `.ipa` con `scripts/inject-game-files.sh`.
- Cualquier otra cosa extraída del disco.

## No compartas archivos del juego

Ni en issues, ni en PRs, ni en enlaces. Los issues que pidan o publiquen archivos
del juego se cierran sin respuesta.
