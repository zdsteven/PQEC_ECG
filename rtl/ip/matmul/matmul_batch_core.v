// Streaming 4x4 unsigned matrix multiplier.
// External layout remains A[0..15], B[0..15].  A words are cached as they
// arrive; every B[k][j] immediately launches four A[i][k]*B[k][j] products.
// Four fully-pipelined radix-4 multipliers accept one product each cycle and
// contain no Verilog multiplication operator, preventing DSP inference.
module matmul_batch_core (
    input               clk,
    input               resetn,
    input               start,
    input      [1023:0] matrix_words,
    input               stream_enable,
    input               stream_valid,
    input      [4:0]    stream_index,
    input      [31:0]   stream_data,
    output reg          busy,
    output reg          done,
    input      [3:0]    result_index,
    output reg [65:0]   result_data
);

reg [31:0] a_data [0:15];
reg [15:0] a_valid;
reg [65:0] accumulator [0:15];
reg [65:0] result_snapshot [0:15];
reg [5:0] replay_index;

// Four lanes, sixteen radix-4 stages per lane.
reg [65:0] mul_x [0:63];
reg [65:0] mul_x3 [0:63];
reg [31:0] mul_y [0:63];
reg [65:0] mul_acc [0:63];
reg [3:0]  mul_tag [0:63];
reg        mul_valid [0:63];
reg        mul_last [0:63];

wire input_fire = busy && (stream_enable ? stream_valid : (replay_index < 6'd32));
wire [4:0] input_index = stream_enable ? stream_index : replay_index[4:0];
wire [31:0] input_word = stream_enable ? stream_data :
                         ((replay_index < 6'd16) ?
                          matrix_words[replay_index*32 +: 32] :
                          matrix_words[(replay_index-6'd16)*32 + 16*32 +: 32]);
wire input_is_b = input_index[4];
wire [3:0] input_pos = input_index[3:0];
wire [1:0] input_k = input_pos[3:2];
wire [1:0] input_j = input_pos[1:0];

function [65:0] radix4_term;
    input [65:0] x;
    input [65:0] x3;
    input [1:0] digit;
    begin
        case (digit)
            2'b00: radix4_term = 66'd0;
            2'b01: radix4_term = x;
            2'b10: radix4_term = {x[64:0],1'b0};
            default: radix4_term = x3;
        endcase
    end
endfunction

integer i;
integer lane;
integer stage;
integer flat;
always @(*) begin
    case (result_index)
        4'd0: result_data = result_snapshot[0];
        4'd1: result_data = result_snapshot[1];
        4'd2: result_data = result_snapshot[2];
        4'd3: result_data = result_snapshot[3];
        4'd4: result_data = result_snapshot[4];
        4'd5: result_data = result_snapshot[5];
        4'd6: result_data = result_snapshot[6];
        4'd7: result_data = result_snapshot[7];
        4'd8: result_data = result_snapshot[8];
        4'd9: result_data = result_snapshot[9];
        4'd10: result_data = result_snapshot[10];
        4'd11: result_data = result_snapshot[11];
        4'd12: result_data = result_snapshot[12];
        4'd13: result_data = result_snapshot[13];
        4'd14: result_data = result_snapshot[14];
        default: result_data = result_snapshot[15];
    endcase
end

always @(posedge clk) begin
    if (!resetn) begin
        busy <= 1'b0;
        done <= 1'b0;
        a_valid <= 16'd0;
        replay_index <= 6'd32;
        for (i=0;i<16;i=i+1) begin
            a_data[i] = 32'd0;
            accumulator[i] = 66'd0;
            result_snapshot[i] = 66'd0;
        end
        for (i=0;i<64;i=i+1) begin
            mul_x[i] = 66'd0; mul_x3[i] = 66'd0;
            mul_y[i] = 32'd0; mul_acc[i] = 66'd0;
            mul_tag[i] = 4'd0; mul_valid[i] = 1'b0; mul_last[i] = 1'b0;
        end
    end else begin
        done <= 1'b0;

        if (start && !busy) begin
            busy <= 1'b1;
            a_valid <= 16'd0;
            replay_index <= stream_enable ? 6'd32 : 6'd0;
            for (i=0;i<16;i=i+1)
                accumulator[i] <= 66'd0;
            for (i=0;i<64;i=i+1) begin
                mul_valid[i] <= 1'b0;
                mul_last[i] <= 1'b0;
            end
            // DMA presents A00 together with start; consume it by bypass.
            if (stream_enable && stream_valid && !stream_index[4]) begin
                a_data[stream_index[3:0]] <= stream_data;
                a_valid[stream_index[3:0]] <= 1'b1;
            end
        end else if (busy) begin
            if (!stream_enable && replay_index < 6'd32)
                replay_index <= replay_index + 6'd1;

            // Default stage-0 bubbles.  A B word overrides all four lanes.
            for (lane=0; lane<4; lane=lane+1) begin
                mul_valid[lane*16] <= 1'b0;
                mul_last[lane*16] <= 1'b0;
            end
            if (input_fire && !input_is_b) begin
                a_data[input_pos] <= input_word;
                a_valid[input_pos] <= 1'b1;
            end else if (input_fire && input_is_b) begin
                for (lane=0; lane<4; lane=lane+1) begin
                    flat = lane*16;
                    mul_x[flat] <= {34'd0, a_data[{lane[1:0],input_k}]};
                    mul_x3[flat] <= {34'd0, a_data[{lane[1:0],input_k}]} +
                                     {33'd0, a_data[{lane[1:0],input_k}],1'b0};
                    mul_y[flat] <= input_word >> 2;
                    mul_acc[flat] <= radix4_term(
                        {34'd0, a_data[{lane[1:0],input_k}]},
                        {34'd0, a_data[{lane[1:0],input_k}]} +
                        {33'd0, a_data[{lane[1:0],input_k}],1'b0},
                        input_word[1:0]);
                    mul_tag[flat] <= {lane[1:0],input_j};
                    mul_valid[flat] <= a_valid[{lane[1:0],input_k}];
                    mul_last[flat] <= (input_index == 5'd31);
                end
            end

            for (stage=1; stage<16; stage=stage+1) begin
                for (lane=0; lane<4; lane=lane+1) begin
                    flat = lane*16 + stage;
                    mul_x[flat] <= {mul_x[flat-1][63:0],2'b0};
                    mul_x3[flat] <= {mul_x3[flat-1][63:0],2'b0};
                    mul_y[flat] <= mul_y[flat-1] >> 2;
                    mul_acc[flat] <= mul_acc[flat-1] +
                        radix4_term({mul_x[flat-1][63:0],2'b0},
                                    {mul_x3[flat-1][63:0],2'b0},
                                    mul_y[flat-1][1:0]);
                    mul_tag[flat] <= mul_tag[flat-1];
                    mul_valid[flat] <= mul_valid[flat-1];
                    mul_last[flat] <= mul_last[flat-1];
                end
            end

            // Lane tags from one B word are always distinct.
            for (lane=0; lane<4; lane=lane+1) begin
                flat = lane*16 + 15;
                if (mul_valid[flat])
                    accumulator[mul_tag[flat]] <= accumulator[mul_tag[flat]] + mul_acc[flat];
            end

            if ((mul_valid[15] && mul_last[15]) ||
                (mul_valid[31] && mul_last[31]) ||
                (mul_valid[47] && mul_last[47]) ||
                (mul_valid[63] && mul_last[63])) begin
                for (i=0;i<16;i=i+1) begin
                    // The final input is B33, so its four lane tags are the
                    // compile-time constants C03/C13/C23/C33.  This case
                    // keeps the snapshot path to one 66-bit addition instead
                    // of a four-product conditional adder chain.
                    case (i)
                        3:  result_snapshot[i] <= accumulator[i] + mul_acc[15];
                        7:  result_snapshot[i] <= accumulator[i] + mul_acc[31];
                        11: result_snapshot[i] <= accumulator[i] + mul_acc[47];
                        15: result_snapshot[i] <= accumulator[i] + mul_acc[63];
                        default: result_snapshot[i] <= accumulator[i];
                    endcase
                end
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end
end
endmodule
