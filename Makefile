# RawHash2 - Root Makefile
#
# Default 'make' builds via src/Makefile (no CMake required).
# Use 'make cmake' to build via the CMake system instead.
#
# Options (passed through to src/Makefile):
#   DEBUG=1     Debug build (-O2 -fsanitize=address -g)
#   PROFILE=1   Profiling build (-g -fno-omit-frame-pointer -DPROFILERH=1)
#   NOPOD5=1    Disable POD5 support (enabled by default)
#   NOHDF5=0    Enable HDF5/FAST5 support (disabled by default)
#   NOSLOW5=0   Enable SLOW5/BLOW5 support (disabled by default)
#   asan=1      Enable AddressSanitizer
#   tsan=1      Enable ThreadSanitizer
#
# CMake build (alternative):
#   make cmake
#   make cmake CMAKE_OPTS="-DENABLE_HDF5=ON"

.PHONY: all rawhash2 subset cmake clean help

# Root directory (works correctly in git worktrees)
ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Default parallelism for cmake target
JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Pass through CMake options when using 'make cmake'
CMAKE_OPTS ?=

# --- Default target: standalone build via src/Makefile (no CMake needed) ---
all: rawhash2

rawhash2:
	@mkdir -p bin
	+$(MAKE) -C src
	@cp src/rawhash2 bin/
	@echo "Build complete: bin/rawhash2"

subset:
	@mkdir -p bin
	+$(MAKE) -C src subset
	@cp src/rawhash2 bin/
	@echo "Build complete (subset): bin/rawhash2"

# --- Alternative: CMake build ---
cmake:
	@mkdir -p build
	cd build && cmake $(CMAKE_OPTS) $(ROOT_DIR)
	cmake --build build -j$(JOBS)
	@mkdir -p bin && cp build/src/rawhash2 bin/
	@echo "CMake build complete: bin/rawhash2"

# --- Clean ---
clean:
	rm -rf bin build
	+$(MAKE) -C src clean

# --- Help ---
help:
	@echo "RawHash2 Build System"
	@echo ""
	@echo "Standalone build (default, no CMake required):"
	@echo "  make                  Build with POD5 enabled (default)"
	@echo "  make subset           Build without recompiling external dependencies"
	@echo "  make NOPOD5=1         Build without POD5 support"
	@echo "  make DEBUG=1          Debug build with AddressSanitizer"
	@echo "  make PROFILE=1        Build with profiling support"
	@echo ""
	@echo "CMake build (alternative):"
	@echo "  make cmake                                  Build via CMake"
	@echo '  make cmake CMAKE_OPTS="-DENABLE_POD5=OFF"   CMake without POD5'
	@echo ""
	@echo "  make clean            Remove all build artifacts"
	@echo "  make help             Show this help"
	@echo ""
	@echo "Standalone options (passed to src/Makefile):"
	@echo "  DEBUG=1       Debug build (-O2 -fsanitize=address -g)"
	@echo "  PROFILE=1     Profiling build (-g -fno-omit-frame-pointer)"
	@echo "  NOPOD5=1      Disable POD5 support"
	@echo "  NOHDF5=0      Enable HDF5/FAST5 support (disabled by default)"
	@echo "  NOSLOW5=0     Enable SLOW5/BLOW5 support (disabled by default)"
	@echo "  asan=1        Enable AddressSanitizer (without DEBUG)"
	@echo "  tsan=1        Enable ThreadSanitizer"
