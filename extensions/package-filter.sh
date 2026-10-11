#!/bin/bash
set -euo pipefail
exec "$(dirname "$0")/package-extension.sh" "${1:-build/AILock.app}" filter
