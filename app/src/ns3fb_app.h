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
#include <algorithm>
#include <cctype>
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
    // Copiado del preset cap60 de Skate 3 iOS (que expone este ajuste como
    // cvar propio): presentar con el mismo command buffer del submit evita
    // crear uno adicional por frame en MoltenVK.
    // MoltenVK lee la variable al crear la instancia, asi que debe fijarse
    // antes de que arranque el runtime.
    setenv("MVK_CONFIG_PRESENT_WITH_COMMAND_BUFFER", "1", 1);

    // iOS rechaza cualquier envio a la GPU mientras la app esta en segundo
    // plano (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted),
    // MoltenVK pierde el VkDevice y la imagen queda negra para siempre. Con
    // esto MoltenVK recrea el dispositivo al volver a primer plano en vez de
    // quedarse muerto.
    setenv("MVK_CONFIG_RESUME_LOST_DEVICE", "1", 1);

    // Envios asincronos a la cola de MoltenVK. Por defecto MoltenVK codifica
    // dentro de vkQueueSubmit, con el lock de la cola tomado: medido en un port
    // hermano (NFSMW, mismo SDK y mismo MoltenVK), cada vkQueueSubmit de UI
    // gastaba 12-17 ms y el command processor esperaba 7-8 ms por frame.
    // Asincrono, la codificacion ocurre en su propia cola de dispatch.
    // El marcador mvk_async_submit.txt fija lo mismo, y Documents/mvk.txt puede
    // volver a 1 para comparar.
    setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "0", 1);

    // Ajustes de MoltenVK desde un archivo editable en la app Archivos, para
    // poder hacer A/B de cada opcion sin recompilar:
    //   Documents/mvk.txt  ->  lineas "MVK_CONFIG_XXX=valor"
    // Se aplica todo antes de crear la instancia (MoltenVK lee las variables
    // una sola vez, al inicializarse).
    {
      const char* home_env = std::getenv("HOME");
      if (home_env && *home_env) {
        // Marcadores vacios: basta duplicar un archivo en la app Archivos y
        // renombrarlo. Evita tener que editar texto desde el iPhone.
        struct MvkFlag {
          const char* file;
          const char* key;
          const char* value;
        };
        static constexpr MvkFlag kMvkFlags[] = {
            {"mvk_argument_buffers.txt", "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "1"},
            {"mvk_prefill.txt", "MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS", "1"},
            {"mvk_async_submit.txt", "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "0"},
            {"mvk_mtlheap.txt", "MVK_CONFIG_USE_MTLHEAP", "1"},
            {"mvk_max3_cmdbuf.txt", "MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE", "3"},
            {"mvk_fast_math.txt", "MVK_CONFIG_FAST_MATH", "1"},
            // Medicion: MoltenVK escribe por frame el tiempo de CPU y de GPU.
            // Es el dato que separa "limitado por GPU" de "limitado por CPU".
            {"mvk_perf_log.txt", "MVK_CONFIG_PERFORMANCE_LOGGING", "1"},
            {"mvk_log_info.txt", "MVK_CONFIG_LOG_LEVEL", "1"},
        };
        for (const auto& flag : kMvkFlags) {
          std::error_code flag_ec;
          if (std::filesystem::exists(
                  std::filesystem::path(home_env) / "Documents" / flag.file, flag_ec)) {
            setenv(flag.key, flag.value, 1);
            REXLOG_INFO("MoltenVK override (marker {}): {}={}", flag.file, flag.key, flag.value);
          }
        }

        const std::filesystem::path mvk_path =
            std::filesystem::path(home_env) / "Documents" / "mvk.txt";
        std::ifstream mvk_file(mvk_path);
        std::string line;
        while (std::getline(mvk_file, line)) {
          const auto hash = line.find('#');
          if (hash != std::string::npos) {
            line.erase(hash);
          }
          const auto eq = line.find('=');
          if (eq == std::string::npos) {
            continue;
          }
          std::string key = line.substr(0, eq);
          std::string value = line.substr(eq + 1);
          const auto trim = [](std::string& v) {
            const auto not_space = [](int c) { return !std::isspace(c); };
            v.erase(v.begin(), std::find_if(v.begin(), v.end(), not_space));
            v.erase(std::find_if(v.rbegin(), v.rend(), not_space).base(), v.end());
          };
          trim(key);
          trim(value);
          if (key.rfind("MVK_CONFIG_", 0) == 0 && !value.empty()) {
            setenv(key.c_str(), value.c_str(), 1);
            REXLOG_INFO("MoltenVK override from mvk.txt: {}={}", key, value);
          }
        }
      }
    }

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
    // Diagnostico del 3D negro, EN CURSO: este atajo resuelve del render target
    // del host a memoria del invitado sin volcar antes los render targets a la
    // EDRAM, y en este port (Vulkan -> MoltenVK -> Metal) hay algo en ese camino
    // que no entrega el contenido.
    //
    // Medido en dispositivo con el atajo DESACTIVADO: el modo Practica se ve
    // completo (~29 fps). El modo VS Battle SIGUE NEGRO, asi que este atajo no
    // es la causa raiz del VS: o hay una segunda causa, o el VS usa otro camino.
    // Se deja en false porque con true el Practica salia negro y no cuesta fps.
    //
    // Para retomarlo: comparar los logs de Practica y de VS Battle con la
    // instrumentacion NS3FB-RANGE / NS3FB-TEX / NS3FB-MEM (after=submit) y ver
    // en que se diferencian. NO volver a poner true sin comprobar que
    // NS3FB-RES-SUM.direct_ok sube y la imagen se mantiene.
    rex::cvar::SetDefaultByName("direct_host_resolve", "false");
    // 16 queued audio frames (~85 ms) ride out scheduling hiccups on a busy or
    // warm phone; 8 ran dry, heard as choppy sound.
    rex::cvar::SetDefaultByName("audio_maxqframes", "16");

    // Resolucion interna 960x540 en vez de 1280x720. Medido en iPhone 11 / A13
    // con el Metal HUD, mismo escenario de menu:
    //   1280x720 -> 61,09 ms de GPU, 15,75 fps
    //    960x540 -> 22,65-29,38 ms, 27,57-28,33 fps, imagen correcta
    // Son 0,56x pixeles pero la GPU baja mas de la mitad, porque el coste del
    // resolve de MSAA y del trafico de EDRAM no escala linealmente. El
    // presenter escala a la pantalla del telefono; ns3fb.toml puede subirlo
    // por encima si el dispositivo tiene margen.
    //
    // NO bajar el MSAA para ganar rendimiento: se probo (msaa_override = 2) y
    // corrompe la imagen, porque la EDRAM emulada esta atada al layout de 4x
    // del invitado. Ver docs/PERF_MATRIX.md.
    rex::cvar::SetDefaultByName("video_mode_width", "960");
    rex::cvar::SetDefaultByName("video_mode_height", "540");

    // Rendimiento (perfil medido en iPhone 11 / A13, ~15 fps en el menu antes).
    //
    // Anisotropico a 3x por defecto: cuesta ancho de banda y a 720p no se nota.
    rex::cvar::SetDefaultByName("anisotropic_override", "0");
    // Estimar la altura real del render target tambien en draws con scissor.
    //
    // Aqui la CPU esta ociosa (6,5 ms por frame) y la GPU es el cuello de
    // botella: el 51 % del frame a 720p son los compute shaders que vuelcan
    // EDRAM, y su tamano sale del rango que reclama cada pase. Con esto se
    // estima el alcance real del draw (gastando CPU, que sobra) y el volcado
    // cubre menos tiles. El propio SDK avisa de que puede procesar mas vertices
    // en la CPU: es exactamente el intercambio que interesa aqui.
    rex::cvar::SetDefaultByName("execute_unclipped_draw_vs_on_cpu_with_scissor", "true");
    // Metal no tiene geometry shaders, asi que los point sprites (chispas,
    // humo, particulas de los jutsus) se expandian por la ruta lenta de
    // primitivas. Expandirlos en el vertex shader es mucho mas barato.
    rex::cvar::SetDefaultByName("vulkan_force_expand_point_sprites_in_vs", "true");
    // async_shader_compilation: DELIBERADAMENTE no se vuelve a fijar aqui.
    //
    // Habia un segundo SetDefaultByName("async_shader_compilation", "true")
    // justo en este punto, que ganaba al de arriba y dejaba el valor efectivo
    // en true, contradiciendo el README y el comentario de la primera
    // definicion. Con true, un frame que usa un pipeline de relleno no se
    // presenta: en el log aparece literalmente
    //   "Skipping Vulkan frame presentation due to async placeholder draw
    //    usage in this frame"
    // y esa era la pantalla negra. El valor por defecto queda en "false"
    // (definido arriba). Para volver a probarlo sin recompilar, crear
    // Documents/async_on.txt en la app Archivos.

    REXLOG_INFO("iOS paths: game={} config={}", paths.game_data_root.string(),
                paths.config_path.string());
  }

  // Los marcadores se aplican AQUI y no en OnConfigurePaths.
  //
  // Casi todos apuntan a cvars que define el plugin de GPU
  // (async_shader_compilation, render_target_path_vulkan,
  // vulkan_async_skip_incomplete_frames, msaa_override), y ese plugin se carga
  // en ReXApp::SetupPresentation() -> LoadGpuPlugin(), que ocurre DESPUES de
  // OnConfigurePaths. cvar::SetFlagFromSource devuelve kRejected cuando el cvar
  // todavia no existe y no lo guarda para mas tarde (a diferencia de los
  // valores de ns3fb.toml, que si se difieren en GetPendingValuesStorage), asi
  // que aplicados antes se perdian en silencio y el A/B no medía lo que decia.
  //
  // OnPreLaunchModule se llama desde ReXApp::LaunchModule(), despues de cargar
  // el plugin y antes de que el invitado lea ningun registro.
  void OnPreLaunchModule() override {
    const char* home = std::getenv("HOME");
    if (!home || !*home) {
      return;
    }

    // Marcadores de cvars del runtime. SetFlagByName va POR ENCIMA de
    // ns3fb.toml, asi que sirven para A/B sin editar el archivo.
    struct CvarMarker {
      const char* file;
      const char* name;
      const char* value;
    };
    static constexpr CvarMarker kCvarMarkers[] = {
        // Arregla las pantallas negras: con async_shader_compilation activo,
        // un frame que usa un pipeline de relleno NO se presenta.
        {"no_async_present.txt", "async_shader_compilation", "false"},
        {"no_async_present.txt", "vulkan_async_skip_incomplete_frames", "false"},
        // Ruta FSI: emula la EDRAM en el pixel shader en vez de con compute.
        // Cambia el reparto entre Compute GPU y Fragment GPU.
        {"rtt_fsi.txt", "render_target_path_vulkan", "fsi"},
        // Desactivar el salto de frames incompletos por separado.
        {"no_skip_frames.txt", "vulkan_async_skip_incomplete_frames", "false"},
        // A/B de async_shader_compilation: cuesta frames mientras compila,
        // pero con el puesto no se presenta ningun frame que use un pipeline
        // de relleno (pantallas negras).
        {"async_on.txt", "async_shader_compilation", "true"},
        // MSAA del host (parche ci/rexglue-msaa-override.patch). Existe tambien
        // como clave de ns3fb.toml: estos marcadores hacen lo mismo desde la
        // app Archivos. OJO: cualquier marcador msaaN.txt PISA el valor de
        // ns3fb.toml, asi que para la matriz de rendimiento no debe quedar
        // ninguno en Documents.
        {"msaa1.txt", "msaa_override", "1"},
        {"msaa2.txt", "msaa_override", "2"},
        {"msaa4.txt", "msaa_override", "4"},
        // Diagnostico del 3D negro (ci/rexglue-diag-overrides.patch).
        //   ztest_off.txt  fuerza z_enable=0 en todos los draws. Si con esto
        //                  aparece la geometria, era el depth test.
        //   blend_off.txt  fuerza One/Zero/Add en todos los draws, que es la
        //                  condicion con la que el pipeline apaga el blending.
        //                  Si aparece con este y no sin el, era el alpha.
        // UNO A UNO, nunca los dos a la vez: juntos no dicen cual arreglo.
        {"ztest_off.txt", "ztest_off", "true"},
        {"blend_off.txt", "blend_off", "true"},
        // Interruptor de TODA la instrumentacion NS3FB-*. Apagada por defecto:
        // encendida escribe mas de 200 lineas por segundo y el juego deja de
        // responder a los botones. Se enciende solo para diagnosticar.
        {"diag_on.txt", "ns3fb_diag", "true"},
    };
    // Volcado del estado efectivo.
    //
    // Existe porque hemos gastado builds enteros sin saber si un ajuste del
    // TOML se habia aplicado: msaa_override, render_target_path, occlusion...
    // Con esta linea, cualquier log dice exactamente con que configuracion se
    // ejecuto. Se consulta por nombre (cvar::Query) porque los cvars del
    // plugin de GPU no estan exportados como simbolo.
    const auto q_i = [](const char* name) { return rex::cvar::Query<int32_t>(name); };
    const auto q_b = [](const char* name) { return rex::cvar::Query<bool>(name) ? 1 : 0; };

    for (const auto& marker : kCvarMarkers) {
      std::error_code marker_ec;
      if (!std::filesystem::exists(
              std::filesystem::path(home) / "Documents" / marker.file, marker_ec)) {
        continue;
      }
      if (rex::cvar::SetFlagByName(marker.name, marker.value)) {
        REXLOG_INFO("cvar override (marker {}): {}={}", marker.file, marker.name, marker.value);
      } else {
        REXLOG_WARN("cvar override failed (marker {}): {}={}", marker.file, marker.name,
                    marker.value);
      }
    }

    // El volcado va DESPUES del bucle de marcadores a proposito: si va antes,
    // los campos zoff/blendoff (y cualquier cvar que ponga un marcador) salen
    // con el valor previo y un marcador aplicado se lee como no aplicado.
    REXLOG_INFO(
        "NS3FB-CONFIG msaa={} video={}x{} rt_path={} occl={} gamma16={} snorm16={} "
        "aniso={} async={} unclipped_cpu={} letterbox={} fsi_mask={} direct_resolve={} "
        "zoff={} blendoff={} diag={}",
        q_i("msaa_override"), q_i("video_mode_width"), q_i("video_mode_height"),
        rex::cvar::Query<std::string>("render_target_path_vulkan"), q_b("occlusion_query_enable"),
        q_b("gamma_render_target_as_unorm16"), q_b("snorm16_render_target_full_range"),
        q_i("anisotropic_override"), q_b("async_shader_compilation"),
        q_b("execute_unclipped_draw_vs_on_cpu"), q_b("present_letterbox"),
        q_b("fsi_sample_mask_from_sample_id"), q_b("direct_host_resolve"),
        // Los dos overrides de diagnostico: si no son 1, los marcadores no se
        // aplicaron y el build no sirve para decidir nada.
        q_b("ztest_off"), q_b("blend_off"), q_b("ns3fb_diag"));
  }
#endif
};
