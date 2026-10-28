// metal-720p — banco de decision: ¿llega un backend Metal nativo a 720p30?
//
// No renderiza el juego. Modela el frame del port con los costes ya medidos en
// dispositivo (docs/PERF_MATRIX.md, docs/METAL_BACKEND.md) y mide en ESTE movil
// la unica componente que un backend Metal cambiaria: el coste del resolve.
//
// Frame del port a 1280x720 en A13 (medido, escena de seleccion):
//     compute (resolves)  30,34 ms   44 %   <- lo que mide este banco
//     fragment            25,54 ms   37 %   <- "OTROS", no depende do backend
//     blit                 5,51 ms    8 %   <- "OTROS"
//     vertex               3,14 ms    5 %   <- "OTROS"
//     total               63,07 ms
// De ahi salen ~25 resolves de 720p por frame (30,34 / 1,21).
//
// El banco mide cuatro cosas y proyecta:
//   1. p_priv   pasada 4x MSAA en memoria privada, sin resolve  (hoy)
//   2. p_mem    pasada 4x MSAA en memoria memoryless, sin resolve
//   3. r_c      ms por copia con el kernel compute (hoy)
//   4. r_t      ms por copia con MultisampleResolve en el tile
//
// Con eso se proyecta el frame. Ojo a como: el resolve del port no es el de
// este banco (el del port convierte formato y encadena targets), asi que lo que
// se transfiere es la PROPORCION tile/compute, anclada en el coste real por
// copia del port:
//
//   portPorCopia = 30,34 / 25 = 1,2136 ms
//   baseline = OTROS + 25 * portPorCopia        (debe rondar los 63,07 medidos)
//   tile     = OTROS + 25 * portPorCopia * prop
//   directo  = OTROS +  1 * portPorCopia        (resolve directo)
//   dir+tile = OTROS +  1 * portPorCopia * prop (lo mejor que puede dar Metal)
//
// Presupuesto: 30 fps = 33,33 ms/frame · 60 fps = 16,67 ms/frame.
//
// El resultado se escribe en Documents/spike_metal_720p.txt y se pinta en
// pantalla, porque sin Mac no hay consola de Xcode.

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <dispatch/dispatch.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <string>

// --- Escenario ---------------------------------------------------------------
static const int kWidth = 1280;
static const int kHeight = 720;
static const int kSampleCount = 4;
static const int kOverdrawPasses = 4;
static const int kWarmupFrames = 5;
static const int kMeasuredFrames = 20;
// Resolves por frame que se lanzan de golpe para medir el coste de una copia.
// No hacen falta 25 texturas distintas: el MSAA de 720p 4x son 14,7 MB, asi que
// cada dispatch ya sale de cache y paga el ancho de banda real.
static const int kResolvesPerSample = 8;

// --- Constantes medidas en el port (A13, 1280x720) ---------------------------
static const double kPortOtherMs = 34.19;      // fragment + blit + vertex
static const double kPortResolveMs = 30.34;    // componente de resolves
static const double kPortFrameMs = 63.07;      // total medido
static const int kPortResolvesPerFrame = 25;   // 30,34 / 1,21

static const double kBudget30 = 1000.0 / 30.0;
static const double kBudget60 = 1000.0 / 60.0;

static NSString *const kShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VSOut {
  float4 position [[position]];
  float2 uv;
};

vertex VSOut vs_main(uint vid [[vertex_id]]) {
  float2 p = float2(float((vid << 1) & 2), float(vid & 2));
  VSOut o;
  o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
  o.uv = p;
  return o;
}

// Carga de ALU y de escritura parecida a la de un pixel shader del juego: no
// pretende ser el juego, solo impedir que el coste lo domine el rasterizador.
fragment float4 fs_main(VSOut in [[stage_in]]) {
  float3 base = float3(in.uv, 0.5);
  float s = 0.0;
  for (int i = 1; i <= 8; ++i) {
    s += sin(in.uv.x * float(i) * 3.7 + in.uv.y * float(i) * 1.3);
  }
  return float4(base + 0.02 * s, 1.0);
}

// Resolve manual de 4 samples: lo que hace hoy resolve_*_cs en el backend
// Vulkan. Lee 4x y escribe 1x, todo por memoria.
kernel void resolve4x(texture2d_ms<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
    return;
  }
  float4 acc = float4(0.0);
  for (uint s = 0; s < 4; ++s) {
    acc += src.read(gid, s);
  }
  dst.write(acc * 0.25, gid);
}
)MSL";

// -----------------------------------------------------------------------------

@interface BudgetView : UIView
@property(nonatomic, strong) UILabel *label;
@end

@implementation BudgetView
- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = [UIColor whiteColor];
    _label = [[UILabel alloc] initWithFrame:CGRectInset(frame, 12, 24)];
    _label.numberOfLines = 0;
    _label.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    _label.textColor = [UIColor blackColor];
    _label.text = @"midiendo...";
    [self addSubview:_label];
  }
  return self;
}
@end

@interface BudgetDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) BudgetView *view;
@end

@implementation BudgetDelegate

- (BOOL)application:(UIApplication *)app
    didFinishLaunchingWithOptions:(NSDictionary *)options {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.view = [[BudgetView alloc] initWithFrame:self.window.bounds];
  UIViewController *vc = [UIViewController new];
  vc.view = self.view;
  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [self run];
                 });
  return YES;
}

- (void)show:(NSString *)text {
  self.view.label.text = text;
  NSLog(@"[metal-720p]\n%@", text);
  NSArray<NSString *> *dirs =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  if (dirs.count > 0) {
    NSString *path = [dirs[0] stringByAppendingPathComponent:@"spike_metal_720p.txt"];
    NSError *err = nil;
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
      NSLog(@"[metal-720p] no se pudo escribir %@: %@", path, err);
    } else {
      NSLog(@"[metal-720p] escrito en %@", path);
    }
  }
}

static std::string Fmt(const char *fmt, ...) {
  char buf[1024];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  return std::string(buf);
}

// Una pasada de geometria a pantalla completa, kOverdrawPasses veces.
// storeAction/resolveTexture deciden si el MSAA se resuelve en el tile (A),
// se guarda a memoria (B) o no se guarda (medida de la pasada sola).
- (double)measurePassWithMsaa:(id<MTLTexture>)msaa
                       depth:(id<MTLTexture>)depth
                 storeAction:(MTLStoreAction)storeAction
              resolveTexture:(id<MTLTexture>)resolveTexture
                       queue:(id<MTLCommandQueue>)queue
                         pso:(id<MTLRenderPipelineState>)pso
                       error:(NSString **)errorOut {
  double total = 0.0;
  int frames = 0;
  for (int i = 0; i < kWarmupFrames + kMeasuredFrames; ++i) {
    @autoreleasepool {
      id<MTLCommandBuffer> cb = [queue commandBuffer];

      MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
      rp.colorAttachments[0].texture = msaa;
      rp.colorAttachments[0].loadAction = MTLLoadActionClear;
      rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.15, 1.0);
      rp.colorAttachments[0].storeAction = storeAction;
      if (resolveTexture) {
        rp.colorAttachments[0].resolveTexture = resolveTexture;
      }
      rp.depthAttachment.texture = depth;
      rp.depthAttachment.loadAction = MTLLoadActionClear;
      rp.depthAttachment.clearDepth = 1.0;
      rp.depthAttachment.storeAction = MTLStoreActionDontCare;

      id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
      [enc setRenderPipelineState:pso];
      MTLViewport viewport = {0.0, 0.0, (double)kWidth, (double)kHeight, 0.0, 1.0};
      [enc setViewport:viewport];
      for (int p = 0; p < kOverdrawPasses; ++p) {
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      }
      [enc endEncoding];

      [cb commit];
      [cb waitUntilCompleted];
      if (cb.status == MTLCommandBufferStatusError) {
        if (errorOut) {
          *errorOut = cb.error ? cb.error.localizedDescription : @"error desconocido";
        }
        return -1.0;
      }
      if (i >= kWarmupFrames) {
        total += (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
        ++frames;
      }
    }
  }
  return frames > 0 ? total / double(frames) : -1.0;
}

// kResolvesPerSample resolves por frame con el kernel compute (camino actual).
// Devuelve los ms POR COPIA.
- (double)measureComputeResolveMsaa:(id<MTLTexture>)msaa
                            resolved:(id<MTLTexture>)resolved
                               queue:(id<MTLCommandQueue>)queue
                                cpso:(id<MTLComputePipelineState>)cpso
                               error:(NSString **)errorOut {
  double total = 0.0;
  int frames = 0;
  for (int i = 0; i < kWarmupFrames + kMeasuredFrames; ++i) {
    @autoreleasepool {
      id<MTLCommandBuffer> cb = [queue commandBuffer];
      id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
      [ce setComputePipelineState:cpso];
      [ce setTexture:msaa atIndex:0];
      [ce setTexture:resolved atIndex:1];
      MTLSize tg = MTLSizeMake(16, 16, 1);
      MTLSize grid = MTLSizeMake((kWidth + 15) / 16, (kHeight + 15) / 16, 1);
      for (int r = 0; r < kResolvesPerSample; ++r) {
        [ce dispatchThreadgroups:grid threadsPerThreadgroup:tg];
      }
      [ce endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      if (cb.status == MTLCommandBufferStatusError) {
        if (errorOut) {
          *errorOut = cb.error ? cb.error.localizedDescription : @"error desconocido";
        }
        return -1.0;
      }
      if (i >= kWarmupFrames) {
        total += (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
        ++frames;
      }
    }
  }
  if (frames <= 0) {
    return -1.0;
  }
  return (total / double(frames)) / double(kResolvesPerSample);
}

- (void)run {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
      [self show:@"ERROR: no hay dispositivo Metal"];
      return;
    }
    if (![device supportsTextureSampleCount:kSampleCount]) {
      [self show:@"ERROR: este dispositivo no soporta 4x MSAA"];
      return;
    }

    NSError *err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:kShaderSource options:nil error:&err];
    if (!lib) {
      [self show:[NSString stringWithFormat:@"ERROR compilando MSL: %@",
                                            err.localizedDescription]];
      return;
    }

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs_main"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs_main"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.rasterSampleCount = kSampleCount;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd
                                                                            error:&err];
    if (!pso) {
      [self show:[NSString stringWithFormat:@"ERROR pipeline: %@", err.localizedDescription]];
      return;
    }

    id<MTLComputePipelineState> cpso =
        [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"resolve4x"]
                                              error:&err];
    if (!cpso) {
      [self show:[NSString stringWithFormat:@"ERROR compute: %@", err.localizedDescription]];
      return;
    }

    id<MTLCommandQueue> queue = [device newCommandQueue];

    // Target resuelto 1x, comun a todos los caminos.
    MTLTextureDescriptor *rd = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:kWidth
                                    height:kHeight
                                 mipmapped:NO];
    rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
               MTLTextureUsageShaderWrite;
    rd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> resolved = [device newTextureWithDescriptor:rd];

    // Profundidad 4x memoryless: en ningun camino se guarda.
    MTLTextureDescriptor *dd = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                     width:kWidth
                                    height:kHeight
                                 mipmapped:NO];
    dd.textureType = MTLTextureType2DMultisample;
    dd.sampleCount = kSampleCount;
    dd.usage = MTLTextureUsageRenderTarget;
    dd.storageMode = MTLStorageModeMemoryless;
    id<MTLTexture> depth = [device newTextureWithDescriptor:dd];

    // MSAA en memoria memoryless (lo que permitiria un backend nativo).
    MTLTextureDescriptor *mm = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:kWidth
                                    height:kHeight
                                 mipmapped:NO];
    mm.textureType = MTLTextureType2DMultisample;
    mm.sampleCount = kSampleCount;
    mm.usage = MTLTextureUsageRenderTarget;
    mm.storageMode = MTLStorageModeMemoryless;
    id<MTLTexture> msaaMem = [device newTextureWithDescriptor:mm];
    std::string noteMem;
    if (!msaaMem) {
      noteMem = " (memoryless no soportado: se usa privada)";
      mm.storageMode = MTLStorageModePrivate;
      mm.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      msaaMem = [device newTextureWithDescriptor:mm];
    }

    // MSAA en memoria privada (lo que hace hoy el backend Vulkan).
    MTLTextureDescriptor *mp = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:kWidth
                                    height:kHeight
                                 mipmapped:NO];
    mp.textureType = MTLTextureType2DMultisample;
    mp.sampleCount = kSampleCount;
    mp.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    mp.storageMode = MTLStorageModePrivate;
    id<MTLTexture> msaaPriv = [device newTextureWithDescriptor:mp];

    if (!depth || !msaaMem || !msaaPriv || !resolved) {
      [self show:@"ERROR: no se pudieron crear las texturas"];
      return;
    }

    NSString *ePassPriv = nil, *ePassMem = nil, *eTile = nil, *eCompute = nil;

    // 1. Pasada sola con MSAA privada y sin guardar.
    double pPriv = [self measurePassWithMsaa:msaaPriv
                                       depth:depth
                                 storeAction:MTLStoreActionDontCare
                              resolveTexture:nil
                                       queue:queue
                                         pso:pso
                                       error:&ePassPriv];

    // 2. Pasada sola con MSAA memoryless y sin guardar.
    double pMem = [self measurePassWithMsaa:msaaMem
                                      depth:depth
                                storeAction:MTLStoreActionDontCare
                             resolveTexture:nil
                                      queue:queue
                                        pso:pso
                                      error:&ePassMem];

    // 3. Resolve en el tile: misma pasada + MultisampleResolve.
    double pTile = [self measurePassWithMsaa:msaaMem
                                       depth:depth
                                 storeAction:MTLStoreActionMultisampleResolve
                              resolveTexture:resolved
                                       queue:queue
                                         pso:pso
                                       error:&eTile];

    // 4. Resolve por compute.
    double rCompute = [self measureComputeResolveMsaa:msaaPriv
                                             resolved:resolved
                                                queue:queue
                                                 cpso:cpso
                                                error:&eCompute];

    if (pPriv < 0 || pMem < 0 || pTile < 0 || rCompute < 0) {
      [self show:[NSString stringWithFormat:
                              @"ERROR GPU:\nprivada: %@\nmemoryless: %@\ntile: %@\ncompute: %@",
                              ePassPriv ?: @"-", ePassMem ?: @"-", eTile ?: @"-",
                              eCompute ?: @"-"]];
      return;
    }

    // Coste de UNA copia en el tile = (pasada + resolve) - (pasada sola).
    double rTile = std::max(0.0, pTile - pMem);

    // --- Proyeccion del frame ------------------------------------------------
    //
    // Este banco NO reproduce el resolve del port: el del port convierte formato,
    // hace downscale y encadena varios targets. Lo que SI es transferible es la
    // PROPORCION tile/compute, porque es la misma operacion hecha por un camino
    // mas barato. Asi que la proyeccion se ancla en el coste por copia medido en
    // el port (30,34 ms / 25 copias) y se le aplica esa proporcion.
    const double n = double(kPortResolvesPerFrame);
    const double portPerCopy = kPortResolveMs / n;              // 1,2136 ms
    const double ratioTile = (rCompute > 0.0) ? (rTile / rCompute) : 1.0;
    const double portTilePerCopy = portPerCopy * ratioTile;

    // Si el fill con memoryless sale mas barato, el fragment tambien se encoge.
    // Solo se descuenta el fragment, que es lo unico ligado al ancho de banda.
    const double kOtherFragmentMs = 25.54;
    const double kOtherFixedMs = 5.51 + 3.14;                   // blit + vertex
    const double fillFactor = (pPriv > 0.0) ? (pMem / pPriv) : 1.0;
    const double otherFixed = kPortOtherMs;
    const double otherMemoryless =
        kOtherFixedMs + kOtherFragmentMs * std::min(1.0, fillFactor);

    const double fBaseline = otherFixed + n * portPerCopy;
    const double fTile = otherFixed + n * portTilePerCopy;
    const double fDirect = otherFixed + 1.0 * portPerCopy;
    const double fDirectTile = otherFixed + 1.0 * portTilePerCopy;
    const double fDirectTileMem = otherMemoryless + 1.0 * portTilePerCopy;

    std::string out;
    out += "metal-720p — presupuesto de frame\n";
    out += Fmt("device: %s\n", device.name.UTF8String);
    out += Fmt("render: %dx%d, %dx MSAA, overdraw %d, %d frames medidos\n", kWidth, kHeight,
               kSampleCount, kOverdrawPasses, kMeasuredFrames);
    out += Fmt("presupuesto: 30 fps = %.2f ms · 60 fps = %.2f ms\n", kBudget30, kBudget60);
    out += "\n-- medido en este movil --\n";
    out += Fmt("pasada 4x MSAA, memoria privada, sin guardar : %7.3f ms\n", pPriv);
    out += Fmt("pasada 4x MSAA, memoryless, sin guardar%s: %7.3f ms\n",
               noteMem.c_str(), pMem);
    out += Fmt("UNA copia, compute (camino actual)          : %7.3f ms\n", rCompute);
    out += Fmt("UNA copia, tile (MultisampleResolve)          : %7.3f ms\n", rTile);
    out += Fmt("  -> proporcion tile/compute: %.2fx  (lo transferible)\n", ratioTile);
    if (pPriv > 0.0) {
      out += Fmt("  -> memoryless en el fill: %+.1f %% de la pasada\n",
                 (fillFactor - 1.0) * 100.0);
    }
    out += "\n-- frame proyectado a 720p --\n";
    out += Fmt("coste por copia del port (30,34 / 25)        : %7.3f ms\n", portPerCopy);
    out += Fmt("OTROS (fragment+blit+vertex, medido)          : %7.2f ms\n", otherFixed);
    out += Fmt("baseline  OTROS + 25 * port                   : %7.2f ms  (%5.1f fps)\n",
               fBaseline, 1000.0 / fBaseline);
    out += Fmt("tile      OTROS + 25 * port * proporcion      : %7.2f ms  (%5.1f fps)\n",
               fTile, 1000.0 / fTile);
    out += Fmt("directo   OTROS +  1 * port                   : %7.2f ms  (%5.1f fps)\n",
               fDirect, 1000.0 / fDirect);
    out += Fmt("dir+tile  OTROS +  1 * port * proporcion      : %7.2f ms  (%5.1f fps)\n",
               fDirectTile, 1000.0 / fDirectTile);
    out += Fmt("dir+tile  idem, con fill memoryless           : %7.2f ms  (%5.1f fps)\n",
               fDirectTileMem, 1000.0 / fDirectTileMem);
    out += Fmt("\ncontrol del modelo: baseline proyectado %.2f vs %.2f medidos en el port\n",
               fBaseline, kPortFrameMs);
    out += "\n-- veredicto --\n";

    const double best = std::min(fDirectTile, fDirectTileMem);
    if (best <= kBudget30) {
      out += "720p30 SI es alcanzable en este movil. Merece la pena el backend Metal.\n";
    } else if (otherFixed >= kBudget30) {
      out += "720p30 NO es alcanzable en este movil, y no por el resolve: solo el fill\n";
      out += "mas blit y vertex ya pasa de 33,33 ms. Ni un backend Metal perfecto lo\n";
      out += "arregla salvo que el fill memoryless ahorre de verdad. Objetivo: 540p30.\n";
    } else if (best <= kBudget30 * 1.15) {
      out += "720p30 esta en el limite: el mejor caso se queda a menos del 15 % del\n";
      out += "presupuesto. Un movil mas nuevo lo pasa; este depende del margen.\n";
    } else {
      out += "720p30 NO sale con este movil. El resolve directo ayuda pero el frame\n";
      out += "sigue por encima de 33,33 ms.\n";
    }
    out += Fmt("\n60 fps a 720p: NO con esta arquitectura (solo OTROS son %.2f ms).\n",
               otherFixed);

    [self show:[NSString stringWithUTF8String:out.c_str()]];
  }
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([BudgetDelegate class]));
  }
}
