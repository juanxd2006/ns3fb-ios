# Your game files go here

Nothing from the game is distributed with this project. Copy in the files you
extracted from **your own** Naruto Shippuden: Ultimate Ninja Storm 3 Full Burst
Xbox 360 disc (NTSC-U). See ../README.md, Paso 1.

```
game/
├── default.xex          <- from the disc, SHA-1 must match
├── nxeart
├── AvatarAssetPack
├── data/                <- game data
└── datafb/              <- Full Burst content
```

Required: Title ID `4E4D085C`, Media ID `2576927D`, version `0.0.0.9`,
default.xex SHA-1 `f7ad65e26a00df6c29c9d34b291819593e455e9f` (11 218 944 bytes).

Verify:

    shasum -a 1 app/game/default.xex
