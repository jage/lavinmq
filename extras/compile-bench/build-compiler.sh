#!/bin/bash
# build-compiler.sh <libgc variant>...: builds the libgc variant with
# ../gc-bench/build-libgc-matrix.sh (stock fix fix-pf fix-fl acton ...), then the Crystal 1.22.2
# compiler in release mode linked against it, as $CB/compilers/crystal-<variant>. The result uses
# the installed stdlib and libgc for the programs it compiles, like the packaged compiler.
# "pkg" means the packaged /usr/bin/crystal and builds nothing. EXTRA_CR_FLAGS adds compiler flags.
set -eu
here=$(cd "$(dirname "$0")" && pwd); . "$here/env.sh"
for v in "$@"; do
  [ "$v" = pkg ] && { ln -sf /usr/bin/crystal "$CB/compilers/crystal-pkg"; continue; }
  [ -f "$CB/gcbuild/install-$v/lib/libgc.a" ] || VARIANTS=$v "$LMQ/extras/gc-bench/build-libgc-matrix.sh" "$CB/gcbuild"
  ( cd "$CRSRC"
    export CRYSTAL_PATH=$CRSRC/lib:$CRSRC/src CRYSTAL_CONFIG_PATH=/usr/share/crystal/src CRYSTAL_CONFIG_LIBRARY_PATH=/usr/lib/crystal
    export CRYSTAL_CONFIG_BUILD_COMMIT=1447d23 SOURCE_DATE_EPOCH=1793232000
    export CRYSTAL_LIBRARY_PATH=$CB/gcbuild/install-$v/lib:/usr/lib/crystal
    crystal build $CR_FLAGS --release ${EXTRA_CR_FLAGS:-} src/compiler/crystal.cr -o "$CB/compilers/crystal-$v" \
      > "$CB/compilers/build-$v.log" 2>&1 )
  "$CB/compilers/crystal-$v" --version | head -1 > /dev/null && echo "built compiler $v"
done
