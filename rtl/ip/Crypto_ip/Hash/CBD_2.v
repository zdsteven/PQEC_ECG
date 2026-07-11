module CBD_2 (
    input [7:0] in,
    output reg [23:0] out
);

    wire [1:0] x_0 = in[0] + in[1];
    wire [1:0] y_0 = in[2] + in[3]; 
    wire [1:0] x_1 = in[4] + in[5];
    wire [1:0] y_1 = in[6] + in[7];

    wire [2:0] z_0 = {1'b0, x_0} + {1'b1, ~y_0} + 1'b1;
    wire [2:0] z_1 = {1'b0, x_1} + {1'b1, ~y_1} + 1'b1;

    always @(*) begin
        case (z_0)
            3'b110: out[11:0] = 12'd3327;
            3'b111: out[11:0] = 12'd3328;
            3'b000: out[11:0] = 12'd0;
            3'b001: out[11:0] = 12'd1;
            3'b010: out[11:0] = 12'd2;
            default: out[11:0] = 12'd0;
        endcase
        case (z_1)
            3'b110: out[23:12] = 12'd3327;
            3'b111: out[23:12] = 12'd3328;
            3'b000: out[23:12] = 12'd0;
            3'b001: out[23:12] = 12'd1;
            3'b010: out[23:12] = 12'd2;
            default: out[23:12] = 12'd0;
        endcase
    end

endmodule