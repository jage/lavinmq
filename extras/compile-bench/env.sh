# Sourced by the compile-bench scripts.
CB=${CB:-$HOME/cbench}
LMQ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CRSRC=$CB/crystal-src
# Flags `make crystal` uses for the compiler (plus i_know_what_im_doing to skip the wrapper check)
CR_FLAGS="-D i_know_what_im_doing -D strict_multi_assign -D preview_overload_order -Dwithout_interpreter -Dwithout_libxml2 -Dwithout_openssl -Dwithout_zlib"
