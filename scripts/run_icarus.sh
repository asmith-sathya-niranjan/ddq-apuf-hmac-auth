#!/usr/bin/env bash
# run_icarus.sh - same three simulations with Icarus Verilog 12
# (this is how the logs/ shipped in this package were produced)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs
for pair in apuf:run sar:run_sar temp:run_temp; do
  tb=${pair%%:*}; log=${pair##*:}
  iverilog -g2005 -o /tmp/ddq_$tb.vvp rtl/ddq_apuf.v rtl/ddq_sar.v tb/tb_ddq_$tb.v
  vvp /tmp/ddq_$tb.vvp > logs/$log.log
  echo "$log: $(grep -E 'TEST (PASSED|FAILED)' logs/$log.log)"
done
