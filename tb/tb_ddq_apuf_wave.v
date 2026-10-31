//======================================================================
//  tb_ddq_apuf.v  -  WAVEFORM version
//
//  Same DUT, stripped down so that EPWave can load the whole VCD and so
//  that the arbiter race is visible without extreme zooming:
//
//    * 8 stages instead of 32  -> short signal paths
//    * all delays scaled x10   -> the delay difference is ~1 ns, i.e. a
//                                 visible fraction of the ~10 ns path,
//                                 instead of tens of ps out of 3.5 ns
//    * only 3 directed CRPs, no statistics loop -> ~3 us of simulation
//    * no $dumpoff; only the noise-free instance is dumped in full
//
//  Use tb_ddq_apuf.v (the full version) for the actual metrics; this file
//  is only for looking at the picture.
//
//  Delays are ratios, so the quantisation behaviour is unchanged:
//  delay_t is still ~sigma(dD)/3.7, which is the calibration that matters.
//======================================================================

`timescale 1ps / 1ps

module tb_ddq_apuf;

  localparam integer N        = 8;        // short chain, easy to read
  localparam integer NDLY     = 6;
  localparam integer NDEV     = 3;
  localparam integer T_NOM    = 1000;     // 1 ns per stage
  localparam integer T_VAR    = 400;      // +/- 0.4 ns process spread
  localparam integer D_LO     = 100;
  localparam integer DELAY_T  = 250;      // quantisation step, 250 ps
  localparam integer NOISE_PS = 60;       // arbiter noise sigma
  localparam integer CLK_HALF = 10000;    // 20 ns period (path is ~10 ns)

  reg          clk   = 1'b0;
  reg          rst_n = 1'b0;
  reg          start = 1'b0;
  reg  [N-1:0] chal  = {N{1'b0}};
  wire [3:0]   sl_sel = chal[3:0];

  wire [13*NDEV-1:0] ro_bus, rl_bus;
  wire [NDEV-1:0]    done_bus;
  wire [4*NDEV-1:0]  ph_bus;

  wire [12:0] ro_ideal, rl_ideal;
  wire [3:0]  ph_ideal;
  wire        done_ideal;

  genvar g;
  generate
    for (g = 0; g < NDEV; g = g + 1) begin : g_dev
      ddq_apuf_top #(
        .N (N), .NDLY (NDLY), .T_NOM (T_NOM), .T_VAR (T_VAR),
        .D_LO (D_LO), .DELAY_T (DELAY_T), .NOISE_PS (NOISE_PS),
        .PUF_SEED (32'h1234_5678 + g * 32'h9E37_79B1)
      ) dut (
        .clk (clk), .rst_n (rst_n), .start (start),
        .challenge (chal), .sl_sel (sl_sel),
        .r_o (ro_bus[13*g +: 13]), .r_l (rl_bus[13*g +: 13]),
        .phase (ph_bus[4*g +: 4]), .busy (), .done (done_bus[g])
      );
    end
  endgenerate

  // noise-free twin of chip 0 -- this is the instance to look at
  ddq_apuf_top #(
    .N (N), .NDLY (NDLY), .T_NOM (T_NOM), .T_VAR (T_VAR),
    .D_LO (D_LO), .DELAY_T (DELAY_T), .NOISE_PS (0),
    .PUF_SEED (32'h1234_5678)
  ) dut_ideal (
    .clk (clk), .rst_n (rst_n), .start (start),
    .challenge (chal), .sl_sel (sl_sel),
    .r_o (ro_ideal), .r_l (rl_ideal),
    .phase (ph_ideal), .busy (), .done (done_ideal)
  );

  always #(CLK_HALF) clk = ~clk;

  // convenience aliases so the two racing edges sit at the top of EPWave
  wire race_top = dut_ideal.u_core.tdly[NDLY];
  wire race_bot = dut_ideal.u_core.bdly[NDLY];
  wire arb_q    = dut_ideal.u_core.resp;
  wire launch   = dut_ideal.u_ctrl.launch;

  integer i, k;
  reg [N-1:0] c_vec;

  function integer ones13;
    input [12:0] v;
    integer j;
    begin
      ones13 = 0;
      for (j = 0; j < 13; j = j + 1) ones13 = ones13 + v[j];
    end
  endfunction

  task print_ro;
    input [12:0] v;
    integer j;
    begin
      for (j = 0; j < 13; j = j + 1) $write("%b", v[j]);
    end
  endtask

  task run_crp;
    input [N-1:0] c;
    begin
      @(negedge clk);
      chal  = c;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      while (done_bus[0] !== 1'b1) @(negedge clk);
      @(negedge clk);
    end
  endtask

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(1, tb_ddq_apuf);              // top-level + the race aliases
    $dumpvars(0, tb_ddq_apuf.dut_ideal);    // full hierarchy of one instance only

    $display("======================================================================");
    $display(" DDQ-APUF waveform run : %0d stages, delay_t = %0d ps, stage ~%0d ps",
             N, DELAY_T, T_NOM);
    $display("======================================================================");
    $display("  challenge  chip   R_O (R[0]..R[12])  #1s  flip  R_L");

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(negedge clk);

    for (i = 0; i < 3; i = i + 1) begin
      case (i)
        0: c_vec = 8'h00;
        1: c_vec = 8'hA5;
        2: c_vec = 8'hFF;
      endcase

      run_crp(c_vec);

      $write("     %h    ideal  ", c_vec); print_ro(ro_ideal);
      $write("   %2d   %2d   %b\n", ones13(ro_ideal), 13 - ones13(ro_ideal), rl_ideal);
      for (k = 0; k < NDEV; k = k + 1) begin
        $write("     %h    chip%0d  ", c_vec, k); print_ro(ro_bus[13*k +: 13]);
        $write("   %2d   %2d   %b\n", ones13(ro_bus[13*k +: 13]),
               13 - ones13(ro_bus[13*k +: 13]), rl_bus[13*k +: 13]);
      end
      $display("  -- CRP %0d ends at %0t --", i, $realtime);
    end

    $display("======================================================================");
    $display("  In EPWave add: race_top, race_bot, arb_q, launch,");
    $display("  dut_ideal.u_ctrl.phase, up_cfg, lo_cfg, r_o");
    $display("======================================================================");

    #(10 * CLK_HALF);
    $finish;
  end

endmodule
