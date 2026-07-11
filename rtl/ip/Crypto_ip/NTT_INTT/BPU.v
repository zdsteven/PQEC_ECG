module BPU (
    input sys_clk,
    input sys_resetn,

    input mode, // 1 for NTT, 0 for INTT
    input [11:0] a,
    input [11:0] b,
    input [11:0] zeta,

    output reg  [11:0] out_a,
    output wire [11:0] out_b
);
    localparam [12:0] Q = 13'd3329;
    localparam [11:0] HALF_Q_PLUS_ONE = 12'd1665;

    reg [11:0] a_d1;
    reg [11:0] a_d2;
    reg [11:0] a_d3;
    reg [11:0] a_d4;

    reg [11:0] half_add_result;
    reg [11:0] half_sub_result;
    reg [11:0] zeta_d1;
    reg [11:0] half_add_d1;
    reg [11:0] half_add_d2;
    reg [11:0] half_add_d3;

    reg [11:0] out_b_ntt;

    wire [11:0] mul_result;
    wire [11:0] mul_a = mode ? b    : half_sub_result;
    wire [11:0] mul_b = mode ? zeta : zeta_d1;
    assign out_b = mode ? out_b_ntt : mul_result;

    fqmul u_fqmul (
        .sys_clk    (sys_clk    ),
        .sys_resetn (sys_resetn ),
        .a          (mul_a      ),
        .b          (mul_b      ),
        .result     (mul_result )
    );

    always @(posedge sys_clk) begin
        if (!sys_resetn) begin
            a_d1 <= 12'd0;
            a_d2 <= 12'd0;
            a_d3 <= 12'd0;
            a_d4 <= 12'd0;
            half_add_result <= 12'd0;
            half_sub_result <= 12'd0;
            zeta_d1 <= 12'd0;
            half_add_d1 <= 12'd0;
            half_add_d2 <= 12'd0;
            half_add_d3 <= 12'd0;
            out_a <= 12'd0;
            out_b_ntt <= 12'd0;
        end else begin
            a_d1 <= a;
            a_d2 <= a_d1;
            a_d3 <= a_d2;
            a_d4 <= a_d3;

            half_add_result <= ifqadd(a, b);
            half_sub_result <= ifqsub(b, a);
            zeta_d1 <= zeta;
            half_add_d1 <= half_add_result;
            half_add_d2 <= half_add_d1;
            half_add_d3 <= half_add_d2;

            out_a <= mode ? fqadd(a_d4, mul_result) : half_add_d3;
            out_b_ntt <= fqsub(a_d4, mul_result);
        end
    end

    function [11:0] fqadd;
        input [11:0] x;
        input [11:0] y;
        reg [12:0] sum;
        reg signed [13:0] diff;
        begin
            sum = {1'b0, x} + {1'b0, y};
            diff = $signed({1'b0, sum}) - $signed({1'b0, Q});
            fqadd = diff[13] ? sum[11:0] : diff[11:0];
        end
    endfunction

    function [11:0] fqsub;
        input [11:0] x;
        input [11:0] y;
        reg signed [13:0] diff;
        reg signed [13:0] corrected;
        begin
            diff = $signed({1'b0, x}) - $signed({1'b0, y});
            corrected = diff[13] ? (diff + $signed({1'b0, Q})) : diff;
            fqsub = corrected[11:0];
        end
    endfunction

    function [11:0] half_modq;
        input [12:0] x;
        reg [11:0] half_x;
        begin
            half_x = x[12:1];
            half_modq = x[0] ? (half_x + HALF_Q_PLUS_ONE) : half_x;
        end
    endfunction

    function [11:0] ifqadd;
        input [11:0] x;
        input [11:0] y;
        reg [11:0] reduced;
        begin
            reduced = fqadd(x, y);
            ifqadd = half_modq({1'b0, reduced});
        end
    endfunction

    function [11:0] ifqsub;
        input [11:0] x;
        input [11:0] y;
        reg [11:0] reduced;
        begin
            reduced = fqsub(x, y);
            ifqsub = half_modq({1'b0, reduced});
        end
    endfunction

endmodule
