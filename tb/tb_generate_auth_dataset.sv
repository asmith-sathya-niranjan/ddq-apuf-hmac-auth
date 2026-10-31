`timescale 1ns/1ps

// Generates tags from the actual RTL for an external modeling/replay attack.
// Layout: 10,000 training transactions, 2,000 unseen test transactions, then
// the same 2,000 test challenges with fresh nonces for replay checking.
module tb_generate_auth_dataset;
    localparam integer N_TRAIN = 10000;
    localparam integer N_TEST  = 2000;

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
    logic [31:0] challenge_state;
    logic [63:0] nonce_state;
    logic [31:0] test_challenges [0:N_TEST-1];
    logic [63:0] test_nonces [0:N_TEST-1];
    integer fd;
    integer i;

    always #5 clk = ~clk;

    secure_ddq_auth_top dut (
        .clk(clk), .rst_n(rst_n), .key_clear(key_clear),
        .root_key_valid(root_key_valid), .root_key_in(root_key_in),
        .auth_start(auth_start), .challenge(challenge), .nonce(nonce),
        .key_ready(key_ready), .auth_tag(auth_tag), .auth_busy(auth_busy),
        .auth_done(auth_done), .auth_error(auth_error)
    );

    function automatic logic [31:0] next32(input logic [31:0] value);
        logic [31:0] x;
        begin
            x = value;
            x = x ^ (x << 13);
            x = x ^ (x >> 17);
            x = x ^ (x << 5);
            next32 = x;
        end
    endfunction

    function automatic logic [63:0] next64(input logic [63:0] value);
        logic [63:0] x;
        begin
            x = value;
            x = x ^ (x << 13);
            x = x ^ (x >> 7);
            x = x ^ (x << 17);
            next64 = x;
        end
    endfunction

    task automatic authenticate_and_write(input integer kind);
        begin
            auth_start = 1'b1;
            @(negedge clk);
            auth_start = 1'b0;
            wait(auth_done === 1'b1);
            $fwrite(fd, "%0d,%08h,%016h,%016h\n", kind, challenge, nonce, auth_tag);
            @(negedge clk);
        end
    endtask

    initial begin
        fd = $fopen("work/secure_vivado/results/rtl_auth_dataset.csv", "w");
        if (fd == 0) begin
            $display("FAIL could not open RTL dataset output");
            $finish;
        end
        $fwrite(fd, "kind,challenge,nonce,tag\n");
        challenge_state = 32'h13579bdf;
        nonce_state = 64'h0123456789abcdef;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        root_key_in = 256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f;
        root_key_valid = 1'b1;
        @(negedge clk);
        root_key_valid = 1'b0;
        if (!key_ready) begin
            $display("FAIL root key was not accepted");
            $finish;
        end

        for (i = 0; i < N_TRAIN; i = i + 1) begin
            challenge_state = next32(challenge_state);
            nonce_state = next64(nonce_state);
            challenge = challenge_state;
            nonce = nonce_state;
            authenticate_and_write(0);
        end

        for (i = 0; i < N_TEST; i = i + 1) begin
            challenge_state = next32(challenge_state);
            nonce_state = next64(nonce_state);
            test_challenges[i] = challenge_state;
            test_nonces[i] = nonce_state;
            challenge = challenge_state;
            nonce = nonce_state;
            authenticate_and_write(1);
        end

        for (i = 0; i < N_TEST; i = i + 1) begin
            challenge = test_challenges[i];
            nonce = test_nonces[i] + 64'd1;
            authenticate_and_write(2);
        end

        $fclose(fd);
        $display("DATASET PASSED - generated %0d RTL tags", N_TRAIN + 2*N_TEST);
        $finish;
    end
endmodule
