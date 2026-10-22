# Créditos

Nada de esto sería posible sin trabajo ajeno. En orden de importancia para este
esqueleto:

## DevZer0D4Y — MCX360-EDITION (BSD-3-Clause)
https://github.com/DevZer0D4Y/MCX360-EDITION

Es la pieza clave. Ese proyecto probó que un juego de Xbox 360 recompilado puede
correr nativamente en iPhone, y publicó el parche de iOS del SDK ReXGlue que este
esqueleto reutiliza: fibers `aarch64`, memoria/threading POSIX para iOS, superficie
de ventana iOS, controles táctiles con `touch_controls_ios.mm`, toasts de logros y
los ajustes de codegen necesarios. Este repo **descarga** ese parche
(`sdk/rexglue-sdk-ios.patch`) en vez de copiarlo, para que el crédito y las
actualizaciones se queden con su autor.

También es la fuente de la estructura de proyecto, los scripts de empaquetado y
firma, el `Info.plist` y las notas de depuración que aquí están adaptadas.

## ReXGlue
https://github.com/rexglue/rexglue-sdk

SDK de recompilación estática de Xbox 360: traduce PowerPC (incluido VMX128) a
C++ y aporta el runtime compartido (kernel, sistema de archivos, audio, input,
gráficos). Incluye el codegen, el analizador de entrypoints y la CLI `rexglue`.

## Xenia / Xenia Canary
https://github.com/xenia-project/xenia

La emulación del hardware de Xbox 360 en la que se apoya ReXGlue: GPU Xenos,
manejo de EDRAM, PM4, traducción de shaders, semántica del kernel.

## XenonRecomp
https://github.com/hedge-dev/XenonRecomp

El recompilador PowerPC→C++ original que abrió el camino; su trabajo de
instrucciones VMX128 y su enfoque de "un runtime, muchos juegos" están en la base
de todo esto.

## MoltenVK
https://github.com/KhronosGroup/MoltenVK

Vulkan sobre Metal. Sin esto no hay gráficos en iOS.

## XenosRecomp
https://github.com/hedge-dev/XenosRecomp

Conversión de shaders de Xbox 360 a HLSL → SPIR-V para Vulkan.

## Otros
SDL 3 (ventana/entrada/audio), FFmpeg (XAudio/XMA), AMD FidelityFX FSR/CAS,
libadrenotools (solo Android), ImGui.

## Aviso legal

Proyecto de fans, sin ánimo de lucro y sin ninguna relación con Bandai Namco,
CyberConnect2, Ubisoft, VIZ Media, Masashi Kishimoto ni Microsoft. *Naruto* y
*Naruto Shippuden: Ultimate Ninja Storm 3 Full Burst* son marcas y obras de sus
respectivos titulares.

Este repositorio **no incluye** archivos, vídeos, sonidos, texturas ni el
ejecutable del juego. Necesitas tu propia copia original. No pidas ni compartas
archivos del juego en issues.
