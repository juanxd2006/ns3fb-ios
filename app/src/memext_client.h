// Cliente de la extension de memoria (opt-in).
//
// Con -DNS3FB_MEM_EXTENSION=ON, la app pide un bloque al proceso de la
// extension y lo usa como backing de la memoria del invitado. Con el flag
// apagado (por defecto) esta cabecera devuelve un bloque vacio y el port
// funciona exactamente igual que siempre.
#pragma once

#include <cstddef>

namespace ns3fb {

struct MemRegion {
  void* base = nullptr;  // nullptr = no disponible, usa el camino normal
  std::size_t size = 0;
};

/// Arranca la extension, pide `bytes` y mapea la region en este proceso.
/// Devuelve {nullptr, 0} si el flag esta apagado, si la extension no esta
/// instalada o si xpc_shmem no existe en el SDK. NO aborta nunca.
MemRegion AcquireMemExtensionRegion(std::size_t bytes);

/// Cierra la conexion y desmapea. Llamar antes de terminar la sesion.
void ReleaseMemExtensionRegion();

}  // namespace ns3fb
