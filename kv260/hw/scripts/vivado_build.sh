#!/bin/bash
# Usage: cd project_root && bash kv260/hw/scripts/vivado_build.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")/../../.."
echo "Project root: $(pwd)"
vivado -mode batch -source kv260/hw/scripts/vivado_build_kv260.tcl 2>&1 | tee kv260_build.log
