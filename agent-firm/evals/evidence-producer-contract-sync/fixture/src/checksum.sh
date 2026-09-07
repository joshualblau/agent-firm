#!/bin/sh
# checksum <file> — print the lowercase SHA-256 of a file's bytes.
# Deliberately tiny: this fixture exists to exercise the evidence-publication path, not to be a
# project. The engagement adds `checksum --bytes` alongside it.
set -eu
[ "$#" -eq 1 ] || { echo "usage: checksum <file>" >&2; exit 2; }
shasum -a 256 "$1" | awk '{print $1}'
