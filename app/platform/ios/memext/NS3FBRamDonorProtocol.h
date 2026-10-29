// Protocolo compartido entre la app (ns3fb) y la extension ns3fb-mem.
//
// La extension corre en su PROPIO proceso, con su propio presupuesto de jetsam.
// Reserva memoria con mach_vm_allocate(VM_FLAGS_PURGABLE), la publica con
// xpc_shmem_create() y manda el descriptor por esta conexion XPC. La app la
// mapea con xpc_shmem_map() y la recoloca con mach_vm_remap() sobre los views
// del invitado. Asi las paginas del invitado dejan de contar en el
// phys_footprint de la app, que es lo que la mata en un iPhone de 3/4 GB.
//
// Referencia: MeloNX 2.7 (starforgejo.dev/projects/MeloNX), mismo esquema.
//
// Este header lo compilan los dos lados: nada de C++ aqui.

#ifndef NS3FB_RAM_DONOR_PROTOCOL_H
#define NS3FB_RAM_DONOR_PROTOCOL_H

#import <Foundation/Foundation.h>
#import <xpc/xpc.h>

// Tamano de cada trozo que se pide a un donante. Mas pequeno = mas granularidad
// para repartir entre extensiones y para sobrevivir si una se niega; mas grande
// = menos viajes XPC. 64 MB da 8 trozos para los 512 MB del invitado.
#define NS3FB_DONOR_CHUNK_SIZE (64ull * 1024ull * 1024ull)

// Margen que se le deja a cada donante por debajo de lo que dice
// os_proc_available_memory(): si se pide todo lo libre, iOS mata la extension
// justo despues de reservar.
#define NS3FB_DONOR_HEADROOM (128ull * 1024ull * 1024ull)

#pragma mark Claves del diccionario XPC

// Peticion: operacion a ejecutar (uno de los NS3FBDonorOp* de abajo).
#define NS3FBDonorKeyOp "op"
// Peticion (create): bytes que se piden.
#define NS3FBDonorKeySize "size"
// Respuesta (create): el xpc_shmem con la region reservada.
#define NS3FBDonorKeyShmem "shmem"
// Respuesta: motivo del fallo. Ausente si todo fue bien.
#define NS3FBDonorKeyError "error"
// Respuesta (available): os_proc_available_memory() del donante.
#define NS3FBDonorKeyAvailable "available"
// Respuesta (physmem): task_vm_info.phys_footprint del donante.
#define NS3FBDonorKeyPhysMem "phys_footprint"
// Respuesta (reserve): bytes que el donante ha reservado en total.
#define NS3FBDonorKeyReserved "reserved"

#pragma mark Operaciones

// Reserva `size` bytes y los devuelve como xpc_shmem.
#define NS3FBDonorOpCreate "create"
// Libera todas las regiones que tenga el donante. La app debe haberlas
// desmapeado antes.
#define NS3FBDonorOpRelease "release"
// Cuanta memoria puede reservar aun el donante antes de que lo maten.
#define NS3FBDonorOpAvailable "available"
// Cuanta memoria fisica ocupa el donante.
#define NS3FBDonorOpPhysMem "phys_footprint"
// Cuanto lleva reservado el donante. Sirve para detectar fugas entre sesiones.
#define NS3FBDonorOpReserved "reserved"

NS_ASSUME_NONNULL_BEGIN

// NSXPCListenerEndpoint no expone su xpc_endpoint_t: solo se puede crear uno con
// el setter privado _setEndpoint:. Lo necesita la app para pasarle al donante la
// conexion de vuelta, porque NSExtensionItem.userInfo solo transporta objetos
// NSSecureCoding y un xpc_endpoint_t no lo es.
@interface NSXPCListenerEndpoint (NS3FBDoor)
@property(nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end

static inline NSXPCListenerEndpoint* NS3FBWrapEndpoint(xpc_endpoint_t endpoint) {
  NSXPCListenerEndpoint* wrapper = [NSXPCListenerEndpoint new];
  wrapper._endpoint = endpoint;
  return wrapper;
}

static inline xpc_endpoint_t _Nullable NS3FBUnwrapEndpoint(NSXPCListenerEndpoint* _Nullable wrapper) {
  if (!wrapper || ![wrapper isKindOfClass:NSXPCListenerEndpoint.class]) {
    return NULL;
  }
  xpc_object_t inner = wrapper._endpoint;
  if (!inner || xpc_get_type(inner) != XPC_TYPE_ENDPOINT) {
    return NULL;
  }
  return (xpc_endpoint_t)inner;
}

NS_ASSUME_NONNULL_END

#endif  // NS3FB_RAM_DONOR_PROTOCOL_H
