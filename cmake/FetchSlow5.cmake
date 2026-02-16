# FetchSlow5.cmake
# Build slow5lib from the extern/slow5lib git submodule.
#
# Sets:
#   SLOW5_INCLUDE_DIRS  - include path for slow5 headers
#   SLOW5_LIBRARIES     - static library path for libslow5.a
#   SLOW5_FOUND         - TRUE if slow5 is available

include(ExternalProject)

set(SLOW5_SOURCE_DIR "${CMAKE_SOURCE_DIR}/extern/slow5lib")
set(SLOW5_INCLUDE_DIRS "${SLOW5_SOURCE_DIR}/include")
set(SLOW5_LIBRARIES "${SLOW5_SOURCE_DIR}/lib/libslow5.a")

# Determine parallel job count
include(ProcessorCount)
ProcessorCount(NPROC)
if(NPROC EQUAL 0)
    set(NPROC 1)
endif()

# slow5lib is built with its own Makefile, in-source.
# It needs zstd for BLOW5 compression. slow5lib's Makefile uses:
#   zstd_local=<path>  to set the include path and enable SLOW5_USE_ZSTD
#   slow5_mt=1         to enable multi-threaded I/O
ExternalProject_Add(slow5_external
    SOURCE_DIR      "${SLOW5_SOURCE_DIR}"
    CONFIGURE_COMMAND ""
    BUILD_COMMAND
        make -j${NPROC}
            slow5_mt=1
            zstd_local=${CMAKE_SOURCE_DIR}/extern/zstd/lib
            lib/libslow5.a
    INSTALL_COMMAND ""
    BUILD_IN_SOURCE TRUE
    BUILD_BYPRODUCTS "${SLOW5_LIBRARIES}"
    LOG_BUILD TRUE
)

# slow5lib depends on zstd being built first (for zstd headers and library).
# zstd may be built via add_subdirectory (CMake) or ExternalProject (Make fallback).
if(TARGET zstd_external)
    add_dependencies(slow5_external zstd_external)
elseif(TARGET libzstd_static)
    # When zstd is built via add_subdirectory, ensure it completes before slow5
    add_dependencies(slow5_external libzstd_static)
endif()

set(SLOW5_FOUND TRUE)
message(STATUS "slow5lib will be built from submodule: ${SLOW5_SOURCE_DIR}")
