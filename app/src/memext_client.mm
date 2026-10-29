// Cliente de la extension de memoria. Ver docs/RAM_EXTENSION_PLAN.md.
//
// Con NS3FB_MEM_EXTENSION apagado esto compila a un stub que devuelve vacio, de
// modo que el build por defecto no cambia en nada.

#include "memext_client.h"

#if defined(NS3FB_MEM_EXTENSION) && NS3FB_MEM_EXTENSION

#include <rex/logging.h>

#include <xpc/xpc.h>
#if __has_include(<xpc/shmem.h>)
#include <xpc/shmem.h>
#else
#error "Este SDK de iOS no trae <xpc/shmem.h>: la extension no puede funcionar"
#endif

#include <cstdio>

namespace ns3fb {
namespace {

xpc_connection_t g_connection = nullptr;
void* g_base = nullptr;
std::size_t g_size = 0;

}  // namespace

MemRegion AcquireMemExtensionRegion(std::size_t bytes) {
  if (g_base) {
    return {g_base, g_size};
  }
  if (!bytes) {
    return {};
  }

  const char* service = NS3FB_MEMEXT_SERVICE_NAME;
  g_connection = xpc_connection_create_mach_service(service, nullptr, 0);
  if (!g_connection) {
    REXLOG_ERROR("memext: no se pudo crear la conexion a {} (extension no instalada?)", service);
    return {};
  }
  xpc_connection_set_event_handler(g_connection, ^(xpc_object_t event) {
    if (xpc_get_type(event) == XPC_TYPE_ERROR) {
      REXLOG_ERROR("memext: error de conexion XPC (la extension pudo morir)");
    }
  });
  xpc_connection_resume(g_connection);

  xpc_object_t request = xpc_dictionary_create(nullptr, nullptr, 0);
  xpc_dictionary_set_uint64(request, "bytes", static_cast<uint64_t>(bytes));

  xpc_object_t reply = xpc_connection_send_message_with_reply_sync(g_connection, request);
  xpc_release(request);
  if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
    REXLOG_ERROR("memext: sin respuesta valida de {}", service);
    if (reply) xpc_release(reply);
    return {};
  }

  xpc_object_t region = xpc_dictionary_get_value(reply, "shmem");
  const uint64_t got = xpc_dictionary_get_uint64(reply, "bytes");
  if (!region || !got) {
    REXLOG_ERROR("memext: la extension no devolvio region ({} bytes pedidos)", bytes);
    xpc_release(reply);
    return {};
  }

  size_t mapped_size = 0;
  void* mapped = xpc_shmem_map(region, &mapped_size);
  xpc_release(reply);
  if (!mapped) {
    REXLOG_ERROR("memext: xpc_shmem_map fallo");
    return {};
  }

  g_base = mapped;
  g_size = mapped_size;
  REXLOG_INFO("memext: {} MB mapeados desde el proceso de la extension", mapped_size >> 20);
  return {g_base, g_size};
}

void ReleaseMemExtensionRegion() {
  // Deliberadamente no se desmapea: liberar la region mientras el invitado
  // tiene punteros dentro es peor que dejarla. Se cierra la conexion y listo.
  if (g_connection) {
    xpc_connection_cancel(g_connection);
    xpc_release(g_connection);
    g_connection = nullptr;
  }
}

}  // namespace ns3fb

#else  // NS3FB_MEM_EXTENSION apagado

namespace ns3fb {

MemRegion AcquireMemExtensionRegion(std::size_t) { return {}; }

void ReleaseMemExtensionRegion() {}

}  // namespace ns3fb

#endif
