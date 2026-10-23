# Resultado medido — iPhone 11 (A13), iOS 27.0.1

Ejecución real del banco, `1280x720`, 4x MSAA, overdraw 4, 20 frames medidos
tras 5 de calentamiento:

```
A  tile resolve (memoryless + MultisampleResolve): 0.722 ms/frame
B  compute resolve (store + resolve4x kernel)    : 1.201 ms/frame
delta B-A: 0.479 ms/frame          (B es 1.7x el coste de A)
```

## Qué significa

Un resolve completo de 720p 4x→1x cuesta ~1,2 ms por compute y ~0,72 ms en el
tile. El tile ahorra el **40 %** de un resolve, no el 100 %: el resolve sigue
teniendo que escribir la textura de salida de 1x, y eso es ancho de banda que
ningún backend evita. Los ~3,7 MB de color 4x de lectura más 0,9 MB de escritura
están cerca del suelo de memoria del A13, así que 0,72 ms ya es un límite físico
más que una optimización.

**Un backend Metal nativo daría como mucho un 40 % menos por cada copia.** Para
un frame de 63 ms con ~30 ms de copias, eso son ~12 ms: de 15 a ~19 fps. No
cierra la brecha de 2x que hace falta.

## Lo que este número NO descarta

`fsi` no hace cada copia más barata: **elimina las copias**. En lugar de ~25
resolves por frame, hay una sola pasada con la EDRAM emulada en el pixel shader.
Eso es una categoría distinta de ahorro, y sigue siendo la única vía con el techo
suficiente. La conclusión de este banco es que no merece la pena *escribir un
backend* para conseguirla; no que `fsi` no sirva.

## Dato colateral útil

Con 30,34 ms de `Compute GPU` en la escena de selección, y ~1,2 ms por resolve,
salen del orden de **25 resolves de 720p por frame**. El problema real no es lo
caros que son: es cuántos hay. Eso es la arquitectura de emulación de EDRAM de
Xenia, no el driver.
