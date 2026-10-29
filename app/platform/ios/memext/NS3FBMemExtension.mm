// ns3fb-mem: extension que presta memoria a la app por XPC shared memory.
//
// Tecnica: ver docs/RAM_EXTENSION_PLAN.md y NS3FBRamDonorProtocol.h.
//
// Esta extension NO dibuja nada ni tiene UI. Lo unico que hace es reservar
// memoria en su proceso (donde el limite de jetsam es distinto al de la app),
// publicarla como xpc_shmem y quedarse viva mientras dure la sesion, porque
// mientras la region este viva las paginas no cuentan contra el presupuesto de
// la app.
//
// Ciclo de vida:
//   1. La app manda un NSExtensionItem con un NSXPCListenerEndpoint en userInfo.
//   2. Aqui se crea la xpc_connection de vuelta, se resume y se manda "hello".
//   3. La app pide "create" con un tamano, una o mas veces (trozos de 64 MB).
//   4. beginRequestWithExtensionContext: NO se completa nunca: si se completa,
//      iOS puede desmontar el proceso y las regiones se irian con el.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <os/proc.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <xpc/xpc.h>

#if __has_include(<xpc/shmem.h>)
#include <xpc/shmem.h>
#else
// xpc_shmem_* es API no publica, pero esta en libxpc y el SDK de iOS la declara
// en <xpc/shmem.h>. Si el SDK usado no trae el header, se declara a mano: son
// dos simbolos estables desde iOS 8.
extern "C" xpc_object_t xpc_shmem_create(void* region, size_t length);
extern "C" size_t xpc_shmem_map(xpc_object_t xpc_shmem, void** region);
#endif

#include "NS3FBRamDonorProtocol.h"

// mach/mach_vm.h es un "#error unsupported" en iOS, pero los entrypoints estan
// en libsystem_kernel y se pueden declarar a mano. OJO: en un .mm hay que
// declararlos con enlace C (extern "C"); sin eso el compilador los mangla como
// C++ y el enlazado falla con "found '_mach_vm_allocate' ... declaration
// possibly missing 'extern \"C\"'" (es lo mismo que hace MeloNX, cuyo
extension es .m y por eso no lo necesita).
extern "C" {
// Los tipos (vm_map_t, mach_vm_address_t...) son los mismos que usa la cabecera
// real, asi que la declaracion coincide con la de Mach.
kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t* address,
                               mach_vm_size_t size, int flags);
kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address,
                                 mach_vm_size_t size);
}

#ifndef VM_FLAGS_PURGABLE
#define VM_FLAGS_PURGABLE 0x2
#endif

#define NS3FBMEM_LOG(fmt, ...) NSLog(@"[NS3FB-MEM] " fmt, ##__VA_ARGS__)

#pragma mark - Regiones del donante

// Pares (direccion, tamano) de todo lo reservado, para poder soltarlo de golpe
// con "release" sin depender de que la app lleve la cuenta.
static NSMutableArray<NSValue*>* gRegions;

static void NS3FBMemReleaseRegions(void) {
  for (NSUInteger i = 0; i + 1 < gRegions.count; i += 2) {
    const mach_vm_address_t base = (mach_vm_address_t)(uintptr_t)gRegions[i].pointerValue;
    const mach_vm_size_t size = (mach_vm_size_t)(uintptr_t)gRegions[i + 1].pointerValue;
    mach_vm_deallocate(mach_task_self(), base, size);
  }
  [gRegions removeAllObjects];
}

static uint64_t NS3FBMemReservedBytes(void) {
  uint64_t total = 0;
  for (NSUInteger i = 0; i + 1 < gRegions.count; i += 2) {
    total += (uint64_t)(uintptr_t)gRegions[i + 1].pointerValue;
  }
  return total;
}

// La region se reserva PURGABLE a proposito: iOS puede reclamar esas paginas
// bajo presion en vez de matar el proceso, y mientras nadie las toque no suman
// al footprint del donante.
static xpc_object_t NS3FBMemCreateRegion(uint64_t size, NSString** error) {
  if (size == 0) {
    *error = @"tamano cero";
    return nil;
  }

  mach_vm_address_t address = 0;
  kern_return_t kr =
      mach_vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);
  if (kr != KERN_SUCCESS) {
    *error = [NSString stringWithFormat:@"mach_vm_allocate(%llu MB) fallo: %s",
                                        size / (1024 * 1024), mach_error_string(kr)];
    return nil;
  }

  xpc_object_t shmem = xpc_shmem_create((void*)address, (size_t)size);
  if (!shmem) {
    mach_vm_deallocate(mach_task_self(), address, size);
    *error = @"xpc_shmem_create devolvio NULL";
    return nil;
  }

  if (!gRegions) {
    gRegions = [NSMutableArray array];
  }
  [gRegions addObject:[NSValue valueWithPointer:(void*)(uintptr_t)address]];
  [gRegions addObject:[NSValue valueWithPointer:(void*)(uintptr_t)size]];

  return shmem;
}

#pragma mark - Metricas

static uint64_t NS3FBMemFootprint(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
    return 0;
  }
  return (uint64_t)info.phys_footprint;
}

#pragma mark - Canal XPC

static void NS3FBMemHandleMessage(xpc_connection_t channel, xpc_object_t message) {
  if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) {
    return;
  }

  const char* op = xpc_dictionary_get_string(message, NS3FBDonorKeyOp);
  if (!op) {
    return;
  }

  // "hello" lo manda el propio donante al conectar; si vuelve, se ignora.
  if (strcmp(op, "hello") == 0) {
    return;
  }

  xpc_object_t reply = xpc_dictionary_create_reply(message);
  if (!reply) {
    return;
  }

  if (strcmp(op, NS3FBDonorOpCreate) == 0) {
    NSString* error = nil;
    xpc_object_t shmem =
        NS3FBMemCreateRegion(xpc_dictionary_get_uint64(message, NS3FBDonorKeySize), &error);
    if (shmem) {
      xpc_dictionary_set_value(reply, NS3FBDonorKeyShmem, shmem);
      NS3FBMEM_LOG(@"region de %llu MB creada, reservado total %llu MB, footprint %llu MB",
                   xpc_dictionary_get_uint64(message, NS3FBDonorKeySize) / (1024 * 1024),
                   NS3FBMemReservedBytes() / (1024 * 1024), NS3FBMemFootprint() / (1024 * 1024));
    } else {
      xpc_dictionary_set_string(reply, NS3FBDonorKeyError, error.UTF8String);
      NS3FBMEM_LOG(@"no se pudo crear la region: %@", error);
    }
  } else if (strcmp(op, NS3FBDonorOpRelease) == 0) {
    NS3FBMEM_LOG(@"release: se sueltan %llu MB", NS3FBMemReservedBytes() / (1024 * 1024));
    NS3FBMemReleaseRegions();
  } else if (strcmp(op, NS3FBDonorOpAvailable) == 0) {
    xpc_dictionary_set_uint64(reply, NS3FBDonorKeyAvailable, (uint64_t)os_proc_available_memory());
  } else if (strcmp(op, NS3FBDonorOpPhysMem) == 0) {
    xpc_dictionary_set_uint64(reply, NS3FBDonorKeyPhysMem, NS3FBMemFootprint());
  } else if (strcmp(op, NS3FBDonorOpReserved) == 0) {
    xpc_dictionary_set_uint64(reply, NS3FBDonorKeyReserved, NS3FBMemReservedBytes());
  } else {
    xpc_dictionary_set_string(reply, NS3FBDonorKeyError, "operacion desconocida");
  }

  xpc_connection_send_message(channel, reply);
}

// El NSExtensionItem viaja por XPC y Foundation valida las clases permitidas al
// decodificarlo: sin este hook, userInfo["endpoint"] no se decodifica como
// NSXPCListenerEndpoint y la extension arranca sin poder hablar con la app.
// Es lo mismo que hace MeloNX; el metodo es privado de NSXPCDecoder.
static void ns3fb_do_nothing(void) {}

__attribute__((constructor)) static void NS3FBAllowEndpointDecoding(void) {
  Class decoder = NSClassFromString(@"NSXPCDecoder");
  SEL selector = NSSelectorFromString(@"_validateAllowedClass:forKey:allowingInvocations:");
  Method method = decoder ? class_getInstanceMethod(decoder, selector) : NULL;
  if (method) {
    method_setImplementation(method, (IMP)ns3fb_do_nothing);
  }
}

#pragma mark - Handler

@interface NS3FBMemExtension : NSObject <NSExtensionRequestHandling>
@end

@implementation NS3FBMemExtension {
  xpc_connection_t _channel;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext*)context {
  NSExtensionItem* item = (NSExtensionItem*)context.inputItems.firstObject;
  id wrapper = item.userInfo[@"endpoint"];

  xpc_endpoint_t endpoint = NS3FBUnwrapEndpoint(wrapper);
  if (!endpoint) {
    NS3FBMEM_LOG(@"arrancada sin endpoint utilizable (claves: %@) - saliendo",
                 item.userInfo.allKeys);
    // Sin canal no hay nada que hacer y no se completa la peticion: iOS acaba
    // matando el proceso, que es justo lo que queremos para no dejar basura.
    return;
  }

  _channel = xpc_connection_create_from_endpoint(endpoint);
  xpc_connection_set_event_handler(_channel, ^(xpc_object_t event) {
    if (xpc_get_type(event) == XPC_TYPE_ERROR) {
      NS3FBMEM_LOG(@"canal cerrado (%s) - saliendo",
                   xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
      // La app ya no nos necesita: si el canal se ha ido, las regiones mapeadas
      // siguen vivas en su espacio de direcciones, asi que salir es seguro.
      exit(0);
    }
    NS3FBMemHandleMessage(self->_channel, event);
  });
  xpc_connection_resume(_channel);

  xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(hello, NS3FBDonorKeyOp, "hello");
  xpc_connection_send_message(_channel, hello);

  NS3FBMEM_LOG(@"lista, pid %d, libre %llu MB, footprint %llu MB", getpid(),
               (uint64_t)os_proc_available_memory() / (1024 * 1024),
               NS3FBMemFootprint() / (1024 * 1024));

  // Deliberadamente NO se llama a completeRequestReturningItems: mientras la
  // peticion siga abierta, iOS mantiene el proceso (y sus regiones) vivos.
}

@end
