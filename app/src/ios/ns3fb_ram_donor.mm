// Lado app del donante de memoria de iOS.
//
// Tecnica y motivo: docs/RAM_EXTENSION_PLAN.md.
// Referencia: MeloNX 2.7 (starforgejo.dev/projects/MeloNX), que usa el mismo
// esquema NSExtension + xpc_shmem.
//
// Que hace, en orden:
//   1. Encuentra la extension ns3fb-mem en PlugIns/ del bundle.
//   2. La arranca con NSExtension (API privada) pasandole un
//      NSXPCListenerEndpoint; la extension conecta de vuelta por XPC.
//   3. Pide trozos de NS3FB_DONOR_CHUNK_SIZE: la extension los reserva en SU
//      proceso y devuelve un xpc_shmem.
//   4. Mapea cada trozo (xpc_shmem_map) y lo recoloca con mach_vm_remap sobre
//      las vistas del invitado, una por cada alias del mismo rango fisico.
//
// Las paginas quedan contadas en el proceso de la extension (o como memoria
// compartida), no en el phys_footprint de la app, que es lo que jetsam mira.

#import "ns3fb_ram_donor.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <os/proc.h>
#import <signal.h>
#import <xpc/xpc.h>

#import "NS3FBRamDonorProtocol.h"

#if __has_include(<xpc/shmem.h>)
#include <xpc/shmem.h>
#else
extern "C" xpc_object_t xpc_shmem_create(void* region, size_t length);
extern "C" size_t xpc_shmem_map(xpc_object_t xpc_shmem, void** region);
#endif

// mach/mach_vm.h no se puede incluir en iOS (es un #error), pero los simbolos
// existen en libsystem_kernel. OJO: en un .mm hay que declararlos con enlace C;
// sin extern "C" el compilador los mangla como C++ y el enlazado falla con
// "found '_mach_vm_remap' ... declaration possibly missing 'extern \"C\"'".
extern "C" {
kern_return_t mach_vm_remap(vm_map_t target, mach_vm_address_t* address, mach_vm_size_t size,
                            mach_vm_offset_t mask, int flags, vm_map_t source,
                            mach_vm_address_t source_address, boolean_t copy,
                            vm_prot_t* current_protection, vm_prot_t* max_protection,
                            vm_inherit_t inheritance);
kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address,
                                 mach_vm_size_t size);
}

#ifndef VM_FLAGS_FIXED
#define VM_FLAGS_FIXED 0x0
#endif
#ifndef VM_FLAGS_OVERWRITE
#define VM_FLAGS_OVERWRITE 0x4000
#endif

#define NS3FB_RAM_LOG(fmt, ...) NSLog(@"[NS3FB-RAM] " fmt, ##__VA_ARGS__)

#pragma mark - NSExtension (API privada)

// NSExtension.h no esta en el SDK publico. Declarar la clase a mano es la unica
// forma de arrancar una extension desde la propia app sin pasar por la hoja de
// compartir; es lo que hacen MeloNX y el resto de ports con esta tecnica.
@interface NSExtension : NSObject
@property(nonatomic, strong, readwrite) NSArray* preferredLanguages;
+ (instancetype)extensionWithIdentifier:(NSString*)identifier error:(NSError**)error;
- (void)beginExtensionRequestWithInputItems:(NSArray*)items
                                 completion:(void (^)(NSUUID*))callback;
- (int)pidForRequestIdentifier:(NSUUID*)identifier;
- (void)setRequestCancellationBlock:(void (^)(NSUUID*, NSError*))callback;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID*))callback;
- (void)_kill:(int)signal;
@end

#pragma mark - Geometria del mapa de memoria del invitado

// Copia de Memory::map_info del SDK para las vistas que aliasean la RAM fisica
// (los 512 MB del invitado). Si el SDK cambia el layout, esto hay que seguirlo:
// los valores estan en src/system/xmemory.cpp.
//
// `file_offset` es el target_address del SDK ya redondeado a la granularidad de
// asignacion, que es como MapViewsMac acaba mapeando el fichero.
struct GuestView {
  uint64_t host_offset;  // respecto a virtual_membase
  uint64_t size;
  uint64_t file_offset;
};

static const uint64_t kGuestRamFileOffset = 0x100000000ull;
static const uint64_t kGuestRamSize = 0x20000000ull;  // 512 MB

static uint64_t NS3FBViewFileOffset(uint64_t target) {
  // Misma mascara que usa MapViewsMac: el offset de mmap se redondea hacia
  // abajo a la granularidad (16 KB en arm64 de Apple).
  const uint64_t granularity = (uint64_t)vm_page_size;
  return target & ~(granularity - 1);
}

static const GuestView* NS3FBRamViews(size_t* count) {
  static GuestView views[5];
  static size_t view_count = 0;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    views[0] = {0x000000007F000000ull, 0x0000000001000000ull, 0x0000000100000000ull};
    views[1] = {0x00000000A0000000ull, 0x0000000020000000ull, 0x0000000100000000ull};
    views[2] = {0x00000000C0000000ull, 0x0000000020000000ull, 0x0000000100000000ull};
    // El heap de 0xE0 va desplazado 4 KB: el SDK redondea su offset de fichero
    // a la granularidad y luego suma PhysicalHostOffset al traducir.
    views[3] = {0x00000000E0000000ull, 0x0000000020000000ull,
                NS3FBViewFileOffset(0x0000000100001000ull)};
    views[4] = {0x0000000100000000ull, 0x0000000020000000ull, 0x0000000100000000ull};
    view_count = 5;
  });
  *count = view_count;
  return views;
}

#pragma mark - Registro de lo donado

@interface NS3FBDonorSlot : NSObject
@property(nonatomic) xpc_connection_t connection;
@property(nonatomic) uint64_t remaining;
@end

@implementation NS3FBDonorSlot
@end

@interface NS3FBRamDonor : NSObject
@property(nonatomic) xpc_connection_t listener;
@property(nonatomic) NSMutableArray<NSExtension*>* extensions;
@property(nonatomic) NSMutableArray* connections;
@property(nonatomic) NSMutableArray* keptShmems;
@property(nonatomic) dispatch_semaphore_t connected;
@property(nonatomic) NSUInteger maxDonors;
@property(nonatomic) BOOL killDonorsAfterMapping;
@property(nonatomic, copy) NSString* lastError;
@property(nonatomic) uint64_t donatedBytes;
+ (instancetype)shared;
+ (instancetype)sharedIfExists;
+ (NSString*)donorBundleIdentifier;
- (NSUInteger)liveDonorCount;
- (NSUInteger)startDonors:(NSUInteger)count timeout:(NSTimeInterval)timeout;
- (BOOL)startOneDonorWithTimeout:(NSTimeInterval)timeout;
- (uint64_t)availableMemory;
- (uint64_t)availableMemoryForConnection:(xpc_connection_t)connection;
- (uint64_t)backGuestRam:(uint8_t*)membase bytes:(uint64_t)bytes;
- (void)killDonorProcesses;
- (void)shutdown;
@end

static NS3FBRamDonor* gSharedDonor;

@implementation NS3FBRamDonor

+ (instancetype)shared {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gSharedDonor = [NS3FBRamDonor new];
  });
  return gSharedDonor;
}

+ (instancetype)sharedIfExists {
  return gSharedDonor;
}

- (instancetype)init {
  self = [super init];
  if (!self) {
    return nil;
  }

  _extensions = [NSMutableArray array];
  _connections = [NSMutableArray array];
  _keptShmems = [NSMutableArray array];
  _connected = dispatch_semaphore_create(0);
  _maxDonors = 4;
  _killDonorsAfterMapping = YES;
  _donatedBytes = 0;

  // Listener por donde los donantes se conectan de vuelta. No acepta clientes
  // de fuera: solo se comparte su endpoint con la extension que arrancamos.
  _listener = xpc_connection_create(NULL, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));

  __weak typeof(self) weakSelf = self;
  xpc_connection_set_event_handler(_listener, ^(xpc_object_t event) {
    if (xpc_get_type(event) != XPC_TYPE_CONNECTION) {
      return;
    }
    [weakSelf acceptConnection:(xpc_connection_t)event];
  });
  xpc_connection_resume(_listener);

  return self;
}

- (NSUInteger)liveDonorCount {
  @synchronized(self) {
    return self.connections.count;
  }
}

#pragma mark Arranque de donantes

// Se busca por NSExtensionPrincipalClass y no por bundle id: el bundle id lleva
// el de la app (com.example.ns3fb.mem) y cambia si el usuario cambia el suyo.
+ (NSString*)donorBundleIdentifier {
  static NSString* identifier;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURL* plugIns = NSBundle.mainBundle.builtInPlugInsURL;
    NSArray<NSURL*>* contents = plugIns ? [NSFileManager.defaultManager
                                              contentsOfDirectoryAtURL:plugIns
                                            includingPropertiesForKeys:nil
                                                               options:0
                                                                 error:nil]
                                        : @[];

    NSMutableArray<NSString*>* found = [NSMutableArray array];
    for (NSURL* url in contents) {
      if (![url.pathExtension isEqualToString:@"appex"]) {
        continue;
      }
      NSBundle* bundle = [NSBundle bundleWithURL:url];
      NSString* principal = bundle.infoDictionary[@"NSExtension"][@"NSExtensionPrincipalClass"];
      NSString* bundle_id = bundle.bundleIdentifier ?: url.lastPathComponent;
      [found addObject:bundle_id];
      if ([principal isEqualToString:@"NS3FBMemExtension"]) {
        identifier = bundle_id;
      }
    }

    if (identifier) {
      NS3FB_RAM_LOG(@"extension donante: %@", identifier);
    } else {
      NS3FB_RAM_LOG(@"no hay extension donante en PlugIns (encontrado: %@)",
                    found.count ? [found componentsJoinedByString:@", "] : @"nada");
    }
  });
  return identifier;
}

- (NSUInteger)startDonors:(NSUInteger)count timeout:(NSTimeInterval)timeout {
  for (NSUInteger i = self.liveDonorCount; i < count; i++) {
    if (![self startOneDonorWithTimeout:timeout]) {
      break;
    }
  }
  return self.liveDonorCount;
}

- (BOOL)startOneDonorWithTimeout:(NSTimeInterval)timeout {
  NSString* identifier = NS3FBRamDonor.donorBundleIdentifier;
  if (!identifier) {
    self.lastError = @"la extension de memoria no esta en este build";
    return NO;
  }

  NSError* error = nil;
  NSExtension* extension = [NSExtension extensionWithIdentifier:identifier error:&error];
  if (!extension) {
    self.lastError = [NSString stringWithFormat:@"no se pudo cargar %@: %@", identifier,
                                                error.localizedDescription];
    NS3FB_RAM_LOG(@"%@", self.lastError);
    return NO;
  }

  // Sin idiomas preferidos se salta la negociacion de localizacion, que en una
  // extension sin UI solo gasta tiempo de arranque.
  extension.preferredLanguages = @[];

  NSExtensionItem* item = [NSExtensionItem new];
  item.userInfo = @{@"endpoint" : NS3FBWrapEndpoint(xpc_endpoint_create(self.listener))};

  [extension setRequestCancellationBlock:^(NSUUID* uuid, NSError* cancelError) {
    NS3FB_RAM_LOG(@"peticion de donante cancelada: %@", cancelError.localizedDescription);
  }];

  const NSUInteger before = self.liveDonorCount;

  __block BOOL started = NO;
  __block NSUUID* requestIdentifier = nil;
  dispatch_semaphore_t spawned = dispatch_semaphore_create(0);

  [extension beginExtensionRequestWithInputItems:@[ item ]
                                      completion:^(NSUUID* uuid) {
                                        requestIdentifier = uuid;
                                        started = uuid != nil;
                                        dispatch_semaphore_signal(spawned);
                                      }];

  dispatch_semaphore_wait(spawned,
                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));

  if (!started) {
    self.lastError = @"iOS rechazo la peticion: no se arranco ningun proceso";
    NS3FB_RAM_LOG(@"%@", self.lastError);
    return NO;
  }

  NS3FB_RAM_LOG(@"proceso donante arrancado (pid %d), esperando su conexion",
                [extension pidForRequestIdentifier:requestIdentifier]);

  const NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + timeout;
  while (self.liveDonorCount <= before) {
    const NSTimeInterval remaining = deadline - NSDate.timeIntervalSinceReferenceDate;
    if (remaining <= 0) {
      self.lastError = @"el donante arranco pero no conecto a tiempo";
      NS3FB_RAM_LOG(@"%@", self.lastError);
      return NO;
    }
    dispatch_semaphore_wait(
        self.connected,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
  }

  @synchronized(self) {
    [self.extensions addObject:extension];
  }
  return YES;
}

- (void)acceptConnection:(xpc_connection_t)connection {
  __weak typeof(self) weakSelf = self;
  xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
    if (xpc_get_type(event) == XPC_TYPE_ERROR) {
      [weakSelf forgetConnection:connection];
    }
  });
  xpc_connection_resume(connection);

  @synchronized(self) {
    [self.connections addObject:connection];
  }
  dispatch_semaphore_signal(self.connected);
}

- (void)forgetConnection:(xpc_connection_t)connection {
  @synchronized(self) {
    [self.connections removeObjectIdenticalTo:connection];
  }
  NS3FB_RAM_LOG(@"un donante se fue, quedan %lu", (unsigned long)self.liveDonorCount);
}

#pragma mark Hablar con los donantes

- (xpc_object_t)send:(const char*)op
                  to:(xpc_connection_t)donor
                size:(uint64_t)size
             timeout:(NSTimeInterval)timeout {
  xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(request, NS3FBDonorKeyOp, op);
  if (size) {
    xpc_dictionary_set_uint64(request, NS3FBDonorKeySize, size);
  }

  __block xpc_object_t answer = nil;
  dispatch_semaphore_t replied = dispatch_semaphore_create(0);

  xpc_connection_send_message_with_reply(
      donor, request, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
          answer = reply;
        }
        dispatch_semaphore_signal(replied);
      });

  if (dispatch_semaphore_wait(
          replied, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
    return nil;
  }
  return answer;
}

- (uint64_t)availableMemoryForConnection:(xpc_connection_t)connection {
  xpc_object_t reply = [self send:NS3FBDonorOpAvailable to:connection size:0 timeout:2.0];
  return reply ? xpc_dictionary_get_uint64(reply, NS3FBDonorKeyAvailable) : 0;
}

- (uint64_t)availableMemory {
  xpc_connection_t donor = nil;
  @synchronized(self) {
    donor = self.connections.firstObject;
  }
  return donor ? [self availableMemoryForConnection:donor] : 0;
}

#pragma mark Reservar y recolocar

- (BOOL)addSlotForNextDonorTo:(NSMutableArray<NS3FBDonorSlot*>*)slots {
  const NSUInteger before = self.liveDonorCount;
  if (slots.count >= before && ![self startOneDonorWithTimeout:8.0]) {
    return NO;
  }

  xpc_connection_t connection = nil;
  @synchronized(self) {
    NSMutableArray* spare = [self.connections mutableCopy];
    for (NS3FBDonorSlot* slot in slots) {
      [spare removeObjectIdenticalTo:slot.connection];
    }
    connection = spare.firstObject;
  }
  if (!connection) {
    return NO;
  }

  const uint64_t budget = [self availableMemoryForConnection:connection];
  NS3FBDonorSlot* slot = [NS3FBDonorSlot new];
  slot.connection = connection;
  // Un donante puede tener un presupuesto enorme (es otro proceso), pero si se
  // le pide entero se muere justo despues de reservar. Se le deja margen.
  slot.remaining = budget > NS3FB_DONOR_HEADROOM ? budget - NS3FB_DONOR_HEADROOM : 0;
  [slots addObject:slot];

  NS3FB_RAM_LOG(@"donante %lu con %llu MB libres; se usaran hasta %llu MB",
                (unsigned long)slots.count, budget / (1024 * 1024),
                slot.remaining / (1024 * 1024));
  return slot.remaining > 0;
}

- (NS3FBDonorSlot*)slotWithRoomFor:(uint64_t)length
                                in:(NSMutableArray<NS3FBDonorSlot*>*)slots {
  for (NSUInteger i = 0; i < slots.count; i++) {
    NS3FBDonorSlot* slot = slots[i];
    if (slot.remaining >= length) {
      return slot;
    }
  }
  if (slots.count >= self.maxDonors) {
    return nil;
  }
  if (![self addSlotForNextDonorTo:slots]) {
    return nil;
  }
  NS3FBDonorSlot* added = slots.lastObject;
  return added.remaining >= length ? added : nil;
}

// Recoloca un trozo donado sobre todas las vistas que aliasean el rango fisico
// del invitado. `scratch` es el mapeo temporal de xpc_shmem_map y `ram_file` es
// el offset del trozo dentro del fichero de memoria (0x100000000 + offset).
- (BOOL)placeChunk:(void*)scratch
          filebase:(uint64_t)ram_file
            length:(uint64_t)length
        guestViews:(const GuestView*)views
             count:(size_t)viewCount
          membase:(uint8_t*)membase {
  const uint64_t chunk_end = ram_file + length;
  BOOL placed = NO;

  for (size_t i = 0; i < viewCount; i++) {
    const GuestView& view = views[i];
    const uint64_t view_start = view.file_offset;
    const uint64_t view_end = view.file_offset + view.size;

    const uint64_t start = MAX(view_start, ram_file);
    const uint64_t end = MIN(view_end, chunk_end);
    if (end <= start) {
      continue;
    }

    mach_vm_address_t destination =
        (mach_vm_address_t)(uintptr_t)(membase + view.host_offset + (start - view.file_offset));
    mach_vm_address_t source = (mach_vm_address_t)(uintptr_t)scratch + (start - ram_file);
    vm_prot_t current = VM_PROT_NONE;
    vm_prot_t maximum = VM_PROT_NONE;

    kern_return_t kr = mach_vm_remap(mach_task_self(), &destination, end - start, 0,
                                     VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), source,
                                     false, &current, &maximum, VM_INHERIT_SHARE);
    if (kr != KERN_SUCCESS) {
      self.lastError = [NSString stringWithFormat:@"mach_vm_remap fallo en la vista %zu: %s", i,
                                                  mach_error_string(kr)];
      NS3FB_RAM_LOG(@"%@", self.lastError);
      continue;
    }
    placed = YES;
  }

  return placed;
}

- (uint64_t)backGuestRam:(uint8_t*)membase bytes:(uint64_t)bytes {
  if (!membase || bytes == 0) {
    return 0;
  }

  const uint64_t page_mask = (uint64_t)vm_page_size - 1;
  bytes = MIN(bytes, kGuestRamSize);
  bytes = (bytes + page_mask) & ~page_mask;
  if (bytes == 0) {
    return 0;
  }

  size_t viewCount = 0;
  const GuestView* views = NS3FBRamViews(&viewCount);

  NSMutableArray<NS3FBDonorSlot*>* slots = [NSMutableArray array];
  if (![self addSlotForNextDonorTo:slots]) {
    return 0;
  }

  uint64_t offset = 0;
  while (offset < bytes) {
    const uint64_t length = MIN(NS3FB_DONOR_CHUNK_SIZE, bytes - offset);

    NS3FBDonorSlot* slot = [self slotWithRoomFor:length in:slots];
    if (!slot) {
      self.lastError = [NSString stringWithFormat:
                                         @"los donantes solo cubrieron %llu MB de %llu MB",
                                         offset / (1024 * 1024), bytes / (1024 * 1024)];
      NS3FB_RAM_LOG(@"%@", self.lastError);
      break;
    }

    xpc_object_t reply = [self send:NS3FBDonorOpCreate to:slot.connection size:length timeout:30.0];
    if (!reply) {
      self.lastError = @"un donante no respondio al pedir memoria";
      NS3FB_RAM_LOG(@"%@", self.lastError);
      break;
    }

    const char* donor_error = xpc_dictionary_get_string(reply, NS3FBDonorKeyError);
    if (donor_error) {
      self.lastError = [NSString stringWithFormat:@"el donante no pudo dar %llu MB: %s",
                                                  length / (1024 * 1024), donor_error];
      NS3FB_RAM_LOG(@"%@", self.lastError);
      break;
    }

    xpc_object_t shmem = xpc_dictionary_get_value(reply, NS3FBDonorKeyShmem);
    if (!shmem || xpc_get_type(shmem) != XPC_TYPE_SHMEM) {
      self.lastError = @"la respuesta del donante no traia memoria compartida";
      NS3FB_RAM_LOG(@"%@", self.lastError);
      break;
    }

    void* scratch = NULL;
    const size_t mapped = xpc_shmem_map(shmem, &scratch);
    if (!scratch || mapped < length) {
      self.lastError = [NSString stringWithFormat:@"xpc_shmem_map dio %zu de %llu bytes", mapped,
                                                  length];
      NS3FB_RAM_LOG(@"%@", self.lastError);
      break;
    }

    const BOOL placed = [self placeChunk:scratch
                                filebase:kGuestRamFileOffset + offset
                                  length:length
                              guestViews:views
                                   count:viewCount
                                membase:membase];

    // El mapeo temporal ya no hace falta: lo que quedo en las vistas mantiene
    // viva la misma memoria. El objeto xpc_shmem se conserva de todas formas,
    // para que la region no dependa solo de los mapeos.
    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)(uintptr_t)scratch, mapped);

    if (!placed) {
      break;
    }

    [self.keptShmems addObject:shmem];
    slot.remaining -= length;
    offset += length;
  }

  self.donatedBytes = offset;

  if (offset > 0 && self.killDonorsAfterMapping) {
    // Las paginas ya estan mapeadas en la app; matar los donantes evita que iOS
    // los mate por su cuenta cuando apriete el presupuesto, que es como se
    // quedaba el juego a medias.
    [self killDonorProcesses];
  }

  return offset;
}

- (void)killDonorProcesses {
  NSArray<NSExtension*>* extensions;
  @synchronized(self) {
    extensions = [self.extensions copy];
    [self.extensions removeAllObjects];
  }
  NS3FB_RAM_LOG(@"matando %lu donante(s) con %llu MB mapeados",
                (unsigned long)extensions.count, self.donatedBytes / (1024 * 1024));
  for (NSExtension* extension in extensions) {
    [extension _kill:SIGKILL];
  }
}

- (void)shutdown {
  NSArray<NSExtension*>* extensions;
  @synchronized(self) {
    extensions = [self.extensions copy];
    [self.extensions removeAllObjects];
    [self.connections removeAllObjects];
    [self.keptShmems removeAllObjects];
  }
  for (NSExtension* extension in extensions) {
    [extension _kill:SIGTERM];
  }
}

@end

#pragma mark - Interfaz C

static uint64_t NS3FBPhysFootprint(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
    return 0;
  }
  return (uint64_t)info.phys_footprint;
}

bool ns3fb_ram_donor_is_available(void) {
  return NS3FBRamDonor.donorBundleIdentifier != nil;
}

uint32_t ns3fb_ram_donor_start(uint32_t count, double timeout_seconds) {
  return (uint32_t)[NS3FBRamDonor.shared startDonors:count timeout:timeout_seconds];
}

uint64_t ns3fb_ram_donor_available_memory(void) {
  return [NS3FBRamDonor.sharedIfExists availableMemory];
}

uint64_t ns3fb_ram_donor_donated_bytes(void) {
  NS3FBRamDonor* donor = NS3FBRamDonor.sharedIfExists;
  return donor ? donor.donatedBytes : 0;
}

uint64_t ns3fb_ram_donor_phys_footprint(void) {
  return NS3FBPhysFootprint();
}

const char* ns3fb_ram_donor_last_error(void) {
  NSString* error = NS3FBRamDonor.sharedIfExists.lastError;
  return error ? error.UTF8String : "";
}

void ns3fb_ram_donor_set_kill_after_mapping(bool enabled) {
  NS3FBRamDonor.shared.killDonorsAfterMapping = enabled ? YES : NO;
}

uint64_t ns3fb_ram_donor_back_guest_ram(uint8_t* virtual_membase, uint64_t bytes) {
  NS3FBRamDonor* donor = NS3FBRamDonor.shared;
  const uint64_t before = NS3FBPhysFootprint();
  const uint64_t donated = [donor backGuestRam:virtual_membase bytes:bytes];
  const uint64_t after = NS3FBPhysFootprint();

  NS3FB_RAM_LOG(@"%llu MB de %llu MB respaldados por la extension; "
                 "footprint app %llu MB -> %llu MB (%+lld MB)",
                donated / (1024 * 1024), bytes / (1024 * 1024), before / (1024 * 1024),
                after / (1024 * 1024),
                (long long)((int64_t)after - (int64_t)before) / (1024 * 1024));
  return donated;
}

void ns3fb_ram_donor_shutdown(void) {
  [NS3FBRamDonor.sharedIfExists shutdown];
}
