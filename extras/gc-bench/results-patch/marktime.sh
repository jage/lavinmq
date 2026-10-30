#!/bin/bash
# Mean and max "World-stopped marking took" (ms) over collections >= #FROM (default 20).
for f in "$@"; do
  awk -v f="$(basename "$f")" -v from="${FROM:-20}" '/^--> Marking for collection/{c=substr($5,2)+0}
    /World-stopped marking took/{if(c>=from){t=$4+$6/1e6; s+=t; n++; if(t>m)m=t}}
    END{printf "%-34s n=%d mean_mark=%.2f ms max_mark=%.2f ms\n", f, n, (n?s/n:0), m}' "$f"
done
