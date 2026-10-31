`timescale 1ns/1ps

// HMAC-SHA-256 specialized for:
//   key     = 256 bits
//   message = challenge[31:0] || nonce[63:0] (96 bits)
//   output  = upper 64 bits of the 256-bit HMAC
// Four SHA-256 compression blocks are required per authentication.
module hmac_sha256_fixed (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [255:0] key,
    input  logic [31:0]  challenge,
    input  logic [63:0]  nonce,
    output logic [63:0]  tag,
    output logic         busy,
    output logic         done
);
    localparam logic [3:0] S_IDLE = 4'd0,
                           S_I0   = 4'd1, S_I0_WAIT = 4'd2,
                           S_I1   = 4'd3, S_I1_WAIT = 4'd4,
                           S_O0   = 4'd5, S_O0_WAIT = 4'd6,
                           S_O1   = 4'd7, S_O1_WAIT = 4'd8;
    logic [3:0] state;
    logic [255:0] key_reg;
    logic [31:0] challenge_reg;
    logic [63:0] nonce_reg;
    logic [255:0] inner_digest;

    logic         sha_start, sha_init, sha_busy, sha_done;
    logic [511:0] sha_block;
    logic [255:0] sha_digest;

    assign sha_start = (state == S_I0) || (state == S_I1) ||
                       (state == S_O0) || (state == S_O1);
    assign sha_init  = (state == S_I0) || (state == S_O0);

    always_comb begin
        sha_block = 512'd0;
        case (state)
          S_I0: sha_block = {key_reg ^ {32{8'h36}}, {32{8'h36}}};
          // Inner message length is 64-byte key block + 12-byte message = 608 bits.
          S_I1: sha_block = {challenge_reg, nonce_reg, 1'b1, {351{1'b0}}, 64'd608};
          S_O0: sha_block = {key_reg ^ {32{8'h5c}}, {32{8'h5c}}};
          // Outer message length is 64-byte key block + 32-byte digest = 768 bits.
          S_O1: sha_block = {inner_digest, 1'b1, {191{1'b0}}, 64'd768};
          default: sha_block = 512'd0;
        endcase
    end

    sha256_compress u_sha (
        .clk(clk), .rst_n(rst_n), .start(sha_start), .init(sha_init),
        .block(sha_block), .digest(sha_digest), .busy(sha_busy), .done(sha_done)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            key_reg <= 256'd0;
            challenge_reg <= 32'd0;
            nonce_reg <= 64'd0;
            inner_digest <= 256'd0;
            tag <= 64'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
              S_IDLE: begin
                  busy <= 1'b0;
                  if (start) begin
                      key_reg <= key;
                      challenge_reg <= challenge;
                      nonce_reg <= nonce;
                      busy <= 1'b1;
                      state <= S_I0;
                  end
              end
              S_I0:      state <= S_I0_WAIT;
              S_I0_WAIT: if (sha_done && !sha_busy) state <= S_I1;
              S_I1:      state <= S_I1_WAIT;
              S_I1_WAIT: if (sha_done && !sha_busy) begin
                  inner_digest <= sha_digest;
                  state <= S_O0;
              end
              S_O0:      state <= S_O0_WAIT;
              S_O0_WAIT: if (sha_done && !sha_busy) state <= S_O1;
              S_O1:      state <= S_O1_WAIT;
              S_O1_WAIT: if (sha_done && !sha_busy) begin
                  tag <= sha_digest[255:192];
                  busy <= 1'b0;
                  done <= 1'b1;
                  state <= S_IDLE;
              end
              default: state <= S_IDLE;
            endcase
        end
    end
endmodule
