//======================================================================
//  tb_ddq_apuf.v  -  self-checking testbench for the unary DDQ-APUF
//
//  Reproduces the paper's reliability / uniqueness / uniformity metrics.
//
//  Enrolment is REALISTIC: the reference R_O for each challenge is the
//  first noisy measurement of chip 0, exactly what a verifier would store.
//  Distances to a noise-free "golden" twin are also reported, but only as
//  a diagnostic - a golden reference halves the error variance and makes
//  every reliability figure optimistic.
//
//  Self-checks (any failure -> TEST FAILED):
//    * the golden twin returns a valid thermometer code
//    * the golden twin is bit-identical on every re-measurement
//    * the verifier recovers R_O from R_L by the inverse LFSR shift
//    * all four DUTs finish on the same clock edge
//
//  Output: human-readable tables plus "CSV,..." records for plot_ddq.py.
//  Vivado: set the simulation run time to "-all" (create_project.tcl does
//  this); the testbench ends itself with $finish.
//======================================================================
`timescale 1ps / 1ps

module tb_ddq_apuf;

  localparam integer N        = 32;
  localparam integer NDLY     = 6;
  localparam integer DELAY_T  = 30;        // unary quantisation step [ps]
  localparam integer NOISE_PS = 8;         // sigma = 8.5 ps
  localparam integer D_TOL    = 3;         // paper's tolerance (Algorithm 1)
  localparam integer NCHAL    = 64;
  localparam integer NREP     = 10;
  localparam integer CLK_HALF = 5000;      // 100 MHz
  localparam integer SL_OFFSET = 0;        // extra LFSR shifts (README: 8 -> ~40 % uniqueness)

  // the "silicon" of the three chips; shared with tb_ddq_sar.v
  localparam [31:0] CHIP0 = 32'h1234_5678;
  localparam [31:0] CHIP1 = 32'h8765_4321;
  localparam [31:0] CHIP2 = 32'h0BAD_F00D;
  localparam [31:0] CSEED = 32'h5EED_1234; // challenge generator seed

  reg          clk = 1'b0, rst_n = 1'b0, start = 1'b0;
  reg  [N-1:0] chal = {N{1'b0}};
  reg  [3:0]   sl   = 4'd0;
  always #(CLK_HALF) clk = ~clk;

  wire [12:0] ro_g, ro0, ro1, ro2;
  wire [12:0] rl_g, rl0, rl1, rl2;
  wire        dn_g, dn0, dn1, dn2;

  ddq_apuf_top #(.N(N), .NDLY(NDLY), .DELAY_T(DELAY_T), .NOISE_PS(0),
                 .SL_OFFSET(SL_OFFSET), .PUF_SEED(CHIP0)) dut_ideal (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl),
    .r_o(ro_g), .r_l(rl_g), .phase(), .busy(), .done(dn_g));

  ddq_apuf_top #(.N(N), .NDLY(NDLY), .DELAY_T(DELAY_T), .NOISE_PS(NOISE_PS),
                 .SL_OFFSET(SL_OFFSET), .PUF_SEED(CHIP0)) dut0 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl),
    .r_o(ro0), .r_l(rl0), .phase(), .busy(), .done(dn0));

  ddq_apuf_top #(.N(N), .NDLY(NDLY), .DELAY_T(DELAY_T), .NOISE_PS(NOISE_PS),
                 .SL_OFFSET(SL_OFFSET), .PUF_SEED(CHIP1)) dut1 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl),
    .r_o(ro1), .r_l(rl1), .phase(), .busy(), .done(dn1));

  ddq_apuf_top #(.N(N), .NDLY(NDLY), .DELAY_T(DELAY_T), .NOISE_PS(NOISE_PS),
                 .SL_OFFSET(SL_OFFSET), .PUF_SEED(CHIP2)) dut2 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(chal), .sl_sel(sl),
    .r_o(ro2), .r_l(rl2), .phase(), .busy(), .done(dn2));

  //------------------------------------------------------------------
  // helpers
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

  // valid thermometer: every '1' has a '1' above it (R[i]=1 -> R[i+1]=1)
  function is_thermo;
    input [12:0] v;
    begin is_thermo = ((({v[11:0], 1'b0}) & ~v) == 13'd0); end
  endfunction

  // verifier side: undo S_L shifts of x^13+x^4+x^3+x+1 (Fibonacci, left)
  function [12:0] lfsr_inv;
    input [12:0] v;
    input [4:0]  s;
    integer k;
    reg [12:0] t;
    begin
      t = v;
      for (k = 0; k < s; k = k + 1) t = {t[0] ^ t[4] ^ t[3] ^ t[1], t[12:1]};
      lfsr_inv = t;
    end
  endfunction

  // print a 13-bit word as R[0] R[1] ... R[12] (paper order, bit 0 first)
  task put13;
    input [12:0] v;
    integer j;
    begin for (j = 0; j < 13; j = j + 1) $write("%b", v[j]); end
  endtask

  integer errors;
  integer cycles;

  task run_crp;
    input [N-1:0] c;
    input [3:0]   s;
    begin
      @(negedge clk);
      chal = c; sl = s; start = 1'b1;
      @(negedge clk);
      start  = 1'b0;
      cycles = 1;
      while (dn0 !== 1'b1) begin
        @(negedge clk);
        cycles = cycles + 1;
      end
      if ((dn_g !== 1'b1) || (dn1 !== 1'b1) || (dn2 !== 1'b1)) begin
        errors = errors + 1;
        $display("  ERROR: DUTs did not finish together (challenge %h)", c);
      end
      @(negedge clk);
    end
  endtask

  task check_lfsr;
    input [12:0] r_o;
    input [12:0] r_l;
    input [3:0]  s;
    reg   [12:0] seed;
    begin
      seed = (r_o == 13'd0) ? 13'd1 : r_o;           // same rule as the RTL
      if (lfsr_inv(r_l, s + SL_OFFSET) !== seed) begin     // 5-bit, as in the RTL
        errors = errors + 1;
        $display("  ERROR: LFSR recovery failed  R_O=%b R_L=%b S_L=%0d", r_o, r_l, s);
      end
    end
  endtask

  task row;
    input [N-1:0]   c;
    input [8*5-1:0] name;
    input [12:0]    r_o;
    input [12:0]    r_l;
    begin
      $write("  %h  %s  ", c, name); put13(r_o);
      $write("  %2d   %2d   %2d   ", ones13(r_o), 13 - ones13(r_o), sl);
      put13(r_l); $display("");
    end
  endtask

  //------------------------------------------------------------------
  // statistics
  //------------------------------------------------------------------
  integer i, r, d, k, cs;
  reg [N-1:0] cvec;
  reg [12:0]  e0, e1, e2, el0, el1, el2, g;

  integer n_rep, n_inter, n_bitobs;
  integer exact, conv_err, conv_err_g, hd_sum_ro, hd_sum_rl, sat;
  integer max_hd, max_hd_g;
  integer rel   [0:13];       // re-measurements with HD <= d  (noisy enrolment)
  integer rel_g [0:13];       // same against the golden twin (diagnostic)
  integer fa    [0:13];       // inter-chip pairs with HD <= d (false accept)
  integer bit_ro[0:12], bit_rl[0:12];
  integer hist  [0:13];
  integer ones_ro_tot, ones_rl_tot, dmin;

  task inter_pair;
    input [12:0] a_o, b_o, a_l, b_l;
    integer h, dd;
    begin
      h = hd13(a_o, b_o);
      hd_sum_ro = hd_sum_ro + h;
      hd_sum_rl = hd_sum_rl + hd13(a_l, b_l);
      for (dd = 0; dd <= 13; dd = dd + 1) if (h <= dd) fa[dd] = fa[dd] + 1;
      n_inter = n_inter + 1;
      $display("CSV,INTER,%0d,%0d", h, hd13(a_l, b_l));
    end
  endtask

  task bits_add;
    input [12:0] vo, vl;
    integer j;
    begin
      for (j = 0; j < 13; j = j + 1) begin
        bit_ro[j] = bit_ro[j] + vo[j];
        bit_rl[j] = bit_rl[j] + vl[j];
      end
      n_bitobs = n_bitobs + 1;
    end
  endtask

  initial begin
    errors = 0; n_rep = 0; n_inter = 0; n_bitobs = 0;
    exact = 0; conv_err = 0; conv_err_g = 0; hd_sum_ro = 0; hd_sum_rl = 0;
    sat = 0; max_hd = 0; max_hd_g = 0; ones_ro_tot = 0; ones_rl_tot = 0;
    for (d = 0; d <= 13; d = d + 1) begin rel[d] = 0; rel_g[d] = 0; fa[d] = 0; hist[d] = 0; end
    for (d = 0; d < 13; d = d + 1)  begin bit_ro[d] = 0; bit_rl[d] = 0; end
    cs = CSEED;

`ifdef DDQ_VCD
    $dumpfile("ddq_apuf.vcd");
    $dumpvars(0, tb_ddq_apuf.dut_ideal);
`endif

    $display("======================================================================");
    $display(" DDQ-APUF  -  %0d-stage core, %0d delay units/path, delay_t = %0d ps", N, NDLY, DELAY_T);
    $display(" arbiter noise sigma = 8.5 ps (NOISE_PS = %0d), tolerance d = %0d", NOISE_PS, D_TOL);
    $display(" enrolment = first noisy measurement of chip 0 (realistic)");
    $display("======================================================================");

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(negedge clk);

    //----------------------------------------------------------------
    $display("\n---- PART 1 : directed CRPs -----------------------------------------");
    $display("  bit order: R[0] first for BOTH R_O and R_L");
    $display("  challenge   chip   R_O            #1s  flip  S_L  R_L");
    for (k = 0; k < 4; k = k + 1) begin
      case (k)
        0: cvec = 32'h0000_0000;
        1: cvec = 32'hFFFF_FFFF;
        2: cvec = 32'hA5A5_A5A5;
        default: cvec = 32'h5A5A_5A5A;
      endcase
      run_crp(cvec, cvec[3:0]);
      row(cvec, "ideal", ro_g, rl_g);
      row(cvec, "chip0", ro0,  rl0);
      row(cvec, "chip1", ro1,  rl1);
      row(cvec, "chip2", ro2,  rl2);
      if (!is_thermo(ro_g)) begin
        errors = errors + 1;
        $display("  ERROR: golden R_O is not a thermometer code");
      end
      check_lfsr(ro_g, rl_g, sl); check_lfsr(ro0, rl0, sl);
      check_lfsr(ro1, rl1, sl);   check_lfsr(ro2, rl2, sl);
    end
    $display("  flip = index of the first '1' = 13 - #1s   (%0d clock cycles for S_L = %0d)",
             cycles, sl);
`ifdef DDQ_VCD
    $dumpoff;
`endif

    //----------------------------------------------------------------
    $display("\n---- PART 2/3 : %0d challenges x (1 enrolment + %0d re-measurements) --", NCHAL, NREP);
    for (i = 0; i < NCHAL; i = i + 1) begin
      cvec = $random(cs);

      // enrolment
      run_crp(cvec, cvec[3:0]);
      e0 = ro0; e1 = ro1; e2 = ro2; el0 = rl0; el1 = rl1; el2 = rl2; g = ro_g;
      if (!is_thermo(g)) begin
        errors = errors + 1;
        $display("  ERROR: golden R_O %b is not a thermometer code", g);
      end
      check_lfsr(ro0, rl0, sl); check_lfsr(ro1, rl1, sl); check_lfsr(ro2, rl2, sl);

      $display("CSV,FLIP,%0d", ones13(g));
      k = ones13(g);
      hist[k] = hist[k] + 1;
      if (ones13(e0) == 0 || ones13(e0) == 13) sat = sat + 1;
      if (ones13(e1) == 0 || ones13(e1) == 13) sat = sat + 1;
      if (ones13(e2) == 0 || ones13(e2) == 13) sat = sat + 1;

      inter_pair(e0, e1, el0, el1);
      inter_pair(e0, e2, el0, el2);
      inter_pair(e1, e2, el1, el2);
      bits_add(e0, el0); bits_add(e1, el1); bits_add(e2, el2);

      // re-measurements of chip 0
      for (r = 0; r < NREP; r = r + 1) begin
        run_crp(cvec, cvec[3:0]);
        if (ro_g !== g) begin
          errors = errors + 1;
          $display("  ERROR: golden twin not repeatable");
        end
        n_rep = n_rep + 1;
        if (hd13(ro0, e0) == 0) exact = exact + 1;
        if (ro0[6] !== e0[6]) conv_err   = conv_err + 1;
        if (ro0[6] !== g[6])  conv_err_g = conv_err_g + 1;
        if (hd13(ro0, e0) > max_hd)  max_hd   = hd13(ro0, e0);
        if (hd13(ro0, g)  > max_hd_g) max_hd_g = hd13(ro0, g);
        for (d = 0; d <= 13; d = d + 1) begin
          if (hd13(ro0, e0) <= d) rel[d]   = rel[d] + 1;
          if (hd13(ro0, g)  <= d) rel_g[d] = rel_g[d] + 1;
        end
        $display("CSV,REP,%0d,%0d,%0d,%0d", hd13(ro0, e0),
                 (ro0[6] !== e0[6]) ? 1 : 0, hd13(ro0, g), (ro0[6] !== g[6]) ? 1 : 0);
      end
    end

    //----------------------------------------------------------------
    for (d = 0; d < 13; d = d + 1) begin
      ones_ro_tot = ones_ro_tot + bit_ro[d];
      ones_rl_tot = ones_rl_tot + bit_rl[d];
    end
    dmin = 13;
    for (d = 13; d >= 0; d = d - 1) if (rel[d] == n_rep) dmin = d;

    $display("\n---- RESULTS  (%0d re-measurements, %0d inter-chip pairs) ------------", n_rep, n_inter);
    $display("  reliability, DDQ-APUF (d = %0d)       : %6.2f %%  (%0d/%0d)",
             D_TOL, 100.0 * rel[D_TOL] / n_rep, rel[D_TOL], n_rep);
    $display("  exact R_O reproduction (d = 0)       : %6.2f %%", 100.0 * exact / n_rep);
    $display("  worst HD to enrolment                : %0d   (to golden twin: %0d)", max_hd, max_hd_g);
    $display("  smallest d with 100 %% reliability    : %0d", dmin);
    $display("  BER, conventional APUF (bit R[6])    : %6.2f %%  (%0d/%0d; vs golden %0.2f %%)",
             100.0 * conv_err / n_rep, conv_err, n_rep, 100.0 * conv_err_g / n_rep);
    $display("  uniqueness, inter-chip HD of R_O     : %6.2f %%   (thermometer code)",
             100.0 * hd_sum_ro / (13.0 * n_inter));
    $display("  uniqueness, inter-chip HD of R_L     : %6.2f %%   (ideal 50 %%)",
             100.0 * hd_sum_rl / (13.0 * n_inter));
    $display("  uniformity of R_O                    : %6.2f %%   (ideal 50 %%)",
             100.0 * ones_ro_tot / (13.0 * n_bitobs));
    $display("  uniformity of R_L (after LFSR)       : %6.2f %%   (ideal 50 %%)",
             100.0 * ones_rl_tot / (13.0 * n_bitobs));
    $display("  saturated enrolments (all-0 / all-1) : %6.2f %%  (%0d/%0d)",
             100.0 * sat / (3.0 * NCHAL), sat, 3 * NCHAL);
    $display("  CRPs discarded                       :   0.00 %%");

    $display("\n  tolerance trade-off (HD <= d)");
    $display("     d   legit accepted   golden-ref   foreign accepted");
    for (d = 0; d <= 7; d = d + 1)
      $display("    %2d     %6.2f %%       %6.2f %%      %6.2f %%", d,
               100.0 * rel[d] / n_rep, 100.0 * rel_g[d] / n_rep, 100.0 * fa[d] / n_inter);

    $display("\n  per-bit uniformity  (paper Fig. 12)   n = %0d per bit", n_bitobs);
    $display("    bit :   R_O      R_L");
    for (d = 0; d < 13; d = d + 1) begin
      $display("    R[%2d]:  %5.1f%%   %5.1f%%", d,
               100.0 * bit_ro[d] / n_bitobs, 100.0 * bit_rl[d] / n_bitobs);
      $display("CSV,BIT,%0d,%0d,%0d,%0d", d, bit_ro[d], bit_rl[d], n_bitobs);
    end

    $display("\n  number of '1's in golden R_O  [Fig. 6(b)]");
    for (d = 0; d <= 13; d = d + 1) begin
      $write("    %2d : ", d);
      for (k = 0; k < hist[d]; k = k + 1) $write("*");
      $display("  (%0d)", hist[d]);
    end

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
