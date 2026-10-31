//======================================================================
//  tb_ddq_temp.v  -  two experiments the paper does not run
//
//  PART A - delay-scale ("temperature") sweep
//  ------------------------------------------
//  The quantised code is a ratio of two delays on the same die,
//  code = dD / delay_t. The model scales every delay as
//        d(T) = d * TSCALE/100  +  (TSCALE-100) * tc/100
//               \___uniform___/     \_______mismatch_______/
//  The uniform part cancels in the ratio BY CONSTRUCTION of this model,
//  so this experiment does not prove the physics. What it does measure
//  is how the three things that remain compare in size:
//     arbiter noise  (the 100 % column: same silicon, fresh noise)
//     TC mismatch    (TC_VAR = 10 ps vs 0 ps)
//     integer-ps truncation of the scaled delays (the noise-free group)
//
//  Fixes relative to the first version:
//    * every instance has its own arbiter-noise seed (NSALT). Before, all
//      five temperature instances drew the SAME noise sequence, so noise
//      cancelled out of the drift and the numbers were far too small.
//    * enrolment is a separate noisy measurement at 100 %, so the 100 %
//      column shows the real noise floor instead of a trivial 0.
//    * both TC values run in one simulation; no file editing needed.
//
//  PART B - median vs mean combiner, core 2 five times noisier
//  -----------------------------------------------------------
//  The median is worse; the diagnostic below shows WHY, per CRP.
//======================================================================
`timescale 1ps / 1ps

module tb_ddq_temp;

  localparam integer N        = 32;
  localparam integer NDLY     = 6;
  localparam integer T_NOM    = 100;
  localparam integer T_VAR    = 16;
  localparam integer NOISE_PS = 8;
  localparam integer TC_A     = 0;       // group 0 (noisy) and group 2 (noise-free)
  localparam integer TC_B     = 10;      // group 1 (noisy)

  localparam integer DT_UNARY = 30;
  localparam integer D_UNARY  = 3;       // paper's tolerance
  localparam integer DT_SAR   = 4;
  localparam integer D_SAR    = 7;       // smallest d at 100 % in tb_ddq_sar.v

  localparam integer NSCALE   = 5;       // 70, 85, 100, 115, 130 %
  localparam integer NGRP     = 3;
  localparam integer NINST    = NSCALE * NGRP;
  localparam integer NCHAL    = 200;
  localparam integer CLK_HALF = 5000;

  localparam [31:0] CHIP0 = 32'h1234_5678;
  localparam [31:0] CSEED = 32'h7E3A_0001;

  reg          clk = 1'b0, rst_n = 1'b0, start = 1'b0;
  reg  [N-1:0] chal = {N{1'b0}};
  always #(CLK_HALF) clk = ~clk;

  //------------------------------------------------------------------
  // PART A instances
  //------------------------------------------------------------------
  wire [12:0]       ro_w   [0:NINST-1];
  wire signed [7:0] code_w [0:NINST-1];
  wire [12:0]       ro_enr;
  wire signed [7:0] code_enr;
  wire              dn_u, dn_s;

  // enrolment: nominal temperature, its own noise
  ddq_apuf_top #(.N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR), .DELAY_T(DT_UNARY),
    .NOISE_PS(NOISE_PS), .TSCALE(100), .TC_VAR(TC_B), .PUF_SEED(CHIP0), .NSALT(999)) u_enr_u (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(4'd0),
    .r_o(ro_enr), .r_l(), .phase(), .busy(), .done(dn_u));
  ddq_sar_top #(.N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR), .DELAY_T(DT_SAR),
    .NOISE_PS(NOISE_PS), .TSCALE(100), .TC_VAR(TC_B), .PUF_SEED(CHIP0), .NSALT(999)) u_enr_s (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(4'd0),
    .code(code_enr), .mag(), .sign(), .r_l(), .step(), .busy(), .done(dn_s));

  genvar gg, g;
  generate
    for (gg = 0; gg < NGRP; gg = gg + 1) begin : g_grp
      for (g = 0; g < NSCALE; g = g + 1) begin : g_scale
        localparam integer TS  = 70 + 15 * g;
        localparam integer TCV = (gg == 1) ? TC_B : TC_A;
        localparam integer NZ  = (gg == 2) ? 0 : NOISE_PS;
        localparam integer IDX = NSCALE * gg + g;

        ddq_apuf_top #(.N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR), .DELAY_T(DT_UNARY),
          .NOISE_PS(NZ), .TSCALE(TS), .TC_VAR(TCV), .PUF_SEED(CHIP0), .NSALT(16 + IDX)) u_unary (
          .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(4'd0),
          .r_o(ro_w[IDX]), .r_l(), .phase(), .busy(), .done());

        ddq_sar_top #(.N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR), .DELAY_T(DT_SAR),
          .NOISE_PS(NZ), .TSCALE(TS), .TC_VAR(TCV), .PUF_SEED(CHIP0), .NSALT(16 + IDX)) u_sar (
          .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(4'd0),
          .code(code_w[IDX]), .mag(), .sign(), .r_l(), .step(), .busy(), .done());
      end
    end
  endgenerate

  //------------------------------------------------------------------
  // PART B instances: same three-core device, measured twice with
  // independent noise (enrolment and re-measurement)
  //------------------------------------------------------------------
  wire signed [7:0] m_c0, m_c1, m_c2, m_med, m_mean;
  wire signed [7:0] e_c0, e_c1, e_c2, e_med, e_mean;

  ddq_sar_x3 #(.N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR), .DELAY_T(DT_SAR),
    .NOISE0(NOISE_PS), .NOISE1(NOISE_PS), .NOISE2(5 * NOISE_PS),
    .PUF_SEED(32'hBEEF_0001), .NSALT(0)) u_meas (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal),
    .code0(m_c0), .code1(m_c1), .code2(m_c2),
    .code_med(m_med), .code_mean(m_mean), .done());

  ddq_sar_x3 #(.N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR), .DELAY_T(DT_SAR),
    .NOISE0(NOISE_PS), .NOISE1(NOISE_PS), .NOISE2(5 * NOISE_PS),
    .PUF_SEED(32'hBEEF_0001), .NSALT(777)) u_enrl (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal),
    .code0(e_c0), .code1(e_c1), .code2(e_c2),
    .code_med(e_med), .code_mean(e_mean), .done());

  //------------------------------------------------------------------
  function integer ones13;
    input [12:0] v;
    integer j;
    begin
      ones13 = 0;
      for (j = 0; j < 13; j = j + 1) ones13 = ones13 + v[j];
    end
  endfunction

  function integer hd13;
    input [12:0] a;
    input [12:0] b;
    begin hd13 = ones13(a ^ b); end
  endfunction

  function integer iabs;
    input integer x;
    begin iabs = (x < 0) ? -x : x; end
  endfunction

  function integer imax3;
    input integer a, b, c;
    begin imax3 = (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c); end
  endfunction

  function integer mid3;                 // reference median, for self-check
    input integer a, b, c;
    begin
      if ((a >= b && a <= c) || (a <= b && a >= c))      mid3 = a;
      else if ((b >= a && b <= c) || (b <= a && b >= c)) mid3 = b;
      else                                               mid3 = c;
    end
  endfunction

  function integer which_med;            // index of the median core
    input integer a, b, c;
    begin
      if ((a >= b && a <= c) || (a <= b && a >= c))      which_med = 0;
      else if ((b >= a && b <= c) || (b <= a && b >= c)) which_med = 1;
      else                                               which_med = 2;
    end
  endfunction

  function integer tdiv3;                // signed divide, truncate toward 0
    input integer x;
    begin tdiv3 = (x < 0) ? -((-x) / 3) : (x / 3); end
  endfunction

  reg got_u, got_s;
  task run_crp;
    input [N-1:0] c;
    begin
      @(negedge clk);
      chal = c; start = 1'b1;
      @(negedge clk);
      start = 1'b0; got_u = 1'b0; got_s = 1'b0;
      while (!(got_u && got_s)) begin
        if (dn_u === 1'b1) got_u = 1'b1;
        if (dn_s === 1'b1) got_s = 1'b1;
        @(negedge clk);
      end
      @(negedge clk);
    end
  endtask

  //------------------------------------------------------------------
  integer i, k, grp, idx, errors, cs, nstat;
  real    lsb_ps;   // SAR LSB at the current scale, in ps
  integer ref_code, ref_ro_ones, sd, ud, ce;
  reg [12:0] ref_ro;
  integer sar_drift [0:NINST-1];
  integer uni_drift [0:NINST-1];
  integer sar_pass  [0:NINST-1];
  integer uni_pass  [0:NINST-1];
  integer conv_err  [0:NINST-1];

  integer ea0, ea1, ea2, ma0, ma1, ma2;
  integer med_err, mean_err, med_err_sum, mean_err_sum, med_worst, mean_worst;
  integer med_pass, mean_pass, n_swap, n_noisy_mid, n_fail_passthru, n_fail_swap, n_fail_other;
  integer core_err_sum2;

  initial begin
    errors = 0; nstat = 0; cs = CSEED;
    for (k = 0; k < NINST; k = k + 1) begin
      sar_drift[k] = 0; uni_drift[k] = 0; sar_pass[k] = 0; uni_pass[k] = 0; conv_err[k] = 0;
    end
    med_err_sum = 0; mean_err_sum = 0; med_worst = 0; mean_worst = 0;
    med_pass = 0; mean_pass = 0; n_swap = 0; n_noisy_mid = 0;
    n_fail_passthru = 0; n_fail_swap = 0; n_fail_other = 0; core_err_sum2 = 0;

    $display("======================================================================");
    $display(" PART A : delay-scale sweep  (TC_VAR = %0d and %0d ps, plus noise-free)", TC_A, TC_B);
    $display(" PART B : median vs mean combiner, core 2 five times noisier");
    $display(" every instance has independent arbiter noise; enrolment is noisy");
    $display("======================================================================");

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(negedge clk);

    for (i = 0; i < NCHAL; i = i + 1) begin
      run_crp($random(cs));
      nstat = nstat + 1;

      //------------------------------------------------ PART A
      for (grp = 0; grp < NGRP; grp = grp + 1) begin
        for (k = 0; k < NSCALE; k = k + 1) begin
          idx = NSCALE * grp + k;
          if (grp == 2) begin                    // noise-free: its own 100 % is the reference
            ref_ro   = ro_w[NSCALE * 2 + 2];
            ref_code = code_w[NSCALE * 2 + 2];
          end else begin
            ref_ro   = ro_enr;
            ref_code = code_enr;
          end
          sd = iabs(code_w[idx] - ref_code);
          ud = hd13(ro_w[idx], ref_ro);
          ce = (ro_w[idx][6] !== ref_ro[6]) ? 1 : 0;
          sar_drift[idx] = sar_drift[idx] + sd;
          uni_drift[idx] = uni_drift[idx] + iabs(ones13(ro_w[idx]) - ones13(ref_ro));
          if (sd <= D_SAR)   sar_pass[idx] = sar_pass[idx] + 1;
          if (ud <= D_UNARY) uni_pass[idx] = uni_pass[idx] + 1;
          conv_err[idx] = conv_err[idx] + ce;
          // last field: the SAR LSB at this scale, in tenths of a ps, so the
          // plot can convert drift to picoseconds without hard-coding DT_SAR
          $display("CSV,TEMP,%0d,%0d,%0d,%0d,%0d,%0d,%0d", 70 + 15 * k, sd, ud, ce,
                   (grp == 1) ? TC_B : TC_A, (grp == 2) ? 0 : 1,
                   (DT_SAR * (70 + 15 * k)) / 10);
        end
      end

      //------------------------------------------------ PART B
      // self-checks on the combiner RTL
      if (m_med  !== mid3(m_c0, m_c1, m_c2) || e_med !== mid3(e_c0, e_c1, e_c2)) begin
        errors = errors + 1; $display("  ERROR: ddq_median3 median wrong");
      end
      if (m_mean !== tdiv3(m_c0 + m_c1 + m_c2) || e_mean !== tdiv3(e_c0 + e_c1 + e_c2)) begin
        errors = errors + 1; $display("  ERROR: ddq_median3 mean wrong");
      end

      ea0 = iabs(m_c0 - e_c0); ea1 = iabs(m_c1 - e_c1); ea2 = iabs(m_c2 - e_c2);
      core_err_sum2 = core_err_sum2 + ea2;
      med_err  = iabs(m_med  - e_med);
      mean_err = iabs(m_mean - e_mean);
      // median-of-3 is 1-Lipschitz: it can never move more than the worst core
      if (med_err > imax3(ea0, ea1, ea2)) begin
        errors = errors + 1; $display("  ERROR: median moved more than any core");
      end
      med_err_sum  = med_err_sum  + med_err;
      mean_err_sum = mean_err_sum + mean_err;
      if (med_err  > med_worst)  med_worst  = med_err;
      if (mean_err > mean_worst) mean_worst = mean_err;
      if (med_err  <= D_SAR) med_pass  = med_pass  + 1;
      if (mean_err <= D_SAR) mean_pass = mean_pass + 1;

      ma0 = which_med(e_c0, e_c1, e_c2);         // median core at enrolment
      ma1 = which_med(m_c0, m_c1, m_c2);         // ... at re-measurement
      if (ma0 != ma1) n_swap = n_swap + 1;
      if (ma0 == 2)   n_noisy_mid = n_noisy_mid + 1;
      if (med_err > D_SAR) begin
        if (ma0 == 2 && ma1 == 2)       n_fail_passthru = n_fail_passthru + 1;
        else if (ma0 == 2 || ma1 == 2)  n_fail_swap     = n_fail_swap + 1;
        else                            n_fail_other    = n_fail_other + 1;
      end
      $display("CSV,COMB,%0d,%0d,%0d,%0d", mean_err, med_err, ma0, ma1);
    end

    //----------------------------------------------------------------
    $display("\n---- PART A : delay-scale sweep, %0d CRPs, enrolled at 100 %% ------------", nstat);
    for (grp = 0; grp < NGRP; grp = grp + 1) begin
      if (grp == 0) $display("\n  TC_VAR = %0d ps, with noise", TC_A);
      if (grp == 1) $display("\n  TC_VAR = %0d ps, with noise", TC_B);
      if (grp == 2) $display("\n  TC_VAR = %0d ps, NOISE-FREE  (what is left is integer-ps truncation)", TC_A);
      $display("  scale   LSB     |SAR drift|          |unary drift|  conv. APUF  pass SAR  pass unary");
      $display("          (ps)    (LSB)     (ps)        (bins)         bit error   (d=%0d)     (d=%0d)", D_SAR, D_UNARY);
      for (k = 0; k < NSCALE; k = k + 1) begin
        idx = NSCALE * grp + k;
        // the LSB is itself made of silicon, so it scales with the die
        // temperature too: delay_t(T) = DT_SAR * TSCALE/100. A drift quoted
        // in LSB is therefore measured with a ruler that changes length.
        // The picosecond column is the physical quantity.
        lsb_ps = 1.0 * DT_SAR * (70 + 15 * k) / 100.0;
        $display("  %3d%%    %4.1f    %5.2f    %5.1f        %5.2f          %5.1f %%    %5.1f %%   %5.1f %%",
                 70 + 15 * k, lsb_ps,
                 1.0 * sar_drift[idx] / nstat,
                 lsb_ps * sar_drift[idx] / nstat,
                 1.0 * uni_drift[idx] / nstat,
                 100.0 * conv_err[idx] / nstat, 100.0 * sar_pass[idx] / nstat,
                 100.0 * uni_pass[idx] / nstat);
      end
    end
    // isolate the TC term: same scale, same noise seeds, only TC_VAR differs
    $display("\n  TC mismatch contribution, in ps  (TC=%0d row minus TC=%0d row)", TC_B, TC_A);
    $display("  scale    noise floor    with TC mismatch    difference");
    for (k = 0; k < NSCALE; k = k + 1) begin
      lsb_ps = 1.0 * DT_SAR * (70 + 15 * k) / 100.0;
      // NOTE: no "%+" flag here - Icarus accepts it, Vivado XSim does not
      // and prints the specifier literally. Plain %5.1f works on both.
      $display("  %3d%%      %5.1f ps        %5.1f ps         %5.1f ps",
               70 + 15 * k,
               lsb_ps * sar_drift[NSCALE*0 + k] / nstat,
               lsb_ps * sar_drift[NSCALE*1 + k] / nstat,
               lsb_ps * (sar_drift[NSCALE*1 + k] - sar_drift[NSCALE*0 + k]) / nstat);
    end

    $display("\n  Reading it. In LSB the TC=0 drift appears to RISE towards 70 %%,");
    $display("  which looks like temperature sensitivity but is not: arbiter noise");
    $display("  is a fixed number of ps, while the LSB shrinks with the silicon, so");
    $display("  the same jitter simply spans more codes. In ps the TC=0 drift is");
    $display("  flat at roughly the arbiter sigma across the whole sweep - that is");
    $display("  the ratiometric cancellation, and it is the column to quote.");
    $display("  The TC term is the DIFFERENCE above: near zero at 100 %% and growing");
    $display("  symmetrically with |scale-100|, as a mismatch model predicts.");
    $display("  Caveat: the uniform scaling cancels by construction in this model,");
    $display("  so this is a consistency check, not proof that real LUT and routing");
    $display("  delays share one temperature coefficient - that needs hardware.");

    //----------------------------------------------------------------
    $display("\n---- PART B : combiner, core 2 five times noisier, %0d CRPs -----------", nstat);
    $display("  combiner     mean |error|   worst |error|   pass rate (d=%0d)", D_SAR);
    $display("  mean          %6.2f          %4d          %5.1f %%",
             1.0 * mean_err_sum / nstat, mean_worst, 100.0 * mean_pass / nstat);
    $display("  median        %6.2f          %4d          %5.1f %%",
             1.0 * med_err_sum / nstat, med_worst, 100.0 * med_pass / nstat);
    $display("  noisy core 2 alone: mean |error| %0.2f LSB", 1.0 * core_err_sum2 / nstat);
    $display("\n  why the median fails (%0d failures):", nstat - med_pass);
    $display("    noisy core 2 was the median in both measurements : %0d", n_fail_passthru);
    $display("    noisy core 2 was the median in one of them        : %0d", n_fail_swap);
    $display("    core 2 not the median in either                   : %0d", n_fail_other);
    $display("  core 2 is the enrolment median in %0d/%0d CRPs; switches overall: %0d",
             n_noisy_mid, nstat, n_swap);
    $display("\n  NEGATIVE RESULT. Median-of-3 is continuous and never moves more than");
    $display("  the worst core (checked on every CRP above), so a core switch is not");
    $display("  a jump. It fails because whenever the noisy core is the middle value -");
    $display("  at enrolment, at re-measurement, or both - its error goes through at");
    $display("  FULL weight, while the mean always divides it by 3. A median only");
    $display("  rejects a bad input when the other inputs agree with each other");
    $display("  (replicas of one quantity); independent PUF cores do not.");

    $display("\n---- SUMMARY --------------------------------------------------------");
    if (errors == 0) $display("  TEST PASSED  -  %0d error(s)", errors);
    else             $display("  TEST FAILED  -  %0d error(s)", errors);
    $display("======================================================================");
    #(20 * CLK_HALF);
    $finish;
  end

  initial begin
    #(64'd50_000_000_000);
    $display("  ERROR: simulation timeout");
    $finish;
  end

endmodule
