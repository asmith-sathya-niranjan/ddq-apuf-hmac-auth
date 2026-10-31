//======================================================================
//  ddq_sar.v
//
//  SAR-DDQ-APUF : a successive-approximation extension of the DDQ-APUF
//  of Wang et al. (IEEE TCAS-I 72(2), Feb 2025).
//
//  What the paper does
//  -------------------
//  Six *unary* delay units per path are swept, one at a time, over 13
//  phases S0..S12. The response is the thermometer code R_O, and the
//  quantised delay difference is its flip point. That gives
//      range      = +/- 6 * delay_t      (about +/-1.6 sigma of dD)
//      resolution = delay_t
//      latency    = 13 arbiter evaluations
//      entropy    ~ log2 of 14 distinct values, ~3.7 bits in 13 bits
//
//  What this module does instead
//  -----------------------------
//  The same six delay units are given *binary* weights (1,2,4,8,16,32)
//  x delay_t, and the controller runs a successive approximation search:
//  one evaluation for the sign of dD, then one per weight, MSB first,
//  keeping a trial bit when the arbiter has not yet flipped. This is a
//  delay-domain SAR ADC using the arbiter as its comparator. With the
//  same six units:
//      levels     = 127 instead of 14    (the real gain: ~9x more codes
//                                         from the same hardware)
//      range      = +/- 63 * delay_t     (in LSB; in PICOSECONDS the
//                                         defaults give +/-252 ps vs the
//                                         unary +/-180 ps, i.e. only 1.4x,
//                                         because delay_t drops 30 -> 4 ps)
//      latency    = 7 arbiter evaluations (1 + NDLY) instead of 13
//      entropy    ~ log2(sigma_code * sqrt(2*pi*e)) in NDLY+1 bits
//
//  Why that matters, beyond being smaller and faster
//  -------------------------------------------------
//  1. Range and resolution decouple. In the unary design range is
//     6*delay_t, so a fine LSB means a narrow range and many saturated
//     (all-0 / all-1) CRPs. With binary weights the range is 63*delay_t,
//     so the LSB can be made fine without the rails closing in.
//  2. The tolerance can be sized to the noise. What decides false accept
//     is the tolerance WINDOW IN PICOSECONDS, not the number of bins. The
//     unary code can only offer windows in 30 ps steps; the SAR code in
//     4 ps steps, so the window can sit just above the noise. At equal
//     reliability the gain is real but modest - measured in tb_ddq_sar.v,
//     which compares both at matched reliability, not at the paper's d=3.
//  3. Authentication is an integer magnitude compare, |code - code'| <= d,
//     rather than a Hamming distance over a code that noise can make
//     non-monotonic.
//
//  Honest limitations
//  ------------------
//  * Binary-weighted delay units inherit the matching problem of a
//    binary-weighted DAC: the 32x unit must equal 32 of the 1x unit or the
//    transfer function has missing/wide codes. On an FPGA, build the large
//    weights as parallel groups of identical LUT delay cells rather than
//    as one long cell, and expect to calibrate. A segmented design (unary
//    MSBs + binary LSBs), as used in real DACs, is the natural fix.
//  * SAR is sequential feedback: the delay configuration for step k
//    depends on the arbiter result of step k-1, so the phases cannot be
//    pipelined the way the paper's fixed sweep can.
//  * Each step is a fresh physical measurement, so a noise hit on an early
//    (MSB) decision costs more than a noise hit in the unary sweep. This
//    is the classic SAR failure mode and is why the tolerance is still
//    needed. It is quantified in tb_ddq_sar.v.
//  * Sign-magnitude coding makes code 0 cover (-delay_t, +delay_t], twice
//    the width of every other code.
//======================================================================

`timescale 1ps / 1ps

//======================================================================
//  ddq_sar_ctrl : successive approximation controller
//
//   step 0        : no delay applied -> arbiter gives sign(dD)
//   step 1..NDLY  : trial = mag | (1 << j), j = NDLY-1 .. 0
//                   the trial delay is applied to the *faster* path, so
//                   the arbiter result only stays equal to the sign while
//                   the applied delay is still smaller than |dD|
//                   -> keep the bit iff arb_q == sign
//======================================================================
module ddq_sar_ctrl #(
  parameter integer NDLY   = 6,
  parameter integer SETTLE = 2
) (
  input  wire              clk,
  input  wire              rst_n,
  input  wire              start,
  input  wire              arb_q,
  output reg  [NDLY-1:0]   up_cfg,
  output reg  [NDLY-1:0]   lo_cfg,
  output reg               launch,
  output reg               arm,
  output reg               sign,        // 1 = upper path faster (dD > 0)
  output reg  [NDLY-1:0]   mag,         // |dD| in units of delay_t
  output reg  signed [NDLY+1:0] code,   // two's complement quantised dD
  output reg  [3:0]        step,
  output reg               busy,
  output reg               done
);

  localparam ST_IDLE = 3'd0,
             ST_CFG  = 3'd1,
             ST_LNCH = 3'd2,
             ST_CAP  = 3'd3,
             ST_FIN  = 3'd4;

  reg [2:0]        state;
  reg [7:0]        scnt;
  reg [NDLY-1:0]   trial;
  reg [3:0]        bitidx;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state  <= ST_IDLE;
      up_cfg <= {NDLY{1'b0}};
      lo_cfg <= {NDLY{1'b0}};
      launch <= 1'b0;
      arm    <= 1'b1;
      sign   <= 1'b0;
      mag    <= {NDLY{1'b0}};
      code   <= {(NDLY+2){1'b0}};
      trial  <= {NDLY{1'b0}};
      step   <= 4'd0;
      bitidx <= 4'd0;
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
            step   <= 4'd0;
            mag    <= {NDLY{1'b0}};
            trial  <= {NDLY{1'b0}};
            bitidx <= NDLY - 1;
            busy   <= 1'b1;
            state  <= ST_CFG;
          end
        end

        ST_CFG: begin
          if (step == 4'd0) begin
            // sign measurement: both paths unloaded
            up_cfg <= {NDLY{1'b0}};
            lo_cfg <= {NDLY{1'b0}};
            trial  <= {NDLY{1'b0}};
          end
          else begin
            // load the trial code onto whichever path is currently faster
            trial  <= mag | ({{(NDLY-1){1'b0}}, 1'b1} << bitidx);
            up_cfg <= sign  ? (mag | ({{(NDLY-1){1'b0}}, 1'b1} << bitidx))
                            : {NDLY{1'b0}};
            lo_cfg <= !sign ? (mag | ({{(NDLY-1){1'b0}}, 1'b1} << bitidx))
                            : {NDLY{1'b0}};
          end
          launch <= 1'b0;
          arm    <= 1'b1;
          scnt   <= 8'd0;
          state  <= ST_LNCH;
        end

        ST_LNCH: begin
          arm    <= 1'b0;
          launch <= 1'b1;
          scnt   <= scnt + 8'd1;
          if (scnt >= SETTLE) state <= ST_CAP;
        end

        ST_CAP: begin
          launch <= 1'b0;
          if (step == 4'd0) begin
            sign  <= arb_q;                 // 1 -> dD > 0, upper path wins
            step  <= 4'd1;
            state <= ST_CFG;
          end
          else begin
            // the arbiter has not flipped yet -> the applied delay is still
            // short of |dD| -> this weight belongs in the result
            if (arb_q == sign) mag <= trial;
            if (bitidx == 4'd0) state <= ST_FIN;
            else begin
              bitidx <= bitidx - 4'd1;
              step   <= step + 4'd1;
              state  <= ST_CFG;
            end
          end
        end

        ST_FIN: begin
          arm  <= 1'b1;
          code <= sign ? $signed({2'b00, mag})
                       : -$signed({2'b00, mag});
          done  <= 1'b1;
          busy  <= 1'b0;
          state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule


//======================================================================
//  ddq_sar_top : SAR-DDQ-APUF instance
//    challenge -> signed quantised delay difference (code)
//              -> LFSR-obfuscated response r_l (same scheme as the paper)
//======================================================================
module ddq_sar_top #(
  parameter integer N         = 32,
  parameter integer NDLY      = 6,
  parameter integer SETTLE    = 2,
  parameter integer T_NOM     = 100,
  parameter integer T_VAR     = 16,
  parameter integer D_LO      = 10,
  parameter integer DELAY_T   = 4,     // LSB step: much finer than the unary
                                       // design, because range no longer
                                       // depends on it
  parameter integer U_VAR     = 2,
  parameter integer NOISE_PS  = 8,
  parameter integer SL_OFFSET = 0,
  parameter integer TSCALE    = 100,   // die temperature, % of nominal delay
  parameter integer TC_VAR    = 10,    // temperature-coefficient mismatch [ps]
  parameter integer PUF_SEED  = 32'h1234_5678,
  parameter integer NSALT     = 0      // independent-noise salt (see core)
) (
  input  wire                   clk,
  input  wire                   rst_n,
  input  wire                   start,
  input  wire [N-1:0]           challenge,
  input  wire [3:0]             sl_sel,
  output wire signed [NDLY+1:0] code,     // quantised dD, two's complement
  output wire [NDLY-1:0]        mag,
  output wire                   sign,
  output wire [12:0]            r_l,      // obfuscated response
  output wire [3:0]             step,
  output wire                   busy,
  output wire                   done
);

  wire [NDLY-1:0] up_cfg, lo_cfg;
  wire            launch, arm, arb_q;
  wire            sar_done;

  ddq_apuf_core #(
    .N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR), .D_LO(D_LO),
    .DELAY_T(DELAY_T), .U_VAR(U_VAR), .NOISE_PS(NOISE_PS),
    .W_MODE(1),                                   // binary-weighted units
    .TSCALE(TSCALE), .TC_VAR(TC_VAR),
    .PUF_SEED(PUF_SEED), .NSALT(NSALT)
  ) u_core (
    .launch    (launch),
    .arm       (arm),
    .challenge (challenge),
    .up_cfg    (up_cfg),
    .lo_cfg    (lo_cfg),
    .resp      (arb_q)
  );

  ddq_sar_ctrl #(.NDLY(NDLY), .SETTLE(SETTLE)) u_sar (
    .clk    (clk),
    .rst_n  (rst_n),
    .start  (start),
    .arb_q  (arb_q),
    .up_cfg (up_cfg),
    .lo_cfg (lo_cfg),
    .launch (launch),
    .arm    (arm),
    .sign   (sign),
    .mag    (mag),
    .code   (code),
    .step   (step),
    .busy   (busy),
    .done   (sar_done)
  );

  // same LFSR obfuscation as the paper, seeded with the quantised code
  ddq_obfuscator #(.SL_OFFSET(SL_OFFSET)) u_obf (
    .clk   (clk),
    .rst_n (rst_n),
    .start (sar_done),
    .seed  ({{(13-(NDLY+2)){1'b0}}, code}),
    .sl    (sl_sel),
    .r_l   (r_l),
    .done  (done)
  );

endmodule


//======================================================================
//  ddq_median3 : combine three quantised codes, median and mean
//
//  The mean is the linear combiner the paper's pseudo-XOR corresponds to
//  (treated here as the average of the three delay differences). The
//  median was tried as a non-linear alternative.
//
//  MEASURED RESULT (tb_ddq_temp.v, PART B): the median is WORSE when one
//  core is noisy. Mechanism: median-of-3 is continuous and 1-Lipschitz,
//  |med(x) - med(y)| <= max_i |x_i - y_i|, so it never "jumps"; but
//  whenever the noisy core happens to be the middle value it is passed
//  through at weight 1, while the mean always attenuates it to 1/3. A
//  median rejects a corrupted input only when the other inputs agree
//  with each other (replicas of one quantity). Independent PUF cores do
//  not agree, so the noisy core sits in the middle about 1/3 of the time.
//
//  Modelling-attack resistance of either combiner is NOT evaluated here
//  (that needs the CMA-ES experiment of the paper's Sec. III-E).
//======================================================================
module ddq_median3 #(
  parameter integer W = 8
) (
  input  wire signed [W-1:0] a,
  input  wire signed [W-1:0] b,
  input  wire signed [W-1:0] c,
  output wire signed [W-1:0] med,
  output wire signed [W-1:0] mean      // pseudo-XOR equivalent, for reference
);
  wire signed [W-1:0] hi_ab = (a > b) ? a : b;
  wire signed [W-1:0] lo_ab = (a > b) ? b : a;
  // median = max(min(a,b), min(max(a,b), c))
  wire signed [W-1:0] mid   = (hi_ab < c) ? hi_ab : c;
  assign med  = (lo_ab > mid) ? lo_ab : mid;
  // widen before adding: three +/-63 codes sum to +/-189, beyond W bits
  wire signed [W+1:0] sum3 = a + b + c;
  assign mean = sum3 / 3;
endmodule


//======================================================================
//  ddq_sar_x3 : three SAR cores on one device, combined two ways
//  NOISE0/1/2 are separate so that one core can be made unstable, which
//  is the case that separates a median from a mean.
//======================================================================
module ddq_sar_x3 #(
  parameter integer N        = 32,
  parameter integer NDLY     = 6,
  parameter integer T_NOM    = 100,
  parameter integer T_VAR    = 16,
  parameter integer DELAY_T  = 4,
  parameter integer NOISE0   = 8,
  parameter integer NOISE1   = 8,
  parameter integer NOISE2   = 8,
  parameter integer TSCALE   = 100,
  parameter integer TC_VAR   = 10,
  parameter integer PUF_SEED = 32'h1234_5678,
  parameter integer NSALT    = 0
) (
  input  wire                   clk,
  input  wire                   rst_n,
  input  wire                   start,
  input  wire [N-1:0]           challenge,
  output wire signed [NDLY+1:0] code0,
  output wire signed [NDLY+1:0] code1,
  output wire signed [NDLY+1:0] code2,
  output wire signed [NDLY+1:0] code_med,
  output wire signed [NDLY+1:0] code_mean,
  output wire                   done
);
  ddq_sar_top #(.N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR),
    .DELAY_T(DELAY_T), .NOISE_PS(NOISE0), .TSCALE(TSCALE), .TC_VAR(TC_VAR),
    .NSALT(NSALT),
    .PUF_SEED(PUF_SEED)) u_c0 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(challenge),
    .sl_sel(4'd0), .code(code0), .mag(), .sign(), .r_l(), .step(),
    .busy(), .done(done));

  ddq_sar_top #(.N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR),
    .DELAY_T(DELAY_T), .NOISE_PS(NOISE1), .TSCALE(TSCALE), .TC_VAR(TC_VAR),
    .NSALT(NSALT),
    .PUF_SEED(PUF_SEED ^ 32'h0F0F_0F0F)) u_c1 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(challenge),
    .sl_sel(4'd0), .code(code1), .mag(), .sign(), .r_l(), .step(),
    .busy(), .done());

  ddq_sar_top #(.N(N), .NDLY(NDLY), .T_NOM(T_NOM), .T_VAR(T_VAR),
    .DELAY_T(DELAY_T), .NOISE_PS(NOISE2), .TSCALE(TSCALE), .TC_VAR(TC_VAR),
    .NSALT(NSALT),
    .PUF_SEED(PUF_SEED ^ 32'h3333_CCCC)) u_c2 (
    .clk(clk), .rst_n(rst_n), .start(start), .challenge(challenge),
    .sl_sel(4'd0), .code(code2), .mag(), .sign(), .r_l(), .step(),
    .busy(), .done());

  ddq_median3 #(.W(NDLY+2)) u_comb (
    .a(code0), .b(code1), .c(code2), .med(code_med), .mean(code_mean));
endmodule
