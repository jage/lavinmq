#!/bin/bash
# measure.sh <results file> <label> <workload> <compiler binary>
# One cold compile (fresh CRYSTAL_CACHE_DIR unless CACHE=<dir>) with --stats, GC_PRINT_STATS and
# /usr/bin/time; appends one summary line to $CB/results/<results file>.txt and prints it.
# Workloads: lmq-dev lmq-release lmq-O3 lmq-O2 lmq-O1 cr-dev cr-release cr-O3 cr-O2 cr-O1, and the
# spec binaries (dev mode): lmq-spec (all LavinMQ specs), crstd-spec (Crystal's std_spec.cr),
# crsem-spec (Crystal's semantic compiler specs, spec/compiler/semantic)
# EXTRA="..." adds compiler arguments (e.g. "--threads 1"); other env (GC_*) passes through.
set -u
here=$(cd "$(dirname "$0")" && pwd); . "$here/env.sh"
file=$1 label=$2 wl=$3 cr=$4
out=$CB/runs/$file-$label-$wl; rm -rf "$out"; mkdir -p "$out"
case $wl in
  lmq-spec) dir=$LMQ; src=$out/lmq_spec.cr; flags=  # one source of requires, as `crystal spec` compiles it
        (cd "$LMQ" && find spec -name '*_spec.cr' | sort | sed "s|.*|require \"$(realpath --relative-to="$out" "$LMQ")/&\"|") > "$src" ;;
  crstd-spec|crsem-spec)
        dir=$CRSRC; flags="-D i_know_what_im_doing -D strict_multi_assign -D preview_overload_order --exclude-warnings spec/std --exclude-warnings spec/compiler"
        [ $wl = crstd-spec ] && src=spec/std_spec.cr || { src=$(cd "$CRSRC" && ls spec/compiler/semantic/*_spec.cr | tr '\n' ' '); flags="$flags -Dwithout_interpreter -Dwithout_libxml2 -Dwithout_openssl -Dwithout_zlib"; }
        export CRYSTAL_PATH=$CRSRC/lib:$CRSRC/src CRYSTAL_CONFIG_PATH=$CRSRC/src CRYSTAL_CONFIG_LIBRARY_PATH=/usr/lib/crystal ;;
  lmq-*) dir=$LMQ; src=src/lavinmq.cr; flags= ;;
  cr-*) dir=$CRSRC; src=src/compiler/crystal.cr; flags=$CR_FLAGS
        export CRYSTAL_PATH=$CRSRC/lib:$CRSRC/src CRYSTAL_CONFIG_PATH=/usr/share/crystal/src CRYSTAL_CONFIG_LIBRARY_PATH=/usr/lib/crystal ;;
  *) echo "unknown workload $wl" >&2; exit 2 ;;
esac
case $wl in
  *-dev|*-spec) mode= ;; *-release) mode=--release ;; *-O3) mode=-O3 ;; *-O2) mode=-O2 ;; *-O1) mode=-O1 ;;
esac
cd "$dir"
CRYSTAL_CACHE_DIR=${CACHE:-$out/cache} GC_PRINT_STATS=1 /usr/bin/time -v "$cr" build --stats $flags $mode ${EXTRA:-} $src -o "$out/bin" > "$out/stdout" 2> "$out/stderr"
rc=$?
[ "${KEEP_BIN:-0}" = 1 ] || rm -f "$out/bin"
[ -z "${CACHE:-}" ] && rm -rf "$out/cache"
python3 -I "$here/summarize.py" "$label" "$wl" "$out" "$rc" "${EXTRA:-}" | tee -a "$CB/results/$file.txt"
