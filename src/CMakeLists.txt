# src/CMakeLists.txt
# Main rawhash2 executable target

# --- Source files ---
set(RAWHASH2_SOURCES
    kthread.c
    kalloc.c
    bseq.c
    roptions.c
    sequence_until.c
    rutils.c
    rsig.c
    revent.c
    rsketch.c
    rindex.c
    lchain.c
    rseed.c
    hit.c
    dtw.c
    rextdata.c
    rmap.c
    main.c
)

add_executable(rawhash2 ${RAWHASH2_SOURCES})

# When POD5, HDF5, or gRPC is enabled, compile all sources as C++.
# HDF5: rsig.c contains C++ code in #ifndef NHDF5RH blocks.
# POD5: pre-built static libraries (libpod5_format.a, libarrow.a) require the C++ linker.
# gRPC: rlive.cpp is C++ and links against gRPC++ / protobuf C++ libraries.
# When none of these is enabled, all sources compile as pure C.
if(ENABLE_POD5 OR ENABLE_HDF5 OR ENABLE_GRPC)
    set_source_files_properties(${RAWHASH2_SOURCES} PROPERTIES LANGUAGE CXX)
endif()

# --- Include directories ---
target_include_directories(rawhash2 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# --- Common compile definitions ---
target_compile_definitions(rawhash2 PRIVATE HAVE_KALLOC)

# Profiling support
if(ENABLE_PROFILING)
    target_compile_definitions(rawhash2 PRIVATE PROFILERH=1)
    target_compile_options(rawhash2 PRIVATE -g -fno-omit-frame-pointer)
endif()

# SIMD / immintrin.h availability (set by CompilerSettings.cmake)
if(HAVE_IMMINTRIN_H)
    target_compile_definitions(rawhash2 PRIVATE HAVE_IMMINTRIN_H)
endif()

# ARM NEON flags
if(HAVE_ARM_NEON)
    target_compile_definitions(rawhash2 PRIVATE _FILE_OFFSET_BITS=64)
    target_compile_options(rawhash2 PRIVATE -fsigned-char)
    if(NOT HAVE_AARCH64)
        # 32-bit ARM needs explicit NEON flag
        target_compile_options(rawhash2 PRIVATE -mfpu=neon)
    endif()
endif()

# --- Conditional feature: HDF5 ---
if(NOT ENABLE_HDF5)
    target_compile_definitions(rawhash2 PRIVATE NHDF5RH=1)
else()
    target_include_directories(rawhash2 PRIVATE ${HDF5_INCLUDE_DIRS})
    target_link_libraries(rawhash2 PRIVATE ${HDF5_LIBRARIES})
    if(NOT USE_SYSTEM_HDF5 AND TARGET hdf5_external)
        add_dependencies(rawhash2 hdf5_external)
    endif()
endif()

# --- Conditional feature: SLOW5 ---
if(NOT ENABLE_SLOW5)
    target_compile_definitions(rawhash2 PRIVATE NSLOW5RH=1)
else()
    target_include_directories(rawhash2 PRIVATE ${SLOW5_INCLUDE_DIRS})
    target_link_libraries(rawhash2 PRIVATE ${SLOW5_LIBRARIES})
    add_dependencies(rawhash2 slow5_external)
endif()

# --- Conditional feature: POD5 ---
if(NOT ENABLE_POD5)
    target_compile_definitions(rawhash2 PRIVATE NPOD5RH=1)
else()
    target_include_directories(rawhash2 PRIVATE ${POD5_INCLUDE_DIRS})
    target_link_libraries(rawhash2 PRIVATE ${POD5_LIBRARIES})
    add_dependencies(rawhash2 pod5_external)
endif()

# --- Conditional feature: gRPC (MinKNOW live streaming) ---
if(NOT ENABLE_GRPC)
    target_compile_definitions(rawhash2 PRIVATE NGRPCRH=1)
else()
    # Generate C++ stubs from MinKNOW proto files
    generate_grpc_cpp(
        PROTO_FILES
            ${PROJECT_SOURCE_DIR}/proto/minknow_api/data.proto
            ${PROJECT_SOURCE_DIR}/proto/minknow_api/device.proto
            ${PROJECT_SOURCE_DIR}/proto/minknow_api/rpc_options.proto
        PROTO_PATH ${PROJECT_SOURCE_DIR}/proto
        OUTPUT_DIR ${CMAKE_BINARY_DIR}/generated
    )
    target_sources(rawhash2 PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/rlive.cpp
        ${GRPC_GENERATED_SOURCES}
    )
    target_include_directories(rawhash2 PRIVATE
        ${CMAKE_BINARY_DIR}/generated
    )
    target_link_libraries(rawhash2 PRIVATE gRPC::grpc++ protobuf::libprotobuf)
endif()

# --- zstd linking ---
# zstd is needed by both POD5 (directly) and SLOW5 (slow5lib built with zstd=1).
# Link it if either feature is enabled.
if(ENABLE_POD5 OR ENABLE_SLOW5)
    if(TARGET libzstd_static)
        # zstd built via add_subdirectory (CMake native build)
        target_link_libraries(rawhash2 PRIVATE libzstd_static)
    elseif(ZSTD_LIB_DIR)
        # zstd built via ExternalProject (Make fallback)
        target_link_libraries(rawhash2 PRIVATE "${ZSTD_LIB_DIR}/libzstd.a")
        if(TARGET zstd_external)
            add_dependencies(rawhash2 zstd_external)
        endif()
    endif()
endif()

# --- System libraries ---
find_package(Threads REQUIRED)
find_package(ZLIB REQUIRED)

target_link_libraries(rawhash2 PRIVATE
    Threads::Threads
    ZLIB::ZLIB
    ${CMAKE_DL_LIBS}   # -ldl on Linux, empty/unset on macOS (fixes macOS build)
    m                   # math library
)

# --- C++ runtime libraries (Linux only) ---
# POD5 v0.3.36 static archives (libarrow.a, libpod5_format.a) reference C++
# stdlib symbols that must be resolved after those archives:
#   - std::filesystem (from file_writer.cpp) needs -lstdc++fs on GCC < 9
#     (harmless stub on GCC 9+)
#   - std::basic_stringstream and other C++ symbols need -lstdc++ explicitly
#     at the end to ensure correct link ordering with static archives
if(ENABLE_POD5 OR ENABLE_HDF5 OR ENABLE_GRPC)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        target_link_libraries(rawhash2 PRIVATE stdc++fs stdc++)
    endif()
endif()

# --- Install ---
install(TARGETS rawhash2 RUNTIME DESTINATION bin)
