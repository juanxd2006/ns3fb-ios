// Puente C entre el runtime (C++/ObjC++) y el donante de memoria de iOS.
//
// Ver docs/RAM_EXTENSION_PLAN.md. Resumen: en iOS el limite de memoria es por
// proceso; la extension ns3fb-mem corre en otro proceso, reserva ahi la RAM del
// invitado y se la pasa a la app como memoria compartida. La app la recoloca
// encima de sus propios views con mach_vm_remap, asi que el invitado sigue
// viendo un unico rango contiguo en las mismas direcciones.
//
// Todo falla de forma suave: si no hay extension, si iOS la rechaza o si reserva
// menos de lo pedido, el juego se queda con el mapeo respaldado por fichero de
// siempre y no cambia nada.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Si el bundle trae la extension ns3fb-mem. No arranca nada.
bool ns3fb_ram_donor_is_available(void);

/// Arranca hasta `count` procesos donantes y espera a que conecten.
/// Devuelve cuantos estan vivos.
uint32_t ns3fb_ram_donor_start(uint32_t count, double timeout_seconds);

/// Memoria que el primer donante dice que puede reservar todavia, en bytes.
uint64_t ns3fb_ram_donor_available_memory(void);

/// Bytes que la app tiene mapeados y respaldados por donantes.
uint64_t ns3fb_ram_donor_donated_bytes(void);

/// `task_vm_info.phys_footprint` del proceso de la app, en bytes.
uint64_t ns3fb_ram_donor_phys_footprint(void);

/// Ultimo error legible. Cadena vacia si no hubo.
const char* ns3fb_ram_donor_last_error(void);

/// Tras mapear, matar los donantes: las paginas ya mapeadas siguen vivas, y
/// asi iOS no los mata por su cuenta en mitad de la partida.
void ns3fb_ram_donor_set_kill_after_mapping(bool enabled);

/// Sustituye los `bytes` que empiezan en la memoria fisica del invitado por
/// memoria de los donantes.
///
/// `virtual_membase` es Memory::virtual_membase(): el rango fisico esta en las
/// vistas 0x7F000000, 0xA0000000, 0xC0000000, 0xE0000000 y 0x100000000 del
/// mismo mapeo (ver Memory::MapViewsMac en el SDK), y las cinco hay que
/// recolocarlas o se rompe el aliasing invitado/GPU.
///
/// Devuelve los bytes efectivamente respaldados (0 si no se pudo hacer nada).
uint64_t ns3fb_ram_donor_back_guest_ram(uint8_t* virtual_membase, uint64_t bytes);

/// Suelta regiones y termina los donantes. Solo para el cierre ordenado; iOS
/// limpia igualmente al matar el proceso.
void ns3fb_ram_donor_shutdown(void);

#ifdef __cplusplus
}  // extern "C"
#endif
