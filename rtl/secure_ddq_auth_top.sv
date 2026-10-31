`timescale 1ns/1ps

// Controlled DDQ authentication boundary.
//
// root_key_in/root_key_valid must be driven by a PUF key reconstructor
// (stable enrollment selection + helper data + ECC/fuzzy extractor).  The
// key is held only in volatile flip-flops and can be cleared.  No raw DDQ,
// SAR, or per-core response is exposed by this module.
module secure_ddq_auth_top (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         key_clear,
    input  logic         root_key_valid,
    input  logic [255:0] root_key_in,
    input  logic         auth_start,
    input  logic [31:0]  challenge,
    input  logic [63:0]  nonce,
    output logic         key_ready,
    output logic [63:0]  auth_tag,
    output logic         auth_busy,
    output logic         auth_done,
    output logic         auth_error
);
    logic [255:0] root_key;
    logic hmac_start;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            root_key <= 256'd0;
            key_ready <= 1'b0;
            auth_error <= 1'b0;
        end else begin
            auth_error <= 1'b0;
            if (key_clear) begin
                root_key <= 256'd0;
                key_ready <= 1'b0;
            end else if (root_key_valid && !auth_busy) begin
                root_key <= root_key_in;
                key_ready <= 1'b1;
            end
            if (auth_start && !key_ready)
                auth_error <= 1'b1;
        end
    end

    assign hmac_start = auth_start && key_ready && !auth_busy;

    hmac_sha256_fixed u_hmac (
        .clk(clk), .rst_n(rst_n), .start(hmac_start), .key(root_key),
        .challenge(challenge), .nonce(nonce), .tag(auth_tag),
        .busy(auth_busy), .done(auth_done)
    );
endmodule
