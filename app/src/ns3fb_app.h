// ns3fb - ReXGlue Recompiled Project
//
// Customize your app by overriding virtual hooks from rex::ReXApp.

#pragma once

#include <rex/rex_app.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#define NS3FB_IOS 1
#include <climits>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mach-o/dyld.h>
#include <rex/cvar.h>
#include <rex/cvar_defaults.h>
#include <rex/logging.h>
#else
#define NS3FB_IOS 0
#endif

class Ns3fbApp : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<Ns3fbApp>(new Ns3fbApp(ctx, "ns3fb",
        PPCImageConfig));
  }

#if NS3FB_IOS
  // Directory holding the app bundle's executable, i.e. NS3FB.app/. The game
  // data can be baked in there (scripts/inject-game-files.sh) so nothing has to
  // be copied by hand on the device.
  static std::filesystem::path BundleDir() {
    char buf[PATH_MAX];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) {
      return {};
    }
    std::error_code ec;
    const auto resolved = std::filesystem::weakly_canonical(std::filesystem::path(buf), ec);
    return ec ? std::filesystem::path(buf).parent_path() : resolved.parent_path();
  }

  // iOS launches an app with no argv, so --game_data_root/--gpu_plugin can never
  // arrive on a command line the way they do on desktop. Resolve them from the
  // app container instead: <container>/Documents is the directory the Files app
  // exposes (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace in
  // Info.plist), so that is where the extracted game is dropped.
  void OnConfigurePaths(rex::PathConfig& paths) override {
    // MoltenVK lee estas variables al crear la instancia, asi que hay que
    // fijarlas antes de que arranque el runtime. Quitan el coste de la capa de
    // validacion/diagnostico (en el log se veian avisos "{ Validation }" en
    // cada frame) y activan los modos rapidos de MoltenVK.
    //
    // No sustituye a un backend Metal nativo: solo elimina el sobrecoste de
    // traduccion que MoltenVK anade por su cuenta.
    setenv("MVK_CONFIG_LOG_LEVEL", "0", 1);
    setenv("MVK_CONFIG_PERFORMANCE_LOGGING", "0", 1);
    setenv("MVK_CONFIG_ACTIVITY_PERFORMANCE_LOGGING", "0", 1);
    setenv("MVK_CONFIG_API_LOGGING", "0", 1);
    // Rellena los command buffers de Metal antes de enviarlos (menos picos de CPU).
    setenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS", "1", 1);
    // Usa argument buffers de Metal para los descriptor sets (menos binding).
    setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "1", 1);
    // No bloquea la CPU esperando a que Metal complete cada submit.
    setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "0", 1);

    const char* home = std::getenv("HOME");
    if (!home || !home[0]) {
      return;
    }
    const std::filesystem::path documents = std::filesystem::path(home) / "Documents";

    std::error_code ec;
    std::filesystem::create_directories(documents, ec);

    // Naruto Storm 3 Full Burst is a disc title: `data/` and `datafb/` both live
    // inside the same folder as default.xex, so there is no separate update root
    // to mount. Only game_data_root matters.
    //
    // Two supported locations, in priority order:
    //   1. Documents/game  - copied over with the Files app; can be replaced or
    //                        fixed without re-signing or reinstalling.
    //   2. <bundle>/game   - baked into the .ipa by scripts/inject-game-files.sh;
    //                        readable (the bundle is read-only) but not writable.
    // Documents wins so an update dropped there overrides a stale bundle copy.
    if (paths.game_data_root.empty()) {
      const auto docs_game = documents / "game";
      const auto bundle_game = BundleDir() / "game";
      std::error_code probe;
      if (std::filesystem::exists(docs_game / "default.xex", probe)) {
        paths.game_data_root = docs_game;
      } else if (std::filesystem::exists(bundle_game / "default.xex", probe)) {
        paths.game_data_root = bundle_game;
      } else {
        paths.game_data_root = docs_game;
        std::filesystem::create_directories(paths.game_data_root, ec);
      }
    }
    // Always override: ReXApp has already defaulted this to GetUserFolder()/ns3fb,
    // i.e. $HOME/.local/share/ns3fb, which is inside the container but invisible
    // to the Files app - and on device it fails to open for writing.
    paths.user_data_root = documents / "userdata";
    std::filesystem::create_directories(paths.user_data_root, ec);

    // Same reason: ReXApp derives cache_root from the pre-override user dir, so
    // it still points at $HOME/.local/share/ns3fb/cache, which the sandbox
    // refuses to create. Everything writable has to live under Documents.
    paths.cache_root = documents / "cache";
    std::filesystem::create_directories(paths.cache_root, ec);

    // Keep the editable config next to the game data rather than inside the
    // (read-only, signed) bundle, so settings can be changed without a rebuild.
    paths.config_path = documents / "ns3fb.toml";

    if (!std::filesystem::exists(paths.config_path)) {
      std::ofstream out(paths.config_path);
      if (out) {
        out << "# ns3fb settings. Edit via the Files app; takes effect on relaunch.\n"
               "# The Xenos GPU emulation renders through Vulkan (MoltenVK on iOS);\n"
               "# leaving this empty disables graphics entirely.\n"
               "gpu_plugin = \"xenos\"\n"
               "\n"
               "# Bit 0 = title is purchased rather than a trial.\n"
               "license_mask = 1\n"
               "\n"
               "# The guest output is 16:9 and the panel is ~19.5:9.\n"
               "#   present_letterbox = false -> stretch to fill (no bars, slight distortion)\n"
               "#   present_letterbox = true  -> keep aspect, pillars down the sides\n"
               "present_letterbox = false\n"
               "\n"
               "# Render target path: \"fbo\" uses host render targets (hardware MSAA\n"
               "# coverage and blending). \"fsi\" emulates the EDRAM in the pixel shader -\n"
               "# more accurate on paper, but much slower here, and MoltenVK does not\n"
               "# report sample 0 coverage, which corrupts every other pixel.\n"
               "render_target_path_vulkan = \"fbo\"\n"
               "\n"
               "# Metal has no fragment-input coverage mask, so MoltenVK's\n"
               "# gl_SampleMaskIn never reports sample 0. Derive it from gl_SampleID.\n"
               "fsi_sample_mask_from_sample_id = true\n"
               "\n"
               "# Storm 3 is frame-locked at 30 on the console; at 60 the game logic\n"
               "# simply runs twice as fast. 30 keeps frames evenly paced.\n"
               "framerate_limit = 30\n"
               "\n"
               "# On-screen gamepad: \"auto\" shows it while no controller is connected,\n"
               "# \"on\" always, \"off\" never. touch_controls_opacity (0.1 to 1.0) dims it.\n"
               "touch_controls = \"auto\"\n";
      }
    }

    // This app's defaults, in place of the SDK's. SetDefaultByName ranks below
    // the config file, so ns3fb.toml can still change every one of them, and
    // it reaches settings owned by the GPU plugin, which only loads after this
    // hook - SetFlagByName rejects those, silently dropping the defaults below
    // whenever ns3fb.toml does not repeat them.

    // The Xenos GPU emulation; empty would disable graphics entirely.
    rex::cvar::SetDefaultByName("gpu_plugin", "xenos");
    rex::cvar::SetDefaultByName("license_mask", "1");
    rex::cvar::SetDefaultByName("present_letterbox", "false");
    rex::cvar::SetDefaultByName("fsi_sample_mask_from_sample_id", "true");
    rex::cvar::SetDefaultByName("render_target_path_vulkan", "fbo");

    // Performance.
    //
    // clear_memory_page_state marks every uploaded page stale at the end of each
    // frame, so all loaded textures were re-copied to the GPU every frame and the
    // CPU spent half its time waiting. Upstream Xenia defaults it off; it only
    // matters for titles that depend on GPU-written memory.
    rex::cvar::SetDefaultByName("clear_memory_page_state", "false");
    // Ending the submission at every PM4 primary buffer end cost a vkQueueSubmit
    // plus fence per buffer; once per frame is enough here.
    rex::cvar::SetDefaultByName("vulkan_submit_on_primary_buffer_end", "false");
    // FIFO only: vsync-locked, evenly paced frames capped at the panel refresh.
    rex::cvar::SetDefaultByName("vulkan_allow_present_mode_immediate", "false");
    rex::cvar::SetDefaultByName("vulkan_allow_present_mode_mailbox", "false");
    rex::cvar::SetDefaultByName("vulkan_allow_present_mode_fifo_relaxed", "false");
    rex::cvar::SetDefaultByName("framerate_limit", "30");
    // Background shader compiling skips any draw whose pipeline isn't ready.
    // Normal frames hide that; one-off passes (saves, UI transitions) do not and
    // come out blank.
    rex::cvar::SetDefaultByName("async_shader_compilation", "false");
    // Work out how far a screen-space draw (clears drawn with Direct3D's
    // unbounded 8192x8192 scissor) really reaches by running its vertex shader on
    // the CPU, as Xenia does by default. Without it, depth-only clears were
    // assumed to cover the whole EDRAM, wrapping over the colour image.
    rex::cvar::SetDefaultByName("execute_unclipped_draw_vs_on_cpu", "true");
    // 16 queued audio frames (~85 ms) ride out scheduling hiccups on a busy or
    // warm phone; 8 ran dry, heard as choppy sound.
    rex::cvar::SetDefaultByName("audio_maxqframes", "16");

    // Rendimiento (perfil medido en iPhone 11 / A13, ~15 fps en el menu antes).
    //
    // Anisotropico a 3x por defecto: cuesta ancho de banda y a 720p no se nota.
    rex::cvar::SetDefaultByName("anisotropic_override", "0");
    // Metal no tiene geometry shaders, asi que los point sprites (chispas,
    // humo, particulas de los jutsus) se expandian por la ruta lenta de
    // primitivas. Expandirlos en el vertex shader es mucho mas barato.
    rex::cvar::SetDefaultByName("vulkan_force_expand_point_sprites_in_vs", "true");
    // Con true, un draw cuyo pipeline aun no esta compilado se salta en vez de
    // bloquear el frame. Cuesta algun efecto en el primer instante.
    rex::cvar::SetDefaultByName("async_shader_compilation", "true");

    REXLOG_INFO("iOS paths: game={} config={}", paths.game_data_root.string(),
                paths.config_path.string());
  }
#endif
};
