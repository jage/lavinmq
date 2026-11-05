#!/bin/bash
# git bisect run step: exit 0 if the 4-thread alloc benchmark is slow (old), 1 if fast (new)
set -u
src=$(pwd); pre=/home/user/gcbench/bisect-install
rm -rf "$pre"
(./autogen.sh && CFLAGS="-fPIC -pipe -O2 -std=gnu17" ./configure -q --disable-debug --disable-shared --enable-large-config --prefix="$pre" && make -j4 && make install) > /home/user/gcbench/bisect-build.log 2>&1 || exit 125
CRYSTAL_LIBRARY_PATH=$pre/lib:/usr/lib/crystal crystal build --release /home/user/lavinmq/extras/gc-bench/alloc.cr -o /home/user/gcbench/bisect-alloc || exit 125
git clean -qfdx > /dev/null 2>&1
best=999999
for i in 1 2; do
  ns=$(/home/user/gcbench/bisect-alloc 4 10 200000 | awk '{for(i=1;i<=NF;i++) if ($i=="ns/step/thread") print int($(i-1))}')
  [ "$ns" -lt "$best" ] && best=$ns
done
echo "$(git rev-parse --short HEAD) $best ns $(git log -1 --format=%s)" >> /home/user/gcbench/bisect.txt
[ "$best" -gt 300 ] && exit 0 || exit 1
