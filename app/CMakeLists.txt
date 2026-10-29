# NS3FB - ReXGlue recompilation of Naruto Shippuden: Ultimate Ninja Storm 3 Full Burst
# (Xbox 360, NTSC-U) for iOS.
#
# SDK boilerplate lives in generated/rexglue.cmake, produced by rexglue codegen.
# The recompiled game code is written to generated/default/ at build time from
# YOUR OWN game/default.xex - it is never part of this source tree.

cmake_minimum_required(VERSION 3.25)
project(ns3fb LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

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
    # Cliente de la extension de memoria. Con NS3FB_MEM_EXTENSION apagado
    # compila a un stub que devuelve vacio: el build por defecto no cambia.
    src/memext_client.mm
)

add_executable(ns3fb ${NS3FB_SOURCES})

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

    # ---------------------------------------------------------------------
    # ns3fb-mem: NSExtension que presta memoria desde su propio proceso.
    #
    # APAGADO POR DEFECTO. El .appex cambia la firma del IPA completo y usa
    # xpc_shmem, que es API no publica: sin un Mac no se puede comprobar que
    # enlace ni que la firma anidada sobreviva al sideload. Activar solo
    # sabiendo que un appex mal firmado invalida la instalacion entera.
    # Ver docs/RAM_EXTENSION_PLAN.md.
    # ---------------------------------------------------------------------
    option(NS3FB_MEM_EXTENSION
        "Build the ns3fb-mem NSExtension (iOS RAM ceiling workaround, experimental)"
        OFF)

    if(NS3FB_MEM_EXTENSION)
        message(STATUS "ns3fb-mem: construyendo la extension de memoria (experimental)")

        # libxpc trae xpc_shmem_create/map, que son API no publica.
        find_library(NS3FB_XPC_LIB xpc REQUIRED)

        add_library(ns3fb-mem MODULE
            platform/ios/memext/NS3FBMemExtension.mm
        )
        set_target_properties(ns3fb-mem PROPERTIES
            BUNDLE TRUE
            BUNDLE_EXTENSION appex
            MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/platform/ios/memext/Info.plist"
            MACOSX_BUNDLE_GUI_IDENTIFIER "${NS3FB_BUNDLE_ID}.memext"
            XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${NS3FB_BUNDLE_ID}.memext"
            XCODE_ATTRIBUTE_SKIP_INSTALL "YES"
            PREFIX ""
            OUTPUT_NAME "ns3fb-mem"
            CXX_STANDARD 23
        )
        target_compile_definitions(ns3fb-mem PRIVATE
            NS3FB_MEMEXT_SERVICE_NAME="${NS3FB_BUNDLE_ID}.memext")
        target_link_libraries(ns3fb-mem PRIVATE
            ${NS3FB_XPC_LIB}
            "-framework Foundation"
            "-framework UIKit"
        )

        # El app necesita el mismo nombre de servicio en su definicion.
        target_compile_definitions(ns3fb PRIVATE
            NS3FB_MEM_EXTENSION=1
            NS3FB_MEMEXT_SERVICE_NAME="${NS3FB_BUNDLE_ID}.memext")

        add_dependencies(ns3fb ns3fb-mem)
        add_custom_command(TARGET ns3fb POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E make_directory
                "$<TARGET_BUNDLE_CONTENT_DIR:ns3fb>/PlugIns"
            COMMAND ${CMAKE_COMMAND} -E copy_directory
                "$<TARGET_BUNDLE_DIR:ns3fb-mem>"
                "$<TARGET_BUNDLE_CONTENT_DIR:ns3fb>/PlugIns/ns3fb-mem.appex"
            COMMENT "Embedding ns3fb-mem.appex into ns3fb.app/PlugIns"
            VERBATIM
        )
    endif()
endif()
