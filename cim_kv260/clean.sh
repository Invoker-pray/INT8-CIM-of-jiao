#!/bin/bash
# Clean all PetaLinux generated files (keeps project-spec configs and user meta)
set -e

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJ_DIR"

echo "=== Cleaning PetaLinux generated files ==="

rm -rf build/
rm -rf images/
rm -rf pre-built/
rm -rf components/yocto/
rm -rf components/plnx_workspace/
rm -rf project-spec/hw-description/
rm -f *.log *.jou

echo "=== Clean complete ==="
