#!/usr/bin/env bash
# =====================================================================
#  run_xsim.sh - run all three testbenches with Vivado's simulator
#                (XSim), no project needed. Linux.
#
#     source <Vivado install>/settings64.sh
#     ./scripts/run_xsim.sh
#  Transcripts go to logs/run.log, logs/run_sar.log, logs/run_temp.log
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs xsim_work
cd xsim_work

xvlog ../rtl/ddq_apuf.v ../rtl/ddq_sar.v \
      ../tb/tb_ddq_apuf.v ../tb/tb_ddq_sar.v ../tb/tb_ddq_temp.v

for pair in apuf:run sar:run_sar temp:run_temp; do
  tb=${pair%%:*}; log=${pair##*:}
  xelab -s snap_$tb tb_ddq_$tb
  xsim  snap_$tb -R -log ../logs/$log.log
done

cd ..
grep -H "TEST \(PASSED\|FAILED\)" logs/run.log logs/run_sar.log logs/run_temp.log
echo "Plot with:  python3 plot_ddq.py logs/run.log logs/run_sar.log logs/run_temp.log"
