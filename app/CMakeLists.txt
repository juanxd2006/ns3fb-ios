# NS3FB - ReXGlue recompilation of Naruto Shippuden: Ultimate Ninja Storm 3 Full Burst
# (Xbox 360, NTSC-U) for iOS.
#
# SDK boilerplate lives in generated/rexglue.cmake, produced by rexglue codegen.
# The recompiled game code is written to generated/default/ at build time from
# YOUR OWN game/default.xex - it is never part of this source tree.

cmake_minimum_required(VERSION 3.25)
project(ns3fb LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# El puente con NSExtension/xpc_shmem es Objective-C++ (.mm). Solo en iOS: en
# macOS el target no compila esos ficheros y no hace falta el lenguaje.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    enable_language(OBJCXX)
endif()

# Extension de memoria (RAM limit workaround). ON por defecto: la app solo la usa
# si existe el marcador Documents/ramext_on.txt, asi que empaquetarla no cambia
# el comportamiento. -DNS3FB_MEM_EXTENSION=OFF compila sin ella.
option(NS3FB_MEM_EXTENSION "Empaquetar la extension ns3fb-mem (NSExtension + xpc_shmem)" ON)

if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/game/default.xex")
    message(FATAL_ERROR
        "game/default.xex not found.\n"
        "Extract your own Naruto Shippuden: Ultimate Ninja Storm 3 Full Burst (NTSC-U) "
        "disc into app/game/ first. See README.md, Paso 1.")
endif()

# Keep build-machine paths (which usually contain your user name) out of the
# binaries: source file names end up in log and assert messages.
add_compile_options("-ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}=ns3fb")
if(DEFINED ENV{REXGLUE_SDK})
    add_compile_options("-ffile-prefix-map=$ENV{REXGLUE_SDK}=rexglue-sdk")
endif()

include(generated/rexglue.cmake)

set(NS3FB_SOURCES
    src/main.cpp
)

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    list(APPEND NS3FB_SOURCES src/ios/ns3fb_ram_donor.mm)
endif()

add_executable(ns3fb ${NS3FB_SOURCES})

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # ARC obligatorio: el codigo del donante usa __weak y xpc_object_t como
    # puntero ObjC. -fapplication-extension solo aplica al .appex, no aqui.
    set_source_files_properties(src/ios/ns3fb_ram_donor.mm PROPERTIES
        COMPILE_OPTIONS "-fobjc-arc")
    target_include_directories(ns3fb PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/platform/ios/memext)
    target_link_libraries(ns3fb PRIVATE "-framework Foundation")
    # libxpc: xpc_* y xpc_shmem_* viven ahi. En iOS no siempre se resuelven por
    # venir Foundation, asi que se enlaza explicitamente si el SDK la expone.
    find_library(NS3FB_XPC_LIBRARY xpc)
    if(NS3FB_XPC_LIBRARY)
        target_link_libraries(ns3fb PRIVATE ${NS3FB_XPC_LIBRARY})
    endif()
endif()

# ns3fb_register.cpp is a flat table of tens of thousands of function-pointer
# registrations with no control flow worth optimising, but -O3 spends over ten
# minutes on it. -O1 produces the same table in seconds.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/generated/default/ns3fb_register.cpp")
    set_source_files_properties(
        ${CMAKE_CURRENT_SOURCE_DIR}/generated/default/ns3fb_register.cpp
        PROPERTIES COMPILE_OPTIONS "-O1")
endif()

rexglue_setup_target(ns3fb)

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(NS3FB_BUNDLE_ID "com.example.ns3fb" CACHE STRING
        "iOS bundle identifier. Use one your signing identity can provision.")
    set(NS3FB_IOS_SDK_LIB_DIR "" CACHE PATH
        "Directory with the iOS SDK runtime dylibs (rexglue-sdk/out/ios-arm64/Release)")
    if(NOT EXISTS "${NS3FB_IOS_SDK_LIB_DIR}/librexruntime.dylib")
        message(FATAL_ERROR
            "NS3FB_IOS_SDK_LIB_DIR='${NS3FB_IOS_SDK_LIB_DIR}' does not contain librexruntime.dylib.\n"
            "Build the patched SDK for iOS first and set REXGLUE_SDK (see README.md, Paso 2).")
    endif()

    # Produce a .app rather than a bare executable.
    set_target_properties(ns3fb PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/platform/ios/Info.plist"
        MACOSX_BUNDLE_GUI_IDENTIFIER "${NS3FB_BUNDLE_ID}"
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${NS3FB_BUNDLE_ID}"
        # The SDK's helper sets @executable_path, right for a flat macOS layout;
        # inside a bundle the dylibs live in Frameworks/.
        INSTALL_RPATH "@executable_path/Frameworks"
        BUILD_WITH_INSTALL_RPATH ON
    )

    # Everything the app dlopens or links must ship inside the bundle and be
    # signed with it: iOS will not load a dylib from outside the app.
    set(NS3FB_IOS_EMBED
        "${NS3FB_IOS_SDK_LIB_DIR}/librexruntime.dylib"
        "${NS3FB_IOS_SDK_LIB_DIR}/librexgpu-xenos.dylib"
        "${NS3FB_IOS_SDK_LIB_DIR}/libMoltenVK.dylib"
    )
    add_custom_command(TARGET ns3fb POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_BUNDLE_CONTENT_DIR:ns3fb>/Frameworks"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${NS3FB_IOS_EMBED}
            "$<TARGET_BUNDLE_CONTENT_DIR:ns3fb>/Frameworks"
        COMMENT "Embedding runtime dylibs into ns3fb.app/Frameworks"
        VERBATIM
    )

    # Optional app icons (not included). iOS resolves icons by filename from the
    # bundle root, driven by CFBundleIcons in Info.plist: drop
    # AppIcon60x60@2x.png etc. into platform/ios/icons/ to use your own.
    file(GLOB NS3FB_IOS_ICONS "${CMAKE_CURRENT_SOURCE_DIR}/platform/ios/icons/*.png")
    if(NS3FB_IOS_ICONS)
        add_custom_command(TARGET ns3fb POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                ${NS3FB_IOS_ICONS}
                "$<TARGET_BUNDLE_CONTENT_DIR:ns3fb>"
            COMMENT "Copying app icons into ns3fb.app"
            VERBATIM
        )
    endif()

    # -----------------------------------------------------------------------
    # Extension de memoria: "RAM limit workaround" (docs/RAM_EXTENSION_PLAN.md)
    #
    # Un .appex con su propio proceso y su propio presupuesto de jetsam que
    # reserva la RAM del invitado y se la pasa a la app por xpc_shmem. Ver
    # platform/ios/memext/README.md.
    #
    # -DNS3FB_MEM_EXTENSION=OFF compila sin ella: sirve para saber si un fallo
    # de instalacion viene de la firma anidada del .appex o del resto del IPA.
    # Aunque vaya empaquetada, la app NO la usa si no existe
    # Documents/ramext_on.txt, asi que el comportamiento por defecto no cambia.
    # -----------------------------------------------------------------------
    if(NS3FB_MEM_EXTENSION)
        add_library(ns3fb-mem MODULE
            platform/ios/memext/NS3FBMemExtension.mm
        )
        set_target_properties(ns3fb-mem PROPERTIES
            OUTPUT_NAME "ns3fb-mem"
            BUNDLE TRUE
            BUNDLE_EXTENSION "appex"
            MACOSX_BUNDLE_INFO_PLIST
                "${CMAKE_CURRENT_SOURCE_DIR}/platform/ios/memext/Info.plist"
            MACOSX_BUNDLE_GUI_IDENTIFIER "${NS3FB_BUNDLE_ID}.mem"
            XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${NS3FB_BUNDLE_ID}.mem"
            XCODE_ATTRIBUTE_SKIP_INSTALL "YES"
        )
        target_include_directories(ns3fb-mem PRIVATE platform/ios/memext)
        target_compile_options(ns3fb-mem PRIVATE -fobjc-arc -fapplication-extension)
        # La extension no enlaza nada del SDK: Foundation (NSXPC*) y libxpc
        # (que ya viene con libSystem).
        target_link_libraries(ns3fb-mem PRIVATE "-framework Foundation")
        if(NS3FB_XPC_LIBRARY)
            target_link_libraries(ns3fb-mem PRIVATE ${NS3FB_XPC_LIBRARY})
        endif()

        # iOS solo carga extensiones desde <app>/PlugIns, y valida la firma
        # anidada del bundle completo: se copia el .appex, no el binario suelto.
        add_dependencies(ns3fb ns3fb-mem)
        add_custom_command(TARGET ns3fb POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E make_directory
                "$<TARGET_BUNDLE_CONTENT_DIR:ns3fb>/PlugIns"
            COMMAND ${CMAKE_COMMAND} -E copy_directory
                "$<TARGET_BUNDLE_DIR:ns3fb-mem>"
                "$<TARGET_BUNDLE_CONTENT_DIR:ns3fb>/PlugIns/ns3fb-mem.appex"
            COMMENT "Empaquetando ns3fb-mem.appex en ns3fb.app/PlugIns"
            VERBATIM
        )
    else()
        message(STATUS "NS3FB_MEM_EXTENSION=OFF: el IPA sale sin extension de memoria")
    endif()
endif()
