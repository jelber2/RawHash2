cmake_minimum_required(VERSION 3.16)
project(rawhash2
    VERSION 2.1
    LANGUAGES C CXX
    DESCRIPTION "Real-time, ultrafast, and lightweight raw nanopore signal mapping"
)

# --- Language standards ---
# gRPC requires C++14 minimum; default is C++11 for POD5/HDF5 compatibility
if(ENABLE_GRPC)
    set(CMAKE_CXX_STANDARD 14)
else()
    set(CMAKE_CXX_STANDARD 11)
endif()
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 99)

# --- Feature toggles ---
# These replace the old NOHDF5=1 / NOSLOW5=1 / NOPOD5=1 Make variables.
# Usage: cmake -DENABLE_HDF5=ON -DENABLE_SLOW5=ON ..
option(ENABLE_HDF5      "Enable HDF5/FAST5 support"    OFF)
option(ENABLE_SLOW5     "Enable SLOW5/BLOW5 support"    OFF)
option(ENABLE_POD5      "Enable POD5 support"           ON)
option(ENABLE_PROFILING "Enable profiling support"      OFF)
option(ENABLE_GRPC      "Enable MinKNOW gRPC live streaming support" OFF)

# --- Version parameters for dependencies ---
# These can be overridden at configure time:
#   cmake -DPOD5_VERSION=0.3.11 ..
set(POD5_VERSION "0.3.36" CACHE STRING "POD5 library version to download")

# --- Compiler and platform settings ---
include(cmake/CompilerSettings.cmake)

# --- External dependencies ---
include(cmake/Dependencies.cmake)

# --- Main target ---
add_subdirectory(src)
