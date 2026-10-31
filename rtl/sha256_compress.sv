`timescale 1ns/1ps

// Iterative SHA-256 compression engine: one 512-bit block in 64 cycles.
// start is accepted only while busy=0. init=1 starts a new hash; init=0
// continues from the digest produced by the previous block.
module sha256_compress (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic         init,
    input  logic [511:0] block,
    output logic [255:0] digest,
    output logic         busy,
    output logic         done
);
    logic [31:0] w [0:15];
    logic [31:0] a, b, c, d, e, f, g, h;
    logic [31:0] base0, base1, base2, base3, base4, base5, base6, base7;
    logic [6:0] round;
    integer i;

    function automatic logic [31:0] rotr(input logic [31:0] x, input integer n);
        rotr = (x >> n) | (x << (32-n));
    endfunction
    function automatic logic [31:0] ch(input logic [31:0] x, y, z);
        ch = (x & y) ^ (~x & z);
    endfunction
    function automatic logic [31:0] maj(input logic [31:0] x, y, z);
        maj = (x & y) ^ (x & z) ^ (y & z);
    endfunction
    function automatic logic [31:0] bsig0(input logic [31:0] x);
        bsig0 = rotr(x,2) ^ rotr(x,13) ^ rotr(x,22);
    endfunction
    function automatic logic [31:0] bsig1(input logic [31:0] x);
        bsig1 = rotr(x,6) ^ rotr(x,11) ^ rotr(x,25);
    endfunction
    function automatic logic [31:0] ssig0(input logic [31:0] x);
        ssig0 = rotr(x,7) ^ rotr(x,18) ^ (x >> 3);
    endfunction
    function automatic logic [31:0] ssig1(input logic [31:0] x);
        ssig1 = rotr(x,17) ^ rotr(x,19) ^ (x >> 10);
    endfunction
    function automatic logic [31:0] kconst(input logic [5:0] index);
        case (index)
          6'd0:kconst=32'h428a2f98;  6'd1:kconst=32'h71374491;
          6'd2:kconst=32'hb5c0fbcf;  6'd3:kconst=32'he9b5dba5;
          6'd4:kconst=32'h3956c25b;  6'd5:kconst=32'h59f111f1;
          6'd6:kconst=32'h923f82a4;  6'd7:kconst=32'hab1c5ed5;
          6'd8:kconst=32'hd807aa98;  6'd9:kconst=32'h12835b01;
          6'd10:kconst=32'h243185be; 6'd11:kconst=32'h550c7dc3;
          6'd12:kconst=32'h72be5d74; 6'd13:kconst=32'h80deb1fe;
          6'd14:kconst=32'h9bdc06a7; 6'd15:kconst=32'hc19bf174;
          6'd16:kconst=32'he49b69c1; 6'd17:kconst=32'hefbe4786;
          6'd18:kconst=32'h0fc19dc6; 6'd19:kconst=32'h240ca1cc;
          6'd20:kconst=32'h2de92c6f; 6'd21:kconst=32'h4a7484aa;
          6'd22:kconst=32'h5cb0a9dc; 6'd23:kconst=32'h76f988da;
          6'd24:kconst=32'h983e5152; 6'd25:kconst=32'ha831c66d;
          6'd26:kconst=32'hb00327c8; 6'd27:kconst=32'hbf597fc7;
          6'd28:kconst=32'hc6e00bf3; 6'd29:kconst=32'hd5a79147;
          6'd30:kconst=32'h06ca6351; 6'd31:kconst=32'h14292967;
          6'd32:kconst=32'h27b70a85; 6'd33:kconst=32'h2e1b2138;
          6'd34:kconst=32'h4d2c6dfc; 6'd35:kconst=32'h53380d13;
          6'd36:kconst=32'h650a7354; 6'd37:kconst=32'h766a0abb;
          6'd38:kconst=32'h81c2c92e; 6'd39:kconst=32'h92722c85;
          6'd40:kconst=32'ha2bfe8a1; 6'd41:kconst=32'ha81a664b;
          6'd42:kconst=32'hc24b8b70; 6'd43:kconst=32'hc76c51a3;
          6'd44:kconst=32'hd192e819; 6'd45:kconst=32'hd6990624;
          6'd46:kconst=32'hf40e3585; 6'd47:kconst=32'h106aa070;
          6'd48:kconst=32'h19a4c116; 6'd49:kconst=32'h1e376c08;
          6'd50:kconst=32'h2748774c; 6'd51:kconst=32'h34b0bcb5;
          6'd52:kconst=32'h391c0cb3; 6'd53:kconst=32'h4ed8aa4a;
          6'd54:kconst=32'h5b9cca4f; 6'd55:kconst=32'h682e6ff3;
          6'd56:kconst=32'h748f82ee; 6'd57:kconst=32'h78a5636f;
          6'd58:kconst=32'h84c87814; 6'd59:kconst=32'h8cc70208;
          6'd60:kconst=32'h90befffa; 6'd61:kconst=32'ha4506ceb;
          6'd62:kconst=32'hbef9a3f7; default:kconst=32'hc67178f2;
        endcase
    endfunction

    logic [31:0] scheduled_w, t1, t2;
    always_comb begin
        if (round < 7'd16)
            scheduled_w = w[round[3:0]];
        else
            scheduled_w = ssig1(w[round[3:0] - 4'd2]) +
                          w[round[3:0] - 4'd7] +
                          ssig0(w[round[3:0] - 4'd15]) +
                          w[round[3:0]];
        t1 = h + bsig1(e) + ch(e,f,g) + kconst(round[5:0]) + scheduled_w;
        t2 = bsig0(a) + maj(a,b,c);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            digest <= 256'd0;
            busy   <= 1'b0;
            done   <= 1'b0;
            round  <= 7'd0;
            a <= 0; b <= 0; c <= 0; d <= 0;
            e <= 0; f <= 0; g <= 0; h <= 0;
            base0 <= 0; base1 <= 0; base2 <= 0; base3 <= 0;
            base4 <= 0; base5 <= 0; base6 <= 0; base7 <= 0;
            for (i = 0; i < 16; i = i + 1) w[i] <= 32'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                for (i = 0; i < 16; i = i + 1)
                    w[i] <= block[511-(i*32) -: 32];
                if (init) begin
                    base0 <= 32'h6a09e667; base1 <= 32'hbb67ae85;
                    base2 <= 32'h3c6ef372; base3 <= 32'ha54ff53a;
                    base4 <= 32'h510e527f; base5 <= 32'h9b05688c;
                    base6 <= 32'h1f83d9ab; base7 <= 32'h5be0cd19;
                    a <= 32'h6a09e667; b <= 32'hbb67ae85;
                    c <= 32'h3c6ef372; d <= 32'ha54ff53a;
                    e <= 32'h510e527f; f <= 32'h9b05688c;
                    g <= 32'h1f83d9ab; h <= 32'h5be0cd19;
                end else begin
                    base0 <= digest[255:224]; base1 <= digest[223:192];
                    base2 <= digest[191:160]; base3 <= digest[159:128];
                    base4 <= digest[127:96];  base5 <= digest[95:64];
                    base6 <= digest[63:32];   base7 <= digest[31:0];
                    a <= digest[255:224]; b <= digest[223:192];
                    c <= digest[191:160]; d <= digest[159:128];
                    e <= digest[127:96];  f <= digest[95:64];
                    g <= digest[63:32];   h <= digest[31:0];
                end
                round <= 7'd0;
                busy  <= 1'b1;
            end else if (busy) begin
                if (round >= 7'd16)
                    w[round[3:0]] <= scheduled_w;
                if (round == 7'd63) begin
                    digest[255:224] <= base0 + t1 + t2;
                    digest[223:192] <= base1 + a;
                    digest[191:160] <= base2 + b;
                    digest[159:128] <= base3 + c;
                    digest[127:96]  <= base4 + d + t1;
                    digest[95:64]   <= base5 + e;
                    digest[63:32]   <= base6 + f;
                    digest[31:0]    <= base7 + g;
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    h <= g;
                    g <= f;
                    f <= e;
                    e <= d + t1;
                    d <= c;
                    c <= b;
                    b <= a;
                    a <= t1 + t2;
                    round <= round + 7'd1;
                end
            end
        end
    end
endmodule
