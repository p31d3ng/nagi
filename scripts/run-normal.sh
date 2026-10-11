#!/bin/zsh
# A new normal instance, even if the separate synthetic test window is open.
set -euo pipefail
project=${0:A:h:h}
unset NAGI_SYNTHETIC_MONITOR NAGI_DATA NAGI_PROJECT
exec /usr/bin/open -n "$project/build/Nagi.app"
