#!/bin/bash
# Run as your normal user; never sudo the build pipeline.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/env python3 "$script_dir/lib/rebuild_install.py" "$@"
