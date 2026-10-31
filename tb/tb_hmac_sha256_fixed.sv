`timescale 1ns/1ps

module tb_hmac_sha256_fixed;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [255:0] key;
    logic [31:0] challenge;
    logic [63:0] nonce;
    logic [63:0] tag;
    logic busy, done;
    integer errors = 0;

    always #5 clk = ~clk;

    hmac_sha256_fixed dut (
        .clk(clk), .rst_n(rst_n), .start(start), .key(key),
        .challenge(challenge), .nonce(nonce), .tag(tag), .busy(busy), .done(done)
    );

    task automatic run_vector(
        input logic [255:0] test_key,
        input logic [31:0] test_challenge,
        input logic [63:0] test_nonce,
        input logic [63:0] expected
    );
        begin
            @(negedge clk);
            key = test_key;
            challenge = test_challenge;
            nonce = test_nonce;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            wait(done === 1'b1);
            if (tag !== expected) begin
                $display("FAIL tag=%016h expected=%016h", tag, expected);
                errors = errors + 1;
            end else begin
                $display("PASS tag=%016h", tag);
            end
            @(negedge clk);
        end
    endtask

    initial begin
        key = 0; challenge = 0; nonce = 0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        run_vector(
            256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f,
            32'h01234567, 64'h89abcdef01234567, 64'hf01bcd48741875e8
        );
        run_vector(
            256'h0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b,
            32'hdeadbeef, 64'h0000000000000001, 64'h542f093cc0e73f18
        );

        if (errors == 0) $display("TEST PASSED - 0 error(s)");
        else             $display("TEST FAILED - %0d error(s)", errors);
        $finish;
    end
endmodule
