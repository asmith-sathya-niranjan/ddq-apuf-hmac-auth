//======================================================================
//  ddq_apuf.v
//
//  Delay Difference Quantization Arbiter PUF (DDQ-APUF)
//  RTL implementation of:
//     Y. Wang, G. Zhang, X. Mei, C. Gu,
//     "A High-Reliability, Non-CRP-Discard Arbiter PUF Based on Delay
//      Difference Quantization", IEEE TCAS-I, vol.72, no.2, Feb 2025.
//
//  Module map to the paper
//  -----------------------
//    ddq_switch      : one crossbar stage of the APUF chain (Fig. 2, Fig. 4)
//                      delays p_i,q_i (c=0, parallel) and u_i,v_i (c=1, cross)
//                      -> delta_i^0 = p_i - q_i , delta_i^1 = u_i - v_i  (2)
//    ddq_delay_unit  : one configurable (PDL / LUT-based) delay unit,
//                      low-latency or high-latency = DELAY_T  (Fig. 10, Fig. 11)
//    ddq_arbiter     : DFF arbiter, R = 1 when the UPPER path is faster
//                      (paper: dD = delay_bottom - delay_top, R = 1 if dD > 0) (1)
//    ddq_apuf_core   : N-stage chain + 6 delay units per path + arbiter (Fig. 5)
//    ddq_phase_ctrl  : FSM stepping S0..S12 and assembling the 13-bit R_O
//                      R[i] = eps( dt_{n-1} + (i-6)*delay_t )                (9)
//                      R_O  = (R[0],R[1],...,R[12])                          (10)
//    ddq_obfuscator  : 13-stage LFSR seeded with R_O, shifted S_L times,
//                      S_L taken from a 4-bit sub-challenge -> R_L (Sec. III-B)
//    ddq_apuf_top    : full CRP engine (challenge in -> R_O and R_L out)
//
//  Compile-time switches
//  ---------------------
//    (default)        : DDQ_BEHAVIORAL - #delay annotated simulation model.
//                       This is what gives visible arbiter flipping in the
//                       waveform and what reproduces the paper's statistics.
//    +define+DDQ_SYNTH: pure structural view for synthesis (no #delays).
//                       On a real FPGA the *timing* must come from placement
//                       (LOC/BEL constraints + LUT6 PDLs), see README.
//    +define+DDQ_DEBUG: arbiter prints the resolved delay difference in ps.
//
//  Timescale is 1ps/1ps: every delay number below is in picoseconds.
//
//  Vivado
//  ------
//    XSim (behavioural simulation) : compiles as-is, no defines needed.
//    Synthesis                     : Vivado predefines SYNTHESIS, which
//                                    selects the DDQ_SYNTH structural view
//                                    automatically (create_project.tcl also
//                                    passes -verilog_define DDQ_SYNTH).
//                                    That view instantiates Xilinx LUT6
//                                    primitives, so it is Vivado-specific.
//======================================================================

`timescale 1ps / 1ps

// Vivado synthesis predefines SYNTHESIS: pick the structural view there
`ifdef SYNTHESIS
  `ifndef DDQ_SYNTH
    `define DDQ_SYNTH
  `endif
`endif

`ifndef DDQ_SYNTH
  `define DDQ_BEHAVIORAL
`endif

//----------------------------------------------------------------------
// Elaboration-time "process variation" generator.
// Pure constant arithmetic (no constant functions) so that it elaborates
// on Icarus, XSim, ModelSim and Vivado synthesis alike.
//   DDQ_DEV(SEED,K,V) -> a repeatable integer in [-V, +V]
//----------------------------------------------------------------------
`define DDQ_MIX(X)      ((((X) * 32'd1103515245) + 32'd12345) & 32'h7fffffff)
`define DDQ_RND(S,K)    `DDQ_MIX(`DDQ_MIX((((S) ^ ((K) * 32'd2654435761))) & 32'h7fffffff))
`define DDQ_DEV(S,K,V)  ((((`DDQ_RND(S,K)) >> 6) % ((2*(V)) + 1)) - (V))


//======================================================================
//  ddq_switch : one APUF stage (pair of MUXes wired as a crossbar)
//
//        a_top --+--[p]--\        /-- z_top
//                 \       X (c=1)
//                  \[v]--/ \
//        a_bot --+--[q]--\  \----- z_bot
//                 \[u]---/
//
//   c = 0 : parallel  (a_top->z_top via p, a_bot->z_bot via q)
//   c = 1 : crossed   (a_bot->z_top via u, a_top->z_bot via v)
//======================================================================
module ddq_switch #(
  parameter integer D_P = 100,   // top -> top   (c = 0)
  parameter integer D_Q = 100,   // bot -> bot   (c = 0)
  parameter integer D_U = 100,   // bot -> top   (c = 1)
  parameter integer D_V = 100    // top -> bot   (c = 1)
) (
  input  wire a_top,
  input  wire a_bot,
  input  wire c,
  output wire z_top,
  output wire z_bot
);

`ifdef DDQ_BEHAVIORAL
  wire p, q, u, v;
  assign #(D_P) p = a_top;
  assign #(D_Q) q = a_bot;
  assign #(D_U) u = a_bot;
  assign #(D_V) v = a_top;

  assign z_top = c ? u : p;
  assign z_bot = c ? v : q;
`else
  // Synthesis view. DONT_TOUCH keeps the two MUXes from being merged or
  // optimised away; real symmetry comes from LOC/BEL placement constraints.
  (* DONT_TOUCH = "TRUE" *) wire z_top_i;
  (* DONT_TOUCH = "TRUE" *) wire z_bot_i;
  assign z_top_i = c ? a_bot : a_top;
  assign z_bot_i = c ? a_top : a_bot;
  assign z_top   = z_top_i;
  assign z_bot   = z_bot_i;
`endif

endmodule


//======================================================================
//  ddq_delay_unit : one configurable delay element
//    en = 0 -> low-latency  state (D_LO, "negligible" per the paper)
//    en = 1 -> high-latency state (D_LO + DELAY_T)
//  On a real Artix-7 this is a LUT6 used as a Programmable Delay Line:
//  the data enters A1 and A2..A6 select a longer or shorter internal
//  MUX path through the LUT (paper Fig. 10 / Fig. 11).
//======================================================================
module ddq_delay_unit #(
  parameter integer D_LO  = 10,
  parameter integer D_HI  = 30,
  parameter integer NCELL = 1     // synthesis view: LUT-PDL cells in series
                                  // (1 for a unary unit, 2^i for SAR weight i)
) (
  input  wire a,
  input  wire en,
  output wire z
);

`ifdef DDQ_BEHAVIORAL
  wire lo, hi;
  assign #(D_LO) lo = a;
  assign #(D_HI) hi = a;
  assign z = en ? hi : lo;
`else
  // Xilinx LUT6 used as a Programmable Delay Line. INIT = 0xAAAA... makes
  // O follow I0 for every value of I1..I5, so the logic function never
  // changes while the select bits change the internal path through the
  // LUT's mux tree, and with it the propagation delay. DONT_TOUCH stops
  // opt_design from trimming the "unused" select pins. Pin mapping and
  // placement (LOCK_PINS, LOC/BEL) belong in the XDC - see README.
  wire [NCELL:0] c;
  assign c[0] = a;
  genvar k;
  generate
    for (k = 0; k < NCELL; k = k + 1) begin : g_pdl
      (* DONT_TOUCH = "TRUE" *)
      LUT6 #(.INIT(64'hAAAA_AAAA_AAAA_AAAA)) u_pdl (
        .O (c[k+1]), .I0(c[k]),
        .I1(en), .I2(en), .I3(en), .I4(en), .I5(en));
    end
  endgenerate
  assign z = c[NCELL];
`endif

endmodule


//======================================================================
//  ddq_arbiter : the arbiter at the end of the two symmetric paths.
//  R = 1 when the UPPER path wins (paper eq. (1) with dD = t_bot - t_top).
//
//  Behavioural model: both arrival times are timestamped, the winner is
//  decided on (t_bot - t_top + noise). The additive noise emulates arbiter
//  metastability + supply/temperature jitter, which is precisely the effect
//  that makes a conventional APUF unreliable when dD ~ 0.
//======================================================================
module ddq_arbiter #(
  parameter integer NOISE_PS = 8,          // noise sigma = sqrt(N*(N+1)) ps
                                           // (8 -> 8.5 ps)
  parameter integer SEED     = 32'h0000_ACE1
) (
  input  wire arm,      // level-high: clear the arbiter before a new phase
  input  wire a_top,
  input  wire a_bot,
  output reg  q
);

`ifdef DDQ_BEHAVIORAL
  real    t_top, t_bot;
  reg     got_top, got_bot;
  integer nseed;
  real    delta, noise;

  initial begin
    nseed   = SEED;
    q       = 1'b0;
    got_top = 1'b0;
    got_bot = 1'b0;
    t_top   = 0.0;
    t_bot   = 0.0;
    delta   = 0.0;
    noise   = 0.0;
  end

  always @(arm)
    if (arm) begin
      got_top = 1'b0;
      got_bot = 1'b0;
      q       = 1'b0;
    end

  always @(posedge a_top) begin
    t_top   = $realtime;
    got_top = 1'b1;
    ddq_resolve;
  end

  always @(posedge a_bot) begin
    t_bot   = $realtime;
    got_bot = 1'b1;
    ddq_resolve;
  end

  // sum of three integer uniforms on [-N, +N]: zero mean,
  // variance 3*((2N+1)^2-1)/12 = N(N+1), i.e. sigma = 8.49 ps for N = 8
  task ddq_resolve;
    begin
      if (got_top && got_bot) begin
        delta = t_bot - t_top;                       // > 0  => upper path wins
        noise = ($random(nseed) % (NOISE_PS + 1)) +
                ($random(nseed) % (NOISE_PS + 1)) +
                ($random(nseed) % (NOISE_PS + 1));
        q = ((delta + noise) > 0.0) ? 1'b1 : 1'b0;
`ifdef DDQ_DEBUG
        $display("[%0t] arbiter: dD = %0.1f ps, noise = %0.1f ps -> R = %b",
                 $realtime, delta, noise, q);
`endif
      end
    end
  endtask

`else
  // Synthesis view: a DFF clocked by the lower path, sampling the upper path.
  // In Vivado this must be constrained with set_disable_timing / false paths.
  (* ASYNC_REG = "TRUE", DONT_TOUCH = "TRUE" *)
  always @(posedge a_bot or posedge arm)
    if (arm) q <= 1'b0;
    else     q <= a_top;
`endif

endmodule


//======================================================================
//  ddq_apuf_core : N-stage APUF chain + NDLY delay units per path + arbiter
//                  (paper Fig. 5)
//======================================================================
module ddq_apuf_core #(
  parameter integer N        = 32,               // number of APUF stages
  parameter integer NDLY     = 6,                // delay units per path
  parameter integer T_NOM    = 100,              // nominal stage delay   [ps]
  parameter integer T_VAR    = 16,               // +/- process spread    [ps]
  parameter integer D_LO     = 10,               // delay unit, low state [ps]
  parameter integer DELAY_T  = 30,               // quantisation step     [ps]
  parameter integer U_VAR    = 2,                // delay unit mismatch   [ps]
  parameter integer NOISE_PS = 8,                // arbiter noise sigma   [ps]
  parameter integer W_MODE   = 0,                // 0 = unary units (paper),
                                                 // 1 = binary weighted (SAR)
  parameter integer TSCALE   = 100,              // die temperature as a delay
                                                 // scale, in percent of nominal
                                                 // (hotter silicon = slower)
  parameter integer TC_VAR   = 10,               // per-path mismatch in the
                                                 // temperature coefficient [ps]
  parameter integer PUF_SEED = 32'h1234_5678,    // "silicon" of this chip
  parameter integer NSALT    = 0                 // arbiter-noise seed salt:
                                                 // same silicon, independent
                                                 // noise (0 = legacy seed)
) (
  input  wire            launch,      // rising edge = challenge pulse
  input  wire            arm,         // clear arbiter between phases
  input  wire [N-1:0]    challenge,
  input  wire [NDLY-1:0] up_cfg,      // 1 = high-latency, upper path
  input  wire [NDLY-1:0] lo_cfg,      // 1 = high-latency, lower path
  output wire            resp
);

  wire [N:0] tnet, bnet;
  assign tnet[0] = launch;
  assign bnet[0] = launch;

  genvar i;

  //------------------------------------------------------------------
  // the switch chain
  //------------------------------------------------------------------
  generate
    for (i = 0; i < N; i = i + 1) begin : g_stage
      // nominal delay, then the temperature model:
      //   d(T) = d * TSCALE/100          <- uniform, common to both paths
      //        + (TSCALE-100) * tc/100   <- mismatch, different per path
      // the uniform term is what cancels in the quantised ratio dD/delay_t
      // deviations are taken into signed integers first, so every later
      // expression is plain signed arithmetic on every simulator
      localparam integer EP  = `DDQ_DEV(PUF_SEED, (4*i + 0), T_VAR);
      localparam integer EQ  = `DDQ_DEV(PUF_SEED, (4*i + 1), T_VAR);
      localparam integer EU  = `DDQ_DEV(PUF_SEED, (4*i + 2), T_VAR);
      localparam integer EV  = `DDQ_DEV(PUF_SEED, (4*i + 3), T_VAR);
      localparam integer DP0 = T_NOM + EP;
      localparam integer DQ0 = T_NOM + EQ;
      localparam integer DU0 = T_NOM + EU;
      localparam integer DV0 = T_NOM + EV;
      localparam integer TP  = `DDQ_DEV(PUF_SEED, (4*i + 5000), TC_VAR);
      localparam integer TQ  = `DDQ_DEV(PUF_SEED, (4*i + 5001), TC_VAR);
      localparam integer TU  = `DDQ_DEV(PUF_SEED, (4*i + 5002), TC_VAR);
      localparam integer TV  = `DDQ_DEV(PUF_SEED, (4*i + 5003), TC_VAR);
      localparam integer DP  = (DP0 * TSCALE)/100 + ((TSCALE-100) * TP)/100;
      localparam integer DQ  = (DQ0 * TSCALE)/100 + ((TSCALE-100) * TQ)/100;
      localparam integer DU  = (DU0 * TSCALE)/100 + ((TSCALE-100) * TU)/100;
      localparam integer DV  = (DV0 * TSCALE)/100 + ((TSCALE-100) * TV)/100;

      (* DONT_TOUCH = "TRUE", KEEP_HIERARCHY = "YES" *)
      ddq_switch #(.D_P(DP), .D_Q(DQ), .D_U(DU), .D_V(DV)) u_stage (
        .a_top (tnet[i]),
        .a_bot (bnet[i]),
        .c     (challenge[i]),
        .z_top (tnet[i+1]),
        .z_bot (bnet[i+1])
      );
    end
  endgenerate

  //------------------------------------------------------------------
  // the two banks of configurable delay units
  //------------------------------------------------------------------
  wire [NDLY:0] tdly, bdly;
  assign tdly[0] = tnet[N];
  assign bdly[0] = bnet[N];

  generate
    for (i = 0; i < NDLY; i = i + 1) begin : g_dly_top
      // W_MODE = 1 gives unit i the weight 2^i * delay_t
      // the delay units are the same silicon, so they scale with T as well:
      // this is what makes the quantised code ratiometric
      localparam integer STEP_T0 = (W_MODE != 0) ? (DELAY_T * (1 << i)) : DELAY_T;
      localparam integer STEP_T  = (STEP_T0 * TSCALE)/100;
      localparam integer UT      = `DDQ_DEV(PUF_SEED, (1000 + i), U_VAR);
      localparam integer LOT     = ((D_LO + UT) * TSCALE)/100;
      (* DONT_TOUCH = "TRUE", KEEP_HIERARCHY = "YES" *)
      ddq_delay_unit #(.D_LO(LOT), .D_HI(LOT + STEP_T),
                       .NCELL((W_MODE != 0) ? (1 << i) : 1)) u_dly (
        .a (tdly[i]), .en (up_cfg[i]), .z (tdly[i+1]));
    end
    for (i = 0; i < NDLY; i = i + 1) begin : g_dly_bot
      localparam integer STEP_B0 = (W_MODE != 0) ? (DELAY_T * (1 << i)) : DELAY_T;
      localparam integer STEP_B  = (STEP_B0 * TSCALE)/100;
      localparam integer UB      = `DDQ_DEV(PUF_SEED, (2000 + i), U_VAR);
      localparam integer LOB     = ((D_LO + UB) * TSCALE)/100;
      (* DONT_TOUCH = "TRUE", KEEP_HIERARCHY = "YES" *)
      ddq_delay_unit #(.D_LO(LOB), .D_HI(LOB + STEP_B),
                       .NCELL((W_MODE != 0) ? (1 << i) : 1)) u_dly (
        .a (bdly[i]), .en (lo_cfg[i]), .z (bdly[i+1]));
    end
  endgenerate

  //------------------------------------------------------------------
  // arbiter
  //------------------------------------------------------------------
  ddq_arbiter #(
    .NOISE_PS (NOISE_PS),
    .SEED     (PUF_SEED ^ 32'h5A5A_1234 ^ NSALT)
  ) u_arb (
    .arm   (arm),
    .a_top (tdly[NDLY]),
    .a_bot (bdly[NDLY]),
    .q     (resp)
  );

endmodule


//======================================================================
//  ddq_phase_ctrl : the S0..S12 quantisation FSM
//
//   phase   upper high-latency units   lower high-latency units
//   S0..S5          6 -> 1                       0
//   S6                 0                         0        (conventional APUF)
//   S7..S12            0                       1 -> 6
//
//   R[i] captured at the end of each phase -> R_O[i]
//======================================================================
module ddq_phase_ctrl #(
  parameter integer NDLY   = 6,
  parameter integer SETTLE = 2      // clk cycles allowed for propagation
) (
  input  wire            clk,
  input  wire            rst_n,
  input  wire            start,
  input  wire            arb_q,
  output reg  [NDLY-1:0] up_cfg,
  output reg  [NDLY-1:0] lo_cfg,
  output reg             launch,
  output reg             arm,
  output reg  [12:0]     r_o,
  output reg  [3:0]      phase,
  output reg             busy,
  output reg             done
);

  localparam ST_IDLE = 3'd0,
             ST_CFG  = 3'd1,
             ST_LNCH = 3'd2,
             ST_CAP  = 3'd3,
             ST_FIN  = 3'd4;

  reg [2:0] state;
  reg [7:0] scnt;

  // thermometer code: hi ones in the LSBs
  function [NDLY-1:0] cfg_of;
    input integer hi;
    integer k;
    begin
      cfg_of = {NDLY{1'b0}};
      for (k = 0; k < NDLY; k = k + 1)
        if (k < hi) cfg_of[k] = 1'b1;
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state  <= ST_IDLE;
      up_cfg <= {NDLY{1'b0}};
      lo_cfg <= {NDLY{1'b0}};
      launch <= 1'b0;
      arm    <= 1'b1;
      r_o    <= 13'd0;
      phase  <= 4'd0;
      scnt   <= 8'd0;
      busy   <= 1'b0;
      done   <= 1'b0;
    end
    else begin
      done <= 1'b0;
      case (state)

        ST_IDLE: begin
          launch <= 1'b0;
          arm    <= 1'b1;
          busy   <= 1'b0;
          if (start) begin
            phase <= 4'd0;
            r_o   <= 13'd0;
            busy  <= 1'b1;
            state <= ST_CFG;
          end
        end

        // program the delay units for this phase, hold the paths quiet
        ST_CFG: begin
          up_cfg <= (phase < 4'd6) ? cfg_of(6 - phase) : cfg_of(0);
          lo_cfg <= (phase > 4'd6) ? cfg_of(phase - 6) : cfg_of(0);
          launch <= 1'b0;
          arm    <= 1'b1;          // clear the arbiter
          scnt   <= 8'd0;
          state  <= ST_LNCH;
        end

        // release the arbiter, then launch the rising edge into both paths
        ST_LNCH: begin
          arm    <= 1'b0;
          launch <= 1'b1;
          scnt   <= scnt + 8'd1;
          if (scnt >= SETTLE) state <= ST_CAP;
        end

        // sample R[phase]
        ST_CAP: begin
          r_o[phase] <= arb_q;
          launch     <= 1'b0;
          if (phase == 4'd12) state <= ST_FIN;
          else begin
            phase <= phase + 4'd1;
            state <= ST_CFG;
          end
        end

        ST_FIN: begin
          arm   <= 1'b1;
          done  <= 1'b1;           // 1-cycle pulse: R_O is valid
          busy  <= 1'b0;
          state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule


//======================================================================
//  ddq_obfuscator : 13-stage LFSR response obfuscation (paper Sec. III-B)
//
//   R_O is loaded as the seed, the register is shifted S_L times, and the
//   resulting state is the final response R_L. S_L comes from a 4-bit
//   sub-challenge, so the verifier (who knows C) can recover R_O by
//   running the inverse shift S_L times.
//
//   Polynomial x^13 + x^4 + x^3 + x + 1  (maximal length, period 8191)
//======================================================================
module ddq_obfuscator #(
  parameter integer SL_OFFSET = 0     // extra shifts added to S_L (0 = as published)
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        start,
  input  wire [12:0] seed,
  input  wire [3:0]  sl,
  output reg  [12:0] r_l,
  output reg         done
);

  localparam ST_IDLE = 2'd0, ST_LOAD = 2'd1, ST_SHIFT = 2'd2, ST_FIN = 2'd3;

  reg [1:0]  state;
  reg [12:0] lfsr;
  reg [4:0]  cnt;

  wire [4:0] nshift = sl + SL_OFFSET;   // truncated to 5 bits
  wire       fb     = lfsr[12] ^ lfsr[3] ^ lfsr[2] ^ lfsr[0];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      lfsr  <= 13'd0;
      cnt   <= 5'd0;
      r_l   <= 13'd0;
      done  <= 1'b0;
    end
    else begin
      done <= 1'b0;
      case (state)

        ST_IDLE:
          if (start) state <= ST_LOAD;

        ST_LOAD: begin
          // the all-zero state is the LFSR lock-up state: substitute a
          // fixed non-zero seed (the verifier applies the same rule)
          lfsr  <= (seed == 13'd0) ? 13'd1 : seed;
          cnt   <= nshift;
          state <= (nshift == 5'd0) ? ST_FIN : ST_SHIFT;
        end

        ST_SHIFT: begin
          lfsr <= {lfsr[11:0], fb};
          cnt  <= cnt - 5'd1;
          if (cnt == 5'd1) state <= ST_FIN;
        end

        ST_FIN: begin
          r_l   <= lfsr;
          done  <= 1'b1;
          state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule


//======================================================================
//  ddq_apuf_top : one complete DDQ-APUF instance
//    start -> 13 quantisation phases -> R_O -> LFSR obfuscation -> R_L
//======================================================================
module ddq_apuf_top #(
  parameter integer N        = 32,
  parameter integer NDLY     = 6,
  parameter integer SETTLE   = 2,
  parameter integer T_NOM    = 100,
  parameter integer T_VAR    = 16,
  parameter integer D_LO     = 10,
  parameter integer DELAY_T  = 30,
  parameter integer U_VAR    = 2,
  parameter integer NOISE_PS  = 8,
  parameter integer SL_OFFSET = 0,
  parameter integer TSCALE    = 100,
  parameter integer TC_VAR    = 10,
  parameter integer PUF_SEED = 32'h1234_5678,
  parameter integer NSALT    = 0          // independent-noise salt, see core
) (
  input  wire         clk,
  input  wire         rst_n,
  input  wire         start,
  input  wire [N-1:0] challenge,
  input  wire [3:0]   sl_sel,      // 4-bit sub-challenge -> LFSR shift count
  output wire [12:0]  r_o,         // raw quantised response  (13 bits)
  output wire [12:0]  r_l,         // obfuscated response     (13 bits)
  output wire [3:0]   phase,
  output wire         busy,
  output wire         done
);

  wire [NDLY-1:0] up_cfg, lo_cfg;
  wire            launch, arm, arb_q;
  wire            core_done, ctrl_busy;

  ddq_apuf_core #(
    .N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR), .D_LO(D_LO),
    .DELAY_T(DELAY_T), .U_VAR(U_VAR), .NOISE_PS(NOISE_PS),
    .TSCALE(TSCALE), .TC_VAR(TC_VAR), .PUF_SEED(PUF_SEED), .NSALT(NSALT)
  ) u_core (
    .launch    (launch),
    .arm       (arm),
    .challenge (challenge),
    .up_cfg    (up_cfg),
    .lo_cfg    (lo_cfg),
    .resp      (arb_q)
  );

  ddq_phase_ctrl #(.NDLY(NDLY), .SETTLE(SETTLE)) u_ctrl (
    .clk    (clk),
    .rst_n  (rst_n),
    .start  (start),
    .arb_q  (arb_q),
    .up_cfg (up_cfg),
    .lo_cfg (lo_cfg),
    .launch (launch),
    .arm    (arm),
    .r_o    (r_o),
    .phase  (phase),
    .busy   (ctrl_busy),
    .done   (core_done)
  );

  ddq_obfuscator #(.SL_OFFSET(SL_OFFSET)) u_obf (
    .clk   (clk),
    .rst_n (rst_n),
    .start (core_done),
    .seed  (r_o),
    .sl    (sl_sel),
    .r_l   (r_l),
    .done  (done)
  );

  // busy: from the accepted start pulse until R_L is valid
  reg busy_r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)          busy_r <= 1'b0;
    else if (start)      busy_r <= 1'b1;
    else if (done)       busy_r <= 1'b0;
  end
  assign busy = busy_r | ctrl_busy;

endmodule
