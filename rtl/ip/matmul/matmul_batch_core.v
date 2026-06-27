// 4x4 unsigned matrix-multiply core for the DMA batch engine.
//
// The implementation deliberately contains no Verilog multiplication
// operator.  Sixteen output elements are accumulated in parallel; one bit of
// the current B row is consumed per cycle.  A complete matrix therefore takes
// 4 * 32 cycles plus start/finish overhead, while the longest arithmetic path
// is a single 66-bit addition.
module matmul_batch_core (
    input               clk,
    input               resetn,
    input               start,
    input      [1023:0] matrix_words,
    output reg          busy,
    output reg          done,
    input      [3:0]    result_index,
    output reg [65:0]   result_data
);

reg [31:0] a_data [0:15];
reg [31:0] b_data [0:15];
reg [65:0] accumulator [0:15];
reg [65:0] a_shift [0:3];
reg [31:0] b_shift [0:3];
reg [1:0]  k_index;
reg [4:0]  bit_index;

integer i;

always @(*) begin
    case (result_index)
        4'd0:  result_data = accumulator[0];
        4'd1:  result_data = accumulator[1];
        4'd2:  result_data = accumulator[2];
        4'd3:  result_data = accumulator[3];
        4'd4:  result_data = accumulator[4];
        4'd5:  result_data = accumulator[5];
        4'd6:  result_data = accumulator[6];
        4'd7:  result_data = accumulator[7];
        4'd8:  result_data = accumulator[8];
        4'd9:  result_data = accumulator[9];
        4'd10: result_data = accumulator[10];
        4'd11: result_data = accumulator[11];
        4'd12: result_data = accumulator[12];
        4'd13: result_data = accumulator[13];
        4'd14: result_data = accumulator[14];
        4'd15: result_data = accumulator[15];
        default: result_data = 66'd0;
    endcase
end

always @(posedge clk) begin
    if (!resetn) begin
        busy      <= 1'b0;
        done      <= 1'b0;
        k_index   <= 2'd0;
        bit_index <= 5'd0;
        for (i = 0; i < 16; i = i + 1) begin
            a_data[i]     <= 32'd0;
            b_data[i]     <= 32'd0;
            accumulator[i] <= 66'd0;
        end
        for (i = 0; i < 4; i = i + 1) begin
            a_shift[i] <= 66'd0;
            b_shift[i] <= 32'd0;
        end
    end else begin
        done <= 1'b0;

        if (start && !busy) begin
            busy      <= 1'b1;
            k_index   <= 2'd0;
            bit_index <= 5'd0;

            for (i = 0; i < 16; i = i + 1) begin
                a_data[i]      <= matrix_words[i*32 +: 32];
                b_data[i]      <= matrix_words[(i+16)*32 +: 32];
                accumulator[i] <= 66'd0;
            end

            a_shift[0] <= {34'd0, matrix_words[0*32 +: 32]};
            a_shift[1] <= {34'd0, matrix_words[4*32 +: 32]};
            a_shift[2] <= {34'd0, matrix_words[8*32 +: 32]};
            a_shift[3] <= {34'd0, matrix_words[12*32 +: 32]};
            b_shift[0] <= matrix_words[(16+0)*32 +: 32];
            b_shift[1] <= matrix_words[(16+1)*32 +: 32];
            b_shift[2] <= matrix_words[(16+2)*32 +: 32];
            b_shift[3] <= matrix_words[(16+3)*32 +: 32];
        end else if (busy) begin
            // Each conditional add is independent.  The constant loop indices
            // are unrolled into sixteen parallel 66-bit accumulator lanes.
            for (i = 0; i < 16; i = i + 1) begin
                if (b_shift[i % 4][0])
                    accumulator[i] <= accumulator[i] + a_shift[i / 4];
            end

            if (bit_index == 5'd31) begin
                bit_index <= 5'd0;
                if (k_index == 2'd3) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    k_index <= k_index + 2'd1;
                    a_shift[0] <= {34'd0, a_data[k_index + 1]};
                    a_shift[1] <= {34'd0, a_data[k_index + 5]};
                    a_shift[2] <= {34'd0, a_data[k_index + 9]};
                    a_shift[3] <= {34'd0, a_data[k_index + 13]};
                    b_shift[0] <= b_data[{k_index + 2'd1, 2'b00} + 0];
                    b_shift[1] <= b_data[{k_index + 2'd1, 2'b00} + 1];
                    b_shift[2] <= b_data[{k_index + 2'd1, 2'b00} + 2];
                    b_shift[3] <= b_data[{k_index + 2'd1, 2'b00} + 3];
                end
            end else begin
                bit_index <= bit_index + 5'd1;
                a_shift[0] <= {a_shift[0][64:0], 1'b0};
                a_shift[1] <= {a_shift[1][64:0], 1'b0};
                a_shift[2] <= {a_shift[2][64:0], 1'b0};
                a_shift[3] <= {a_shift[3][64:0], 1'b0};
                b_shift[0] <= {1'b0, b_shift[0][31:1]};
                b_shift[1] <= {1'b0, b_shift[1][31:1]};
                b_shift[2] <= {1'b0, b_shift[2][31:1]};
                b_shift[3] <= {1'b0, b_shift[3][31:1]};
            end
        end
    end
end

endmodule
