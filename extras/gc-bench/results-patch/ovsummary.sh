#!/bin/bash
# Per GC_PRINT_STATS log: collections, collections with >=1 "Mark stack overflow", overflow lines,
# last collection that overflowed, and the "Grew mark stack" sizes in order.
for f in "$@"; do
  awk -v f="$(basename "$f")" '/^--> Marking for collection/{c=substr($5,2)+0; n++}
    /Mark stack overflow/{o++; if(!(c in s)){s[c]=1;k++; last=c}}
    /Grew mark stack/{g=g (g?",":"") $5}
    END{printf "%-34s collections=%d with_overflow=%d overflow_lines=%d last_overflow=#%s grew=%s\n", f, n, k, o, last, (g?g:"-")}' "$f"
done
