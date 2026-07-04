module Basemul (
    input aclk,
    input aresetn,

    input valid_in,

    input [23:0] a,
    input [23:0] b,
    input [11:0] zeta,

    output reg [23:0] result,
    output reg valid_out
);
    localparam [12:0] Q = 13'd3329;

    wire [11:0] a0 = a[11:0];
    wire [11:0] a1 = a[23:12];
    wire [11:0] b0 = b[11:0];
    wire [11:0] b1 = b[23:12];

    wire [11:0] mul_00;
    wire [11:0] mul_01;
    wire [11:0] mul_10;
    wire [11:0] mul_11;
    wire [11:0] mul_11_zeta;

    reg [11:0] zeta_d1;
    reg [11:0] zeta_d2;
    reg [11:0] zeta_d3;
    reg [11:0] zeta_d4;

    reg [11:0] mul_00_d1;
    reg [11:0] mul_00_d2;
    reg [11:0] mul_00_d3;
    reg [11:0] mul_00_d4;
    reg [11:0] mul_01_d1;
    reg [11:0] mul_01_d2;
    reg [11:0] mul_01_d3;
    reg [11:0] mul_01_d4;
    reg [11:0] mul_10_d1;
    reg [11:0] mul_10_d2;
    reg [11:0] mul_10_d3;
    reg [11:0] mul_10_d4;

    reg [7:0] valid_pipeline;

    fqmul u_fqmul_00 (
        .sys_clk    (aclk   ),
        .sys_resetn (aresetn),
        .a           (a0     ),
        .b           (b0     ),
        .result      (mul_00 )
    );

    fqmul u_fqmul_01 (
        .sys_clk    (aclk   ),
        .sys_resetn (aresetn),
        .a           (a0     ),
        .b           (b1     ),
        .result      (mul_01 )
    );

    fqmul u_fqmul_10 (
        .sys_clk    (aclk   ),
        .sys_resetn (aresetn),
        .a           (a1     ),
        .b           (b0     ),
        .result      (mul_10 )
    );

    fqmul u_fqmul_11 (
        .sys_clk    (aclk   ),
        .sys_resetn (aresetn),
        .a           (a1     ),
        .b           (b1     ),
        .result      (mul_11 )
    );

    fqmul u_fqmul_11_zeta (
        .sys_clk    (aclk       ),
        .sys_resetn (aresetn    ),
        .a           (mul_11     ),
        .b           (zeta_d4    ),
        .result      (mul_11_zeta)
    );

    always @(posedge aclk) begin
        if (!aresetn) begin
            zeta_d1 <= 12'd0;
            zeta_d2 <= 12'd0;
            zeta_d3 <= 12'd0;
            zeta_d4 <= 12'd0;

            mul_00_d1 <= 12'd0;
            mul_00_d2 <= 12'd0;
            mul_00_d3 <= 12'd0;
            mul_00_d4 <= 12'd0;
            mul_01_d1 <= 12'd0;
            mul_01_d2 <= 12'd0;
            mul_01_d3 <= 12'd0;
            mul_01_d4 <= 12'd0;
            mul_10_d1 <= 12'd0;
            mul_10_d2 <= 12'd0;
            mul_10_d3 <= 12'd0;
            mul_10_d4 <= 12'd0;

            valid_pipeline <= 8'd0;
            result <= 24'd0;
            valid_out <= 1'b0;
        end else begin
            zeta_d1 <= zeta;
            zeta_d2 <= zeta_d1;
            zeta_d3 <= zeta_d2;
            zeta_d4 <= zeta_d3;

            mul_00_d1 <= mul_00;
            mul_00_d2 <= mul_00_d1;
            mul_00_d3 <= mul_00_d2;
            mul_00_d4 <= mul_00_d3;
            mul_01_d1 <= mul_01;
            mul_01_d2 <= mul_01_d1;
            mul_01_d3 <= mul_01_d2;
            mul_01_d4 <= mul_01_d3;
            mul_10_d1 <= mul_10;
            mul_10_d2 <= mul_10_d1;
            mul_10_d3 <= mul_10_d2;
            mul_10_d4 <= mul_10_d3;

            valid_pipeline <= {valid_pipeline[6:0], valid_in};
            valid_out <= valid_pipeline[7];
            if (valid_pipeline[7]) begin
                result[11:0] <= fqadd(mul_00_d4, mul_11_zeta);
                result[23:12] <= fqadd(mul_01_d4, mul_10_d4);
            end
        end
    end

    function [11:0] fqadd;
        input [11:0] x;
        input [11:0] y;
        reg [12:0] sum;
        begin
            sum = {1'b0, x} + {1'b0, y};
            fqadd = (sum >= Q) ? (sum - Q) : sum[11:0];
        end
    endfunction

endmodule
