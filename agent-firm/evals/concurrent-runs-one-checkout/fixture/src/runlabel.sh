#!/bin/sh
# runlabel <run-id> — print a short, human-readable label for a run id of the form
# <YYYYmmddTHHMMSSZ>-<slug>: the slug, then the timestamp in parentheses.
#
# Deliberately tiny. This fixture exists to exercise the CONCURRENT-RUN tooling under a real
# engagement, not to be a project; the engagement's own deliverable is small on purpose so that the
# golden concurrency check, not the feature work, is what the eval turns on.
set -eu
[ "$#" -eq 1 ] || { echo "usage: runlabel <run-id>" >&2; exit 2; }
id="$1"
case "$id" in
  *-*) ;;
  *) echo "runlabel: not a run id: $id" >&2; exit 2 ;;
esac
stamp="${id%%-*}"
slug="${id#*-}"
printf '%s (%s)\n' "$slug" "$stamp"
