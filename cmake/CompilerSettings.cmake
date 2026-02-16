# CompilerSettings.cmake
# Platform detection, compiler flags, and SIMD feature checks

include(CheckCXXCompilerFlag)
include(CheckIncludeFileCXX)

# --- Platform detection ---
message(STATUS "System: ${CMAKE_SYSTEM_NAME} ${CMAKE_SYSTEM_PROCESSOR}")
message(STATUS "Compiler: ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")

# --- Optimization flags ---
# Check if -march=native is supported (not supported on some Apple Silicon toolchains)
check_cxx_compiler_flag("-march=native" COMPILER_SUPPORTS_MARCH_NATIVE)

if(COMPILER_SUPPORTS_MARCH_NATIVE)
    set(ARCH_FLAG "-march=native")
else()
    # Fallback: no architecture-specific flag (common on Apple Silicon with certain compilers)
    set(ARCH_FLAG "")
    message(STATUS "Compiler does not support -march=native, using default architecture flags")
endif()

# Release flags (default)
set(CMAKE_C_FLAGS_RELEASE "-O3 ${ARCH_FLAG}" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_RELEASE "-O3 ${ARCH_FLAG}" CACHE STRING "" FORCE)

# Debug flags (replaces DEBUG=1)
set(CMAKE_C_FLAGS_DEBUG "-O2 -g ${ARCH_FLAG}" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_DEBUG "-O2 -g ${ARCH_FLAG}" CACHE STRING "" FORCE)

# Default to Release if not specified
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
    message(STATUS "Build type not specified, defaulting to Release")
endif()

# --- SIMD / Architecture detection ---

# ARM NEON detection
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
    set(HAVE_ARM_NEON TRUE)
    set(HAVE_AARCH64 TRUE)
    message(STATUS "Detected AArch64 with NEON support")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "arm|ARM")
    set(HAVE_ARM_NEON TRUE)
    set(HAVE_AARCH64 FALSE)
    message(STATUS "Detected 32-bit ARM with NEON support")
endif()

# x86 intrinsics header check (immintrin.h is Intel/AMD only)
check_include_file_cxx("immintrin.h" HAVE_IMMINTRIN_H)
if(HAVE_IMMINTRIN_H)
    message(STATUS "immintrin.h available (x86 SIMD intrinsics)")
else()
    message(STATUS "immintrin.h not available (non-x86 or missing intrinsics)")
endif()

# --- Address / Thread sanitizer support ---
option(ENABLE_ASAN "Enable AddressSanitizer" OFF)
option(ENABLE_TSAN "Enable ThreadSanitizer" OFF)

if(ENABLE_ASAN)
    add_compile_options(-fsanitize=address)
    add_link_options(-fsanitize=address)
    message(STATUS "AddressSanitizer enabled")
endif()

if(ENABLE_TSAN)
    add_compile_options(-fsanitize=thread)
    add_link_options(-fsanitize=thread)
    message(STATUS "ThreadSanitizer enabled")
endif()

# --- Common compile flags ---
# Note: -pthread is NOT added here because Threads::Threads (linked in
# src/CMakeLists.txt) provides it correctly per-platform.
add_compile_options(-Wall)
