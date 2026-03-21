#!/usr/bin/env bash
set -e

ZLIB_INCLUDE=$(echo "$NIX_CFLAGS_COMPILE" | tr ' ' '\n' | grep -A1 '\-isystem' | grep 'zlib' | head -1)
ZLIB_LIB=$(echo "$NIX_LDFLAGS" | tr ' ' '\n' | grep '\-L.*zlib' | grep -v 'static\|dev' | head -1 | sed 's/-L//')

if [ -z "$ZLIB_INCLUDE" ]; then
    ZLIB_INCLUDE=/nix/store/rxd3kdsc7k72198g58wk0qp3xdip5x5d-zlib-1.3.1-dev/include
fi

if [ -z "$ZLIB_LIB" ]; then
    ZLIB_LIB=/nix/store/jl19fdc7gdxqz9a1s368r9d15vpirnqy-zlib-1.3.1/lib
fi

echo "Building RawHash2 (no external format dependencies)..."
mkdir -p bin

make -C src NOPOD5=1 NOHDF5=1 NOSLOW5=1 \
    INCLUDES="-I${ZLIB_INCLUDE}" \
    BASE_DEFS="-DHAVE_KALLOC -D_POSIX_C_SOURCE=200809L" \
    EXTRA_LDFLAGS="-L${ZLIB_LIB}"

cp src/rawhash2 bin/rawhash2
echo "Build complete: bin/rawhash2"
echo "Run: ./bin/rawhash2 -h"
./bin/rawhash2 -h 2>&1 | head -5
