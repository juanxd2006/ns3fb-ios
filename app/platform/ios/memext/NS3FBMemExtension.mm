// ns3fb-mem: extension que presta memoria al app por XPC shared memory.
//
// NO SE COMPILA (ver README.md y docs/RAM_EXTENSION_PLAN.md).
//
// Idea: el app pide "N MB", la extension crea la region con xpc_shmem_create(),
// la retiene en su proceso y devuelve el descriptor por la respuesta de la
// peticion; el app la mapea con xpc_shmem_map() y la usa como backing de la
// memoria del invitado. Las paginas quedan contadas en el proceso de la
// extension, que es lo que sube el techo conjunto.
//
// Puntos que hay que resolver antes de activarlo (documentados en el plan):
//  - xpc_shmem_create/map son API no publica: comprobar que existen en el SDK
//    de iOS que use el build y que el enlazado resuelve.
//  - La extension debe seguir viva mientras el juego corre; iOS la puede matar
//    y hay que poder reinstanciarla sin corromper la memoria del invitado.
//  - Firma: el .appex necesita su propio perfil; con Apple ID gratis y
//    Sideloadly hay que comprobar que la firma anidada se aplica.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <xpc/xpc.h>
#include <xpc/shmem.h>

@interface NS3FBMemExtension : NSObject <NSExtensionRequestHandling>
@end

@implementation NS3FBMemExtension

- (void)beginRequestWithExtensionContext:(NSExtensionContext*)context {
  // Tamano pedido: el app lo manda en NSExtensionItem.attachments como texto.
  size_t requested = 512u * 1024u * 1024u;
  for (NSExtensionItem* item in context.inputItems) {
    for (NSItemProvider* provider in item.attachments) {
      if ([provider hasItemConformingToTypeIdentifier:@"public.plain-text"]) {
        [provider loadItemForTypeIdentifier:@"public.plain-text"
                                   options:nil
                         completionHandler:^(id<NSSecureCoding> obj, NSError* err) {
                           if ([obj isKindOfClass:[NSString class]]) {
                             requested = (size_t)[(NSString*)obj longLongValue];
                           }
                         }];
      }
    }
  }

  // La region vive en ESTE proceso.
  xpc_object_t shmem = xpc_shmem_create(NULL, requested);
  if (!shmem) {
    NSError* error = [NSError errorWithDomain:@"ns3fb.mem" code:1 userInfo:nil];
    [context cancelRequestWithError:error];
    return;
  }
  // TODO: entregar el descriptor al app y mantener la region viva; ver el plan.
  (void)shmem;

  [context completeRequestReturningItems:@[] completionHandler:nil];
}

@end
