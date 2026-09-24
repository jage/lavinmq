#!/bin/sh
set -e
d=$(dirname "$0")
iconv -f windows-1252 -t utf-8 "$1" \
  | python3 "$d/bullets.py" \
  | python3 "$d/code_blocks.py" \
  | python3 "$d/flatten_tables.py" \
  | pandoc -f html -t gfm-raw_html --wrap=none \
  | python3 "$d/cleanup_mqtt.py"
