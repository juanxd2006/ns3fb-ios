// metal-tile-resolve — banco de pruebas de un solo proposito.
//
// Mide cuanto cuesta resolver 4x MSAA de dos formas a 1280x720, con el mismo
// trabajo de rasterizado en ambas:
//
//   A) MSAA en memoria *memoryless* (nunca sale del tile) + store action
//      MTLStoreActionMultisampleResolve. Es lo que podria hacer un backend
//      Metal nativo y lo que Vulkan no puede expresar.
//   B) MSAA en memoria privada + store, y resolve con un compute shader que
//      lee los 4 samples. Es lo que hace Xenia/ReXGlue hoy (resolve_*_cs).
//
// Si A sale mucho mas rapido que B, escribir un backend Metal nativo tiene una
// razon economica. Si salen parecidos, no la tiene.
//
// Sin Mac no hay consola de Xcode, asi que el resultado se escribe en
// Documents/spike_result.txt y ademas se pinta en pantalla en tipografia
// grande, para poder leerlo en una captura.

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <dispatch/dispatch.h>

#include <cstdarg>
#include <cstdio>
#include <string>

static const int kWidth = 1280;
static const int kHeight = 720;
static const int kSampleCount = 4;
static const int kWarmupFrames = 5;
static const int kMeasuredFrames = 20;
static const int kOverdrawPasses = 4;

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

fragment float4 fs_main(VSOut in [[stage_in]]) {
  float3 base = float3(in.uv, 0.5);
  float s = 0.0;
  for (int i = 1; i <= 8; ++i) {
    s += sin(in.uv.x * float(i) * 3.7 + in.uv.y * float(i) * 1.3);
  }
  return float4(base + 0.02 * s, 1.0);
}

// Resolve manual: promedio de los 4 samples, escrito a la textura 1x.
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

@interface SpikeView : UIView
@property(nonatomic, strong) UILabel *label;
@end

@implementation SpikeView
- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = [UIColor whiteColor];
    _label = [[UILabel alloc] initWithFrame:CGRectInset(frame, 16, 16)];
    _label.numberOfLines = 0;
    _label.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightMedium];
    _label.textColor = [UIColor blackColor];
    _label.text = @"midiendo...";
    [self addSubview:_label];
  }
  return self;
}
@end

@interface SpikeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) SpikeView *view;
@end

@implementation SpikeDelegate

- (BOOL)application:(UIApplication *)app
    didFinishLaunchingWithOptions:(NSDictionary *)options {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.view = [[SpikeView alloc] initWithFrame:self.window.bounds];
  UIViewController *vc = [UIViewController new];
  vc.view = self.view;
  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];

  // Fuera del arranque para que la ventana ya este en pantalla cuando se
  // pinte el resultado.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [self run];
                 });
  return YES;
}

- (void)show:(NSString *)text {
  self.view.label.text = text;
  NSLog(@"[spike]\n%@", text);
  // Documents es visible desde la app Archivos (UIFileSharingEnabled).
  NSArray<NSString *> *dirs =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  if (dirs.count > 0) {
    NSString *path = [dirs[0] stringByAppendingPathComponent:@"spike_result.txt"];
    NSError *err = nil;
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
      NSLog(@"[spike] no se pudo escribir %@: %@", path, err);
    } else {
      NSLog(@"[spike] escrito en %@", path);
    }
  }
}

static std::string Fmt(const char *fmt, ...) {
  char buf[512];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  return std::string(buf);
}

// Devuelve el tiempo medio de GPU por frame en ms, o -1 si algo fallo.
- (double)measurePath:(BOOL)tileResolve
                queue:(id<MTLCommandQueue>)queue
               pso:(id<MTLRenderPipelineState>)pso
              cpso:(id<MTLComputePipelineState>)cpso
              msaa:(id<MTLTexture>)msaa
             depth:(id<MTLTexture>)depth
           resolved:(id<MTLTexture>)resolved
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
      rp.depthAttachment.texture = depth;
      rp.depthAttachment.loadAction = MTLLoadActionClear;
      rp.depthAttachment.clearDepth = 1.0;
      rp.depthAttachment.storeAction = MTLStoreActionDontCare;
      if (tileResolve) {
        // El MSAA nunca llega a memoria: el resolve ocurre en el tile.
        rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        rp.colorAttachments[0].resolveTexture = resolved;
      } else {
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
      }

      id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
      [enc setRenderPipelineState:pso];
      MTLViewport viewport = {0.0, 0.0, (double)kWidth, (double)kHeight, 0.0, 1.0};
      [enc setViewport:viewport];
      for (int p = 0; p < kOverdrawPasses; ++p) {
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      }
      [enc endEncoding];

      if (!tileResolve) {
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:cpso];
        [ce setTexture:msaa atIndex:0];
        [ce setTexture:resolved atIndex:1];
        MTLSize tg = MTLSizeMake(16, 16, 1);
        MTLSize grid = MTLSizeMake((kWidth + 15) / 16, (kHeight + 15) / 16, 1);
        [ce dispatchThreadgroups:grid threadsPerThreadgroup:tg];
        [ce endEncoding];
      }

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

    // Resolve target 1x, comun a los dos caminos.
    MTLTextureDescriptor *rd = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:kWidth
                                    height:kHeight
                                 mipmapped:NO];
    rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
               MTLTextureUsageShaderWrite;
    rd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> resolved = [device newTextureWithDescriptor:rd];

    // Profundidad 4x. No se guarda en ninguno de los dos caminos.
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

    // --- Camino A: MSAA memoryless + resolve en el tile -------------------
    MTLTextureDescriptor *ma = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:kWidth
                                    height:kHeight
                                 mipmapped:NO];
    ma.textureType = MTLTextureType2DMultisample;
    ma.sampleCount = kSampleCount;
    ma.usage = MTLTextureUsageRenderTarget;
    ma.storageMode = MTLStorageModeMemoryless;
    id<MTLTexture> msaaA = [device newTextureWithDescriptor:ma];
    std::string noteA;
    if (!msaaA) {
      noteA = " (memoryless no soportado, se usa privada)";
      ma.storageMode = MTLStorageModePrivate;
      msaaA = [device newTextureWithDescriptor:ma];
    }

    // --- Camino B: MSAA privada + store + compute resolve -----------------
    MTLTextureDescriptor *mb = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:kWidth
                                    height:kHeight
                                 mipmapped:NO];
    mb.textureType = MTLTextureType2DMultisample;
    mb.sampleCount = kSampleCount;
    mb.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    mb.storageMode = MTLStorageModePrivate;
    id<MTLTexture> msaaB = [device newTextureWithDescriptor:mb];

    if (!msaaA || !msaaB || !depth || !resolved) {
      [self show:@"ERROR: no se pudieron crear las texturas"];
      return;
    }

    NSString *errA = nil, *errB = nil;
    double msA = [self measurePath:YES
                             queue:queue
                               pso:pso
                              cpso:cpso
                              msaa:msaaA
                             depth:depth
                          resolved:resolved
                             error:&errA];
    double msB = [self measurePath:NO
                             queue:queue
                               pso:pso
                              cpso:cpso
                              msaa:msaaB
                             depth:depth
                          resolved:resolved
                             error:&errB];
    if (msA < 0 || msB < 0) {
      [self show:[NSString stringWithFormat:@"ERROR GPU:\nA: %@\nB: %@",
                                            errA ?: @"-", errB ?: @"-"]];
      return;
    }

    double delta = msB - msA;
    std::string out;
    out += "metal-tile-resolve\n";
    out += Fmt("device: %s\n", device.name.UTF8String);
    out += Fmt("render: %dx%d, %dx MSAA, %d frames, overdraw %d\n", kWidth, kHeight,
               kSampleCount, kMeasuredFrames, kOverdrawPasses);
    out += "\n";
    out += Fmt("A  tile resolve (memoryless + MultisampleResolve)%s: %.3f ms/frame\n",
               noteA.c_str(), msA);
    out += Fmt("B  compute resolve (store + resolve4x kernel)      : %.3f ms/frame\n", msB);
    out += Fmt("delta B-A: %.3f ms/frame\n", delta);
    out += "\n";
    if (msA > 0.0) {
      out += Fmt("B es %.1fx el coste de A\n", msB / msA);
    }
    out += "\n";
    out += delta > 5.0
               ? "VEREDICTO: el resolve por compute cuesta ms de verdad. Un backend\n"
                 "Metal nativo con tile memory tiene una razon economica para existir.\n"
               : "VEREDICTO: la diferencia es pequena a este tamano. Un backend Metal\n"
                 "nativo NO arreglaria el problema de rendimiento por si solo.\n";

    [self show:[NSString stringWithUTF8String:out.c_str()]];
  }
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([SpikeDelegate class]));
  }
}
