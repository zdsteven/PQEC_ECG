module matmul_core (
    input             clk,
    input             resetn,
    input             start,
    input      [1023:0] ab_data,
    output reg        busy,
    output reg        done,
    output     [1055:0] c_data
);

reg [2:0] issue_k;
reg [2:0] product_k;
reg       product_valid;
reg [65:0] c_reg [0:15];

wire [63:0] product [0:15];

function [31:0] ab_word;
    input [5:0] index;
    begin
        ab_word = ab_data[index * 32 +: 32];
    end
endfunction

genvar row;
genvar col;
generate
    for (row = 0; row < 4; row = row + 1) begin: g_row
        for (col = 0; col < 4; col = col + 1) begin: g_col
            mul u_mul (
                .mul_clk    (clk),
                .reset      (1'b0),
                .mul_signed (1'b0),
                .x          (ab_word(row * 4 + issue_k[1:0])),
                .y          (ab_word(6'd16 + issue_k[1:0] * 4 + col)),
                .result     (product[row * 4 + col])
            );
        end
    end
endgenerate

genvar out_i;
generate
    for (out_i = 0; out_i < 16; out_i = out_i + 1) begin: g_out
        assign c_data[out_i * 66 +: 66] = c_reg[out_i];
    end
endgenerate

integer i;
always @(posedge clk) begin
    if (!resetn) begin
        busy <= 1'b0;
        done <= 1'b0;
        issue_k <= 3'd0;
        product_k <= 3'd0;
        product_valid <= 1'b0;
        for (i = 0; i < 16; i = i + 1) begin
            c_reg[i] <= 66'd0;
        end
    end
    else begin
        done <= 1'b0;

        if (start && !busy) begin
            busy <= 1'b1;
            issue_k <= 3'd0;
            product_k <= 3'd0;
            product_valid <= 1'b0;
            for (i = 0; i < 16; i = i + 1) begin
                c_reg[i] <= 66'd0;
            end
        end
        else if (busy) begin
            if (product_valid) begin
                for (i = 0; i < 16; i = i + 1) begin
                    c_reg[i] <= c_reg[i] + {2'b0, product[i]};
                end

                if (product_k == 3'd3) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    product_valid <= 1'b0;
                end
            end

            if (issue_k < 3'd4) begin
                issue_k <= issue_k + 3'd1;
                product_k <= issue_k;
                product_valid <= 1'b1;
            end
        end
    end
end

endmodule
