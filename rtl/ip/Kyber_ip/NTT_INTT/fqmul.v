(* use_dsp = "no" *) module fqmul (
    input sys_clk,
    input sys_resetn,

    input [11:0] a,
    input [11:0] b,
    output reg [11:0] result
);
    localparam signed [14:0] Q  = 15'sd3329;
    localparam signed [14:0] Q2 = 15'sd6658;

    reg [23:0] product;
    reg signed [12:0] low;
    reg signed [12:0] sum_12_15;
    reg signed [12:0] sum_16_19;
    reg signed [12:0] sum_20_23;
    reg signed [14:0] raw_result;

    wire signed [14:0] low_ext       = {{2{low[12]}}, low};
    wire signed [14:0] sum_12_15_ext = {{2{sum_12_15[12]}}, sum_12_15};
    wire signed [14:0] sum_16_19_ext = {{2{sum_16_19[12]}}, sum_16_19};
    wire signed [14:0] sum_20_23_ext = {{2{sum_20_23[12]}}, sum_20_23};

    function [11:0] canonical_reduce;
        input signed [14:0] x;
        reg signed [14:0] r;
        begin
            if (x >= Q2) begin
                r = x - Q2;
            end else if (x >= Q) begin
                r = x - Q;
            end else if (x < 0) begin
                r = x + Q;
            end else begin
                r = x;
            end
            canonical_reduce = r[11:0];
        end
    endfunction

    always @(posedge sys_clk) begin
        if (!sys_resetn) begin
            product <= 24'd0;
            low <= 13'sd0;
            sum_12_15 <= 13'sd0;
            sum_16_19 <= 13'sd0;
            sum_20_23 <= 13'sd0;
            raw_result <= 15'sd0;
            result <= 12'd0;
        end else begin
            product <= a * b;
            low <= $signed({1'b0, product[11:0]});
            sum_12_15   <=  (product[12] ? 13'sd767  : 13'sd0) +
                            (product[13] ? 13'sd1534 : 13'sd0) -
                            (product[14] ? 13'sd261  : 13'sd0) -
                            (product[15] ? 13'sd522  : 13'sd0);
            sum_16_19  <=  -(product[16] ? 13'sd1044 : 13'sd0) +
                            (product[17] ? 13'sd1241 : 13'sd0) -
                            (product[18] ? 13'sd847  : 13'sd0) +
                            (product[19] ? 13'sd1635 : 13'sd0);
            sum_20_23  <=  -(product[20] ? 13'sd59  : 13'sd0) -
                            (product[21] ? 13'sd118 : 13'sd0) -
                            (product[22] ? 13'sd236 : 13'sd0) -
                            (product[23] ? 13'sd472 : 13'sd0);
            raw_result <= low_ext + sum_12_15_ext + sum_16_19_ext + sum_20_23_ext;
            result <= canonical_reduce(raw_result);
        end
    end



endmodule
