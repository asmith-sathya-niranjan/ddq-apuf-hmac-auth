//======================================================================
//  tb_ddq_sar.v  -  unary DDQ-APUF (paper) vs SAR-DDQ-APUF (extension)
//
//  Identical silicon for both quantisers: same PUF seeds, same N, T_VAR,
//  same challenges, same measurement schedule as tb_ddq_apuf.v. The unary
//  numbers printed here are therefore the SAME numbers as in run.log.
//
//  Fairness rules (these were missing from the first version):
//    * enrolment is the first noisy measurement, for both quantisers
//    * the two codes use different LSBs (30 ps vs 4 ps), so every
//      tolerance is also reported as a window in picoseconds
//    * the headline comparison is at MATCHED reliability: each quantiser
//      at the smallest tolerance that accepted every legitimate
//      re-measurement - not unary d = 3 against SAR d = 6
//======================================================================
`timescale 1ps / 1ps

module tb_ddq_sar;

  localparam integer N        = 32;
  localparam integer NDLY     = 6;
  localparam integer DT_U     = 30;      // unary LSB [ps]
  localparam integer DT_S     = 4;       // SAR LSB   [ps]
  localparam integer NOISE_PS = 8;
  localparam integer D_PAPER  = 3;       // paper's unary tolerance
  localparam integer NCHAL    = 64;
  localparam integer NREP     = 10;
  localparam integer CLK_HALF = 5000;
  localparam integer DMAXU    = 13;
  localparam integer DMAXS    = 40;

  localparam [31:0] CHIP0 = 32'h1234_5678;
  localparam [31:0] CHIP1 = 32'h8765_4321;
  localparam [31:0] CHIP2 = 32'h0BAD_F00D;
  localparam [31:0] CSEED = 32'h5EED_1234;

  reg          clk = 1'b0, rst_n = 1'b0, start = 1'b0;
  reg  [N-1:0] chal = {N{1'b0}};
  reg  [3:0]   sl   = 4'd0;
  always #(CLK_HALF) clk = ~clk;

  wire [12:0]        ug, u0, u1, u2;
  wire               dug, du0, du1, du2;
  wire signed [7:0]  sg, s0, s1, s2;
  wire               dsg, ds0, ds1, ds2;

  // ---- unary (paper) -------------------------------------------------
  ddq_apuf_top #(.N(N), .NDLY(NDLY), .DELAY_T(DT_U), .NOISE_PS(0),        .PUF_SEED(CHIP0)) dut_u_ideal (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl), .r_o(ug), .r_l(), .phase(), .busy(), .done(dug));
  ddq_apuf_top #(.N(N), .NDLY(NDLY), .DELAY_T(DT_U), .NOISE_PS(NOISE_PS), .PUF_SEED(CHIP0)) dut_u0 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl), .r_o(u0), .r_l(), .phase(), .busy(), .done(du0));
  ddq_apuf_top #(.N(N), .NDLY(NDLY), .DELAY_T(DT_U), .NOISE_PS(NOISE_PS), .PUF_SEED(CHIP1)) dut_u1 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl), .r_o(u1), .r_l(), .phase(), .busy(), .done(du1));
  ddq_apuf_top #(.N(N), .NDLY(NDLY), .DELAY_T(DT_U), .NOISE_PS(NOISE_PS), .PUF_SEED(CHIP2)) dut_u2 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl), .r_o(u2), .r_l(), .phase(), .busy(), .done(du2));

  // ---- SAR (extension) -----------------------------------------------
  ddq_sar_top #(.N(N), .NDLY(NDLY), .DELAY_T(DT_S), .NOISE_PS(0),        .PUF_SEED(CHIP0)) dut_s_ideal (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl), .code(sg), .mag(), .sign(), .r_l(), .step(), .busy(), .done(dsg));
  ddq_sar_top #(.N(N), .NDLY(NDLY), .DELAY_T(DT_S), .NOISE_PS(NOISE_PS), .PUF_SEED(CHIP0)) dut_s0 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl), .code(s0), .mag(), .sign(), .r_l(), .step(), .busy(), .done(ds0));
  ddq_sar_top #(.N(N), .NDLY(NDLY), .DELAY_T(DT_S), .NOISE_PS(NOISE_PS), .PUF_SEED(CHIP1)) dut_s1 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl), .code(s1), .mag(), .sign(), .r_l(), .step(), .busy(), .done(ds1));
  ddq_sar_top #(.N(N), .NDLY(NDLY), .DELAY_T(DT_S), .NOISE_PS(NOISE_PS), .PUF_SEED(CHIP2)) dut_s2 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl), .code(s2), .mag(), .sign(), .r_l(), .step(), .busy(), .done(ds2));

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

  task put13;
    input [12:0] v;
    integer j;
    begin for (j = 0; j < 13; j = j + 1) $write("%b", v[j]); end
  endtask

  integer errors;
  integer cyc, cyc_u, cyc_s, cyc_uq, cyc_sq;
  reg     got_u, got_s, got_uq, got_sq;

  // run one CRP on all eight instances; also measure latency
  task run_crp;
    input [N-1:0] c;
    input [3:0]   s;
    begin
      @(negedge clk);
      chal = c; sl = s; start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      cyc = 1; got_u = 0; got_s = 0; got_uq = 0; got_sq = 0;
      while (!(got_u && got_s)) begin
        if (!got_uq && dut_u0.core_done === 1'b1) begin got_uq = 1; cyc_uq = cyc; end
        if (!got_sq && dut_s0.sar_done  === 1'b1) begin got_sq = 1; cyc_sq = cyc; end
        if (!got_u  && du0 === 1'b1) begin got_u = 1; cyc_u = cyc;
          if ((dug !== 1'b1) || (du1 !== 1'b1) || (du2 !== 1'b1)) begin
            errors = errors + 1; $display("  ERROR: unary DUTs out of step");
          end
        end
        if (!got_s  && ds0 === 1'b1) begin got_s = 1; cyc_s = cyc;
          if ((dsg !== 1'b1) || (ds1 !== 1'b1) || (ds2 !== 1'b1)) begin
            errors = errors + 1; $display("  ERROR: SAR DUTs out of step");
          end
        end
        @(negedge clk);
        cyc = cyc + 1;
      end
      @(negedge clk);
    end
  endtask

  //------------------------------------------------------------------
  integer i, r, d, k, cs, n_rep, n_inter;
  reg [N-1:0]  cvec;
  reg [12:0]   eu0, eu1, eu2, gu;
  integer      es0, es1, es2, gs;
  integer      rel_u[0:DMAXU], fa_u[0:DMAXU];
  integer      rel_s[0:DMAXS], fa_s[0:DMAXS];
  integer      rel_sg[0:DMAXS];
  integer      exact_u, exact_s, sat_u, sat_s, max_u, max_s, max_sg;
  integer      dmin_u, dmin_s;
  real         sum_c, sum_c2, sd_ps;
  integer      seen[0:127];
  integer      nd_u, nd_s;
  reg          seen_u[0:13];

  task inter_pair;
    input [12:0] a_u, b_u;
    input integer a_s, b_s;
    integer hu, hs, dd;
    begin
      hu = hd13(a_u, b_u);
      hs = iabs(a_s - b_s);
      for (dd = 0; dd <= DMAXU; dd = dd + 1) if (hu <= dd) fa_u[dd] = fa_u[dd] + 1;
      for (dd = 0; dd <= DMAXS; dd = dd + 1) if (hs <= dd) fa_s[dd] = fa_s[dd] + 1;
      n_inter = n_inter + 1;
      $display("CSV,SARINTER,%0d,%0d", hu, hs);
    end
  endtask

  task sat_add;
    input [12:0] vu;
    input integer vs;
    begin
      if (ones13(vu) == 0 || ones13(vu) == 13) sat_u = sat_u + 1;
      if (iabs(vs) == 63) sat_s = sat_s + 1;
    end
  endtask

  initial begin
    errors = 0; n_rep = 0; n_inter = 0;
    exact_u = 0; exact_s = 0; sat_u = 0; sat_s = 0; max_u = 0; max_s = 0; max_sg = 0;
    sum_c = 0.0; sum_c2 = 0.0; nd_u = 0; nd_s = 0;
    for (d = 0; d <= DMAXU; d = d + 1) begin rel_u[d] = 0; fa_u[d] = 0; end
    for (d = 0; d <= DMAXS; d = d + 1) begin rel_s[d] = 0; fa_s[d] = 0; rel_sg[d] = 0; end
    for (d = 0; d < 128; d = d + 1) seen[d] = 0;
    for (d = 0; d < 14;  d = d + 1) seen_u[d] = 1'b0;
    cs = CSEED;

    $display("======================================================================");
    $display(" unary DDQ-APUF (paper)  vs  SAR-DDQ-APUF (extension)");
    $display(" identical silicon: %0d stages, T_VAR = 16 ps, noise sigma = 8.5 ps", N);
    $display(" unary: LSB %0d ps, range +/-%0d ps     SAR: LSB %0d ps, range +/-%0d ps",
             DT_U, 6 * DT_U, DT_S, 63 * DT_S);
    $display(" enrolment = first noisy measurement, for both");
    $display("======================================================================");

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(negedge clk);

    //----------------------------------------------------------------
    $display("\n---- the same delay difference, seen by both quantisers (ideal) -----");
    $display("  challenge   unary R_O (R[0] first)  #1s  dD bin (ps)   |  SAR code  dD bin (ps)");
    for (k = 0; k < 4; k = k + 1) begin
      case (k)
        0: cvec = 32'h0000_0000;
        1: cvec = 32'hFFFF_FFFF;
        2: cvec = 32'hA5A5_A5A5;
        default: cvec = 32'h5A5A_5A5A;
      endcase
      run_crp(cvec, cvec[3:0]);
      $write("  %h   ", cvec); put13(ug);
      // k ones  <=>  dD in (DT*(k-7), DT*(k-6)]
      $write("            %2d  (%4d,%4d]   |", ones13(ug), DT_U * (ones13(ug) - 7), DT_U * (ones13(ug) - 6));
      if (sg > 0)      $display("   %4d     (%4d,%4d]", sg, DT_S * sg,     DT_S * (sg + 1));
      else if (sg < 0) $display("   %4d     (%4d,%4d]", sg, DT_S * (sg - 1), DT_S * sg);
      else             $display("   %4d     (%4d,%4d]", sg, -DT_S, DT_S);
      // consistency: the two bins must overlap (same silicon, noise-free)
      if (!(((sg > 0) ? DT_S * (sg + 1) : ((sg < 0) ? DT_S * sg : DT_S)) >
            ((ones13(ug) == 0)  ? -100000 : DT_U * (ones13(ug) - 7)) &&
            ((sg > 0) ? DT_S * sg : ((sg < 0) ? DT_S * (sg - 1) : -DT_S)) <
            ((ones13(ug) == 13) ?  100000 : DT_U * (ones13(ug) - 6)))) begin
        errors = errors + 1;
        $display("  ERROR: unary and SAR disagree on dD");
      end
    end
    $display("  latency: unary %0d cycles to R_O, SAR %0d cycles to code (+LFSR: %0d / %0d)",
             cyc_uq, cyc_sq, cyc_u, cyc_s);

    //----------------------------------------------------------------
    $display("\n---- %0d challenges x (1 enrolment + %0d re-measurements) ------------", NCHAL, NREP);
    for (i = 0; i < NCHAL; i = i + 1) begin
      cvec = $random(cs);
      run_crp(cvec, cvec[3:0]);
      eu0 = u0; eu1 = u1; eu2 = u2; gu = ug;
      es0 = s0; es1 = s1; es2 = s2; gs = sg;

      $display("CSV,SARFLIP,%0d,%0d", ones13(gu), gs);
      if (seen[gs + 63] == 0) nd_s = nd_s + 1;
      seen[gs + 63] = seen[gs + 63] + 1;
      k = ones13(gu);
      if (!seen_u[k]) nd_u = nd_u + 1;
      seen_u[k] = 1'b1;
      sum_c  = sum_c + gs;
      sum_c2 = sum_c2 + gs * gs;

      // the two bins must overlap for the noise-free twins
      if (!(((gs > 0) ? DT_S * (gs + 1) : ((gs < 0) ? DT_S * gs : DT_S)) >
            ((ones13(gu) == 0)  ? -100000 : DT_U * (ones13(gu) - 7)) &&
            ((gs > 0) ? DT_S * gs : ((gs < 0) ? DT_S * (gs - 1) : -DT_S)) <
            ((ones13(gu) == 13) ?  100000 : DT_U * (ones13(gu) - 6)))) begin
        errors = errors + 1;
        $display("  ERROR: unary (%0d ones) and SAR (%0d) disagree on dD", ones13(gu), gs);
      end

      sat_add(eu0, es0); sat_add(eu1, es1); sat_add(eu2, es2);
      inter_pair(eu0, eu1, es0, es1);
      inter_pair(eu0, eu2, es0, es2);
      inter_pair(eu1, eu2, es1, es2);

      for (r = 0; r < NREP; r = r + 1) begin
        run_crp(cvec, cvec[3:0]);
        if (ug !== gu || sg !== gs) begin
          errors = errors + 1; $display("  ERROR: golden twin not repeatable");
        end
        n_rep = n_rep + 1;
        if (hd13(u0, eu0) == 0) exact_u = exact_u + 1;
        if (s0 == es0)          exact_s = exact_s + 1;
        if (hd13(u0, eu0)  > max_u)  max_u  = hd13(u0, eu0);
        if (iabs(s0 - es0) > max_s)  max_s  = iabs(s0 - es0);
        if (iabs(s0 - gs)  > max_sg) max_sg = iabs(s0 - gs);
        for (d = 0; d <= DMAXU; d = d + 1) if (hd13(u0, eu0)  <= d) rel_u[d]  = rel_u[d] + 1;
        for (d = 0; d <= DMAXS; d = d + 1) begin
          if (iabs(s0 - es0) <= d) rel_s[d]  = rel_s[d] + 1;
          if (iabs(s0 - gs)  <= d) rel_sg[d] = rel_sg[d] + 1;
        end
        $display("CSV,SARREP,%0d,%0d,%0d,%0d", hd13(u0, eu0), iabs(s0 - es0),
                 hd13(u0, gu), iabs(s0 - gs));
      end
    end

    //----------------------------------------------------------------
    dmin_u = DMAXU; for (d = DMAXU; d >= 0; d = d - 1) if (rel_u[d] == n_rep) dmin_u = d;
    dmin_s = DMAXS; for (d = DMAXS; d >= 0; d = d - 1) if (rel_s[d] == n_rep) dmin_s = d;
    sd_ps  = DT_S * $sqrt(sum_c2 / NCHAL - (sum_c / NCHAL) * (sum_c / NCHAL));

    $display("\n---- COMPARISON  (%0d re-measurements, %0d foreign pairs) -----------", n_rep, n_inter);
    $display("                                       unary (paper)     SAR (extension)");
    $display("  arbiter evaluations per CRP     :        13                  7");
    $display("  clock cycles to quantised code  :     %5d              %5d", cyc_uq, cyc_sq);
    $display("  LSB size                        :     %3d ps              %3d ps", DT_U, DT_S);
    $display("  levels                          :        14                127");
    $display("  range                           :  +/-%3d ps  (+/-6 LSB)  +/-%3d ps  (+/-63 LSB)", 6 * DT_U, 63 * DT_S);
    $display("  saturated enrolments            :     %5.1f %%             %5.1f %%",
             100.0 * sat_u / (3 * NCHAL), 100.0 * sat_s / (3 * NCHAL));
    $display("  distinct codes (golden, %0d CRPs):     %5d              %5d", NCHAL, nd_u, nd_s);
    $display("  sigma(dD) from SAR golden codes :                        %5.1f ps", sd_ps);
    $display("  exact reproduction              :     %5.1f %%             %5.1f %%",
             100.0 * exact_u / n_rep, 100.0 * exact_s / n_rep);
    $display("  worst error vs noisy enrolment  :     %3d bins           %3d LSB  (vs golden: %0d)",
             max_u, max_s, max_sg);

    $display("\n  operating points                   tol.  window    reliability  false accept");
    $display("  unary, paper d = %0d                  %2d   +/-%3d ps    %6.2f %%     %6.2f %%",
             D_PAPER, D_PAPER, DT_U * D_PAPER, 100.0 * rel_u[D_PAPER] / n_rep, 100.0 * fa_u[D_PAPER] / n_inter);
    $display("  unary, smallest d at 100 %%         %2d   +/-%3d ps    %6.2f %%     %6.2f %%",
             dmin_u, DT_U * dmin_u, 100.0 * rel_u[dmin_u] / n_rep, 100.0 * fa_u[dmin_u] / n_inter);
    if (dmin_u > 0)
      $display("  unary, one step tighter            %2d   +/-%3d ps    %6.2f %%     %6.2f %%",
               dmin_u - 1, DT_U * (dmin_u - 1), 100.0 * rel_u[dmin_u - 1] / n_rep,
               100.0 * fa_u[dmin_u - 1] / n_inter);
    $display("  SAR,   smallest d at 100 %%         %2d   +/-%3d ps    %6.2f %%     %6.2f %%",
             dmin_s, DT_S * dmin_s, 100.0 * rel_s[dmin_s] / n_rep, 100.0 * fa_s[dmin_s] / n_inter);
    $display("  (window = tolerance x LSB; for the unary HD metric it is approximate)");
    $display("  The unary code can only move its window in 30 ps steps, so it either");
    $display("  sits below the noise or well above it; SAR can place it at the noise.");
    $display("  SAR against a noise-free golden reference would need only d = %0d -", max_sg);
    $display("  that is the optimistic figure the first version reported.");

    $display("\n  full sweep, SAR                     d   window   reliability  false accept");
    for (d = 0; d <= 16; d = d + 2)
      $display("                                     %2d  +/-%3d ps  %6.2f %%    %6.2f %%",
               d, DT_S * d, 100.0 * rel_s[d] / n_rep, 100.0 * fa_s[d] / n_inter);

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
