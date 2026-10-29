// ns3fb-mem: extension que presta memoria al app por XPC shared memory.
//
// Se compila SOLO con -DNS3FB_MEM_EXTENSION=ON (apagado por defecto). Ver
// docs/RAM_EXTENSION_PLAN.md para el diseno y lo que falta por verificar.
//
// Flujo:
//   1. El app se conecta al servicio mach "<bundle-id>.memext".
//   2. Pide N bytes con el mensaje { "bytes": N }.
//   3. La extension crea la region con xpc_shmem_create() EN SU PROCESO, la
//      retiene y devuelve el objeto en la respuesta bajo la clave "shmem".
//   4. El app la mapea con xpc_shmem_map().
//
// Las paginas quedan contabilizadas en el proceso de la extension, no en el del
// app. Esa es toda la tecnica.

#import <Foundation/Foundation.h>
#include <xpc/xpc.h>
#if __has_include(<xpc/shmem.h>)
#include <xpc/shmem.h>
#define NS3FB_HAVE_XPC_SHMEM 1
#else
#define NS3FB_HAVE_XPC_SHMEM 0
#endif
#include <cstdio>

// Regiones vivas mientras viva el proceso. Si iOS mata la extension, estas
// paginas desaparecen y el app se queda con memoria invalida mapeada: por eso
// el cliente del app tiene que tratar la caida como error fatal, no reintentar.
static xpc_object_t g_region = NULL;


// Entrada de la extension. No completa la peticion A PROPOSITO: mientras no la
// complete, iOS mantiene el proceso vivo, y con el, la region creada por el
// listener de arriba. El trabajo real no ocurre aqui, sino en el servicio mach.
@interface NS3FBMemExtension : NSObject <NSExtensionRequestHandling>
@end

@implementation NS3FBMemExtension

- (void)beginRequestWithExtensionContext:(NSExtensionContext*)context {
  std::fprintf(stderr, "[ns3fb-mem] extension arrancada; queda viva para servir memoria\n");
  (void)context;  // sin completeRequestReturningItems: no muere
}

@end


static void ns3fb_mem_peer(xpc_connection_t peer) {
  xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
    if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) {
      return;
    }
#if NS3FB_HAVE_XPC_SHMEM
    size_t bytes = (size_t)xpc_dictionary_get_uint64(event, "bytes");
    if (bytes == 0) {
      bytes = 512ull * 1024ull * 1024ull;
    }
    if (!g_region) {
      g_region = xpc_shmem_create(NULL, bytes);
      if (g_region) {
        std::fprintf(stderr, "[ns3fb-mem] region creada: %zu bytes\n", bytes);
      } else {
        std::fprintf(stderr, "[ns3fb-mem] xpc_shmem_create fallo para %zu bytes\n", bytes);
      }
    }
    xpc_object_t reply = xpc_dictionary_create_reply(event);
    if (reply) {
      if (g_region) {
        xpc_dictionary_set_value(reply, "shmem", g_region);
        xpc_dictionary_set_uint64(reply, "bytes", bytes);
      } else {
        xpc_dictionary_set_uint64(reply, "bytes", 0);
      }
      xpc_connection_send_message(peer, reply);
    }
#else
    std::fprintf(stderr, "[ns3fb-mem] este SDK no tiene <xpc/shmem.h>\n");
#endif
  });
  xpc_connection_resume(peer);
}

__attribute__((constructor)) static void ns3fb_mem_start(void) {
#if NS3FB_HAVE_XPC_SHMEM
  // Nombre del servicio declarado en Info.plist (MachServices). El sufijo
  // ".memext" lo pone el bundle id que inyecta CMake con NS3FB_BUNDLE_ID.
  const char* service = NS3FB_MEMEXT_SERVICE_NAME;
  xpc_connection_t listener = xpc_connection_create_mach_service(service, NULL,
                                                                 XPC_CONNECTION_MACH_SERVICE_LISTENER);
  if (listener) {
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
      if (xpc_get_type(event) == XPC_TYPE_CONNECTION) {
        ns3fb_mem_peer((xpc_connection_t)event);
      }
    });
    xpc_connection_resume(listener);
    std::fprintf(stderr, "[ns3fb-mem] escuchando en %s\n", service);
  } else {
    std::fprintf(stderr, "[ns3fb-mem] no se pudo crear el listener %s\n", service);
  }
#endif
}
