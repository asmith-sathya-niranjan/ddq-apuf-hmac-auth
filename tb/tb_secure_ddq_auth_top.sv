`timescale 1ns/1ps

module tb_secure_ddq_auth_top;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic key_clear = 1'b0;
    logic root_key_valid = 1'b0;
    logic [255:0] root_key_in = 256'd0;
    logic auth_start = 1'b0;
    logic [31:0] challenge = 32'd0;
    logic [63:0] nonce = 64'd0;
    logic key_ready;
    logic [63:0] auth_tag;
    logic auth_busy, auth_done, auth_error;
    integer errors = 0;

    always #5 clk = ~clk;

    secure_ddq_auth_top dut (
        .clk(clk), .rst_n(rst_n), .key_clear(key_clear),
        .root_key_valid(root_key_valid), .root_key_in(root_key_in),
        .auth_start(auth_start), .challenge(challenge), .nonce(nonce),
        .key_ready(key_ready), .auth_tag(auth_tag), .auth_busy(auth_busy),
        .auth_done(auth_done), .auth_error(auth_error)
    );

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // Authentication must be refused before key reconstruction.
        @(negedge clk); auth_start = 1'b1;
        @(posedge clk); #1;
        if (!auth_error) begin
            $display("FAIL missing start-before-key error");
            errors = errors + 1;
        end
        @(negedge clk); auth_start = 1'b0;

        // Load the PUF-reconstructed root key through the explicit interface.
        @(negedge clk);
        root_key_in = 256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f;
        root_key_valid = 1'b1;
        @(negedge clk); root_key_valid = 1'b0;
        if (!key_ready) begin
            $display("FAIL key did not become ready");
            errors = errors + 1;
        end

        challenge = 32'h01234567;
        nonce = 64'h89abcdef01234567;
        auth_start = 1'b1;
        @(negedge clk); auth_start = 1'b0;
        wait(auth_done === 1'b1);
        if (auth_tag !== 64'hf01bcd48741875e8) begin
            $display("FAIL auth tag=%016h expected=f01bcd48741875e8", auth_tag);
            errors = errors + 1;
        end else begin
            $display("PASS controlled auth tag=%016h", auth_tag);
        end

        // Clearing the volatile key must disable authentication again.
        @(negedge clk); key_clear = 1'b1;
        @(negedge clk); key_clear = 1'b0;
        if (key_ready) begin
            $display("FAIL key_clear did not remove key_ready");
            errors = errors + 1;
        end

        if (errors == 0) $display("TEST PASSED - 0 error(s)");
        else             $display("TEST FAILED - %0d error(s)", errors);
        $finish;
    end
endmodule
