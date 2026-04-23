#!/bin/bash
# Run this script on the PYNQ board to test DMA vs MMIO

echo "=== Hardware Diagnostic ==="
python3 diagnose_hardware.py
echo ""

echo "=== DMA vs MMIO Test ==="
python3 test_dma_simple.py
echo ""

echo "=== Full Comparison Test ==="
python3 test_dma_vs_mmio.py
