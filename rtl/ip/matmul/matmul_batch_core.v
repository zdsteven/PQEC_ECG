// Streaming 4x4 unsigned matrix multiplier.
// External layout remains A[0..15], B[0..15].  A words are cached as adjacent
// pairs; every B[k][j]/B[k][j+1] pair immediately launches eight products.
// The fully-pipelined radix-4 datapath contains no Verilog multiplication
// operator, preventing DSP inference.
module matmul_batch_core (
    input               clk,
    input               resetn,
    input               start,
    input               stream_valid,
    input      [4:0]    stream_index,
    input      [31:0]   stream_data,
    input               stream_valid1,
    input      [4:0]    stream_index1,
    input      [31:0]   stream_data1,
    output reg          busy,
    output reg          done,
    input      [3:0]    result_index,
    output reg [65:0]   result_data
);

reg [31:0] a_data [0:15];
reg [15:0] a_valid;
reg [65:0] accumulator [0:15];
reg [65:0] result_snapshot [0:15];

// Four row lanes, sixteen radix-4 stages per lane and two products per row.
reg [65:0] mul_x [0:63];
reg [65:0] mul_x3 [0:63];
// A pair contains adjacent matrix words.  Adjacent B words have the same k,
// so both product channels for one row can share the shifted multiplicand
// pipeline while retaining independent multiplier/accumulator state.
reg [31:0] mul_y0 [0:63];
reg [65:0] mul_acc0 [0:63];
reg [3:0]  mul_tag0 [0:63];
reg        mul_valid0 [0:63];
reg        mul_last0 [0:63];
reg [31:0] mul_y1 [0:63];
reg [65:0] mul_acc1 [0:63];
reg [3:0]  mul_tag1 [0:63];
reg        mul_valid1 [0:63];
reg        mul_last1 [0:63];

wire input_fire0 = busy && stream_valid;
wire input_fire1 = busy && stream_valid1;
wire input_is_b0 = stream_index[4];
wire input_is_b1 = stream_index1[4];
wire [3:0] input_pos0 = stream_index[3:0];
wire [3:0] input_pos1 = stream_index1[3:0];
wire [1:0] input_k0 = input_pos0[3:2];
wire [1:0] input_k1 = input_pos1[3:2];
wire [1:0] input_j0 = input_pos0[1:0];
wire [1:0] input_j1 = input_pos1[1:0];
wire launch_b0 = input_fire0 && input_is_b0;
wire launch_b1 = input_fire1 && input_is_b1;
wire launch_b_pair = launch_b0 || launch_b1;
wire [1:0] launch_k = launch_b0 ? input_k0 : input_k1;
wire launch_last_pair = (launch_b0 && (stream_index == 5'd31)) ||
                        (launch_b1 && (stream_index1 == 5'd31));

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
        for (i=0;i<16;i=i+1) begin
            a_data[i] = 32'd0;
            accumulator[i] = 66'd0;
            result_snapshot[i] = 66'd0;
        end
        for (i=0;i<64;i=i+1) begin
            mul_x[i] = 66'd0; mul_x3[i] = 66'd0;
            mul_y0[i] = 32'd0; mul_acc0[i] = 66'd0;
            mul_tag0[i] = 4'd0; mul_valid0[i] = 1'b0; mul_last0[i] = 1'b0;
            mul_y1[i] = 32'd0; mul_acc1[i] = 66'd0;
            mul_tag1[i] = 4'd0; mul_valid1[i] = 1'b0; mul_last1[i] = 1'b0;
        end
    end else begin
        done <= 1'b0;

        if (start && !busy) begin
            busy <= 1'b1;
            a_valid <= 16'd0;
            for (i=0;i<16;i=i+1)
                accumulator[i] <= 66'd0;
            for (i=0;i<64;i=i+1) begin
                mul_valid0[i] <= 1'b0;
                mul_last0[i] <= 1'b0;
                mul_valid1[i] <= 1'b0;
                mul_last1[i] <= 1'b0;
            end
            // A streaming producer may present A00 together with start;
            // consume that first word through the input bypass.
            if (stream_valid && !stream_index[4]) begin
                a_data[stream_index[3:0]] <= stream_data;
                a_valid[stream_index[3:0]] <= 1'b1;
            end
            if (stream_valid1 && !stream_index1[4]) begin
                a_data[stream_index1[3:0]] <= stream_data1;
                a_valid[stream_index1[3:0]] <= 1'b1;
            end
        end else if (busy) begin
            // Default stage-0 bubbles.  A B pair overrides both product
            // channels in all four row lanes.
            for (lane=0; lane<4; lane=lane+1) begin
                mul_valid0[lane*16] <= 1'b0;
                mul_last0[lane*16] <= 1'b0;
                mul_valid1[lane*16] <= 1'b0;
                mul_last1[lane*16] <= 1'b0;
            end
            if (input_fire0 && !input_is_b0) begin
                a_data[input_pos0] <= stream_data;
                a_valid[input_pos0] <= 1'b1;
            end
            if (input_fire1 && !input_is_b1) begin
                a_data[input_pos1] <= stream_data1;
                a_valid[input_pos1] <= 1'b1;
            end

            if (launch_b_pair) begin
                for (lane=0; lane<4; lane=lane+1) begin
                    flat = lane*16;
                    mul_x[flat] <= {34'd0, a_data[{lane[1:0],launch_k}]};
                    mul_x3[flat] <= {34'd0, a_data[{lane[1:0],launch_k}]} +
                                     {33'd0, a_data[{lane[1:0],launch_k}],1'b0};

                    if (launch_b0) begin
                        mul_y0[flat] <= stream_data >> 2;
                        mul_acc0[flat] <= radix4_term(
                            {34'd0, a_data[{lane[1:0],input_k0}]},
                            {34'd0, a_data[{lane[1:0],input_k0}]} +
                            {33'd0, a_data[{lane[1:0],input_k0}],1'b0},
                            stream_data[1:0]);
                        mul_tag0[flat] <= {lane[1:0],input_j0};
                        mul_valid0[flat] <= a_valid[{lane[1:0],input_k0}];
                        mul_last0[flat] <= launch_last_pair;
                    end
                    if (launch_b1) begin
                        mul_y1[flat] <= stream_data1 >> 2;
                        mul_acc1[flat] <= radix4_term(
                            {34'd0, a_data[{lane[1:0],input_k1}]},
                            {34'd0, a_data[{lane[1:0],input_k1}]} +
                            {33'd0, a_data[{lane[1:0],input_k1}],1'b0},
                            stream_data1[1:0]);
                        mul_tag1[flat] <= {lane[1:0],input_j1};
                        mul_valid1[flat] <= a_valid[{lane[1:0],input_k1}];
                        mul_last1[flat] <= launch_last_pair;
                    end
                end
            end

            for (stage=1; stage<16; stage=stage+1) begin
                for (lane=0; lane<4; lane=lane+1) begin
                    flat = lane*16 + stage;
                    mul_x[flat] <= {mul_x[flat-1][63:0],2'b0};
                    mul_x3[flat] <= {mul_x3[flat-1][63:0],2'b0};
                    mul_y0[flat] <= mul_y0[flat-1] >> 2;
                    mul_acc0[flat] <= mul_acc0[flat-1] +
                        radix4_term({mul_x[flat-1][63:0],2'b0},
                                    {mul_x3[flat-1][63:0],2'b0},
                                    mul_y0[flat-1][1:0]);
                    mul_tag0[flat] <= mul_tag0[flat-1];
                    mul_valid0[flat] <= mul_valid0[flat-1];
                    mul_last0[flat] <= mul_last0[flat-1];
                    mul_y1[flat] <= mul_y1[flat-1] >> 2;
                    mul_acc1[flat] <= mul_acc1[flat-1] +
                        radix4_term({mul_x[flat-1][63:0],2'b0},
                                    {mul_x3[flat-1][63:0],2'b0},
                                    mul_y1[flat-1][1:0]);
                    mul_tag1[flat] <= mul_tag1[flat-1];
                    mul_valid1[flat] <= mul_valid1[flat-1];
                    mul_last1[flat] <= mul_last1[flat-1];
                end
            end

            // The two adjacent B words have distinct j values, so all eight
            // tags retiring in one cycle are distinct.
            for (lane=0; lane<4; lane=lane+1) begin
                flat = lane*16 + 15;
                if (mul_valid0[flat])
                    accumulator[mul_tag0[flat]] <= accumulator[mul_tag0[flat]] + mul_acc0[flat];
                if (mul_valid1[flat])
                    accumulator[mul_tag1[flat]] <= accumulator[mul_tag1[flat]] + mul_acc1[flat];
            end

            if ((mul_valid0[15] && mul_last0[15]) ||
                (mul_valid0[31] && mul_last0[31]) ||
                (mul_valid0[47] && mul_last0[47]) ||
                (mul_valid0[63] && mul_last0[63]) ||
                (mul_valid1[15] && mul_last1[15]) ||
                (mul_valid1[31] && mul_last1[31]) ||
                (mul_valid1[47] && mul_last1[47]) ||
                (mul_valid1[63] && mul_last1[63])) begin
                for (i=0;i<16;i=i+1) begin
                    // Both products in the final B32/B33 pair retire in this
                    // cycle.  Select at most one matching row channel before
                    // the final 66-bit addition, avoiding a two-adder chain.
                    flat = (i >> 2) * 16 + 15;
                    if (mul_valid0[flat] && mul_last0[flat] &&
                        (mul_tag0[flat] == i[3:0]))
                        result_snapshot[i] <= accumulator[i] + mul_acc0[flat];
                    else if (mul_valid1[flat] && mul_last1[flat] &&
                             (mul_tag1[flat] == i[3:0]))
                        result_snapshot[i] <= accumulator[i] + mul_acc1[flat];
                    else
                        result_snapshot[i] <= accumulator[i];
                end
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end
end
endmodule

// Area-oriented implementation for generic SoC use.  Four DSP multipliers
// match the four products launched by each B word, while the 16 accumulators
// retain the same streaming protocol as the evaluation core.
module matmul_batch_core_dsp (
    input clk, input resetn, input start,
    input stream_valid, input [4:0] stream_index, input [31:0] stream_data,
    output reg busy, output reg done,
    input [3:0] result_index, output [65:0] result_data
);
reg [31:0] a_data [0:15];
reg [65:0] accumulator [0:15];
reg [65:0] result_snapshot [0:15];
wire input_fire = busy && stream_valid;
wire input_is_b = stream_index[4];
wire [1:0] input_k = stream_index[3:2];
wire [1:0] input_j = stream_index[1:0];

// Deliberate '*' operators: generic mode permits DSP inference.  Keeping four
// lanes is the minimum needed to accept one B word every cycle without adding
// a ready/backpressure signal to the established interface.
wire [63:0] product0 = a_data[{2'd0,input_k}] * stream_data;
wire [63:0] product1 = a_data[{2'd1,input_k}] * stream_data;
wire [63:0] product2 = a_data[{2'd2,input_k}] * stream_data;
wire [63:0] product3 = a_data[{2'd3,input_k}] * stream_data;
assign result_data = result_snapshot[result_index];

integer i;
always @(posedge clk) begin
    if (!resetn) begin
        busy <= 1'b0;
        done <= 1'b0;
        for (i=0; i<16; i=i+1) begin
            a_data[i] <= 32'd0;
            accumulator[i] <= 66'd0;
            result_snapshot[i] <= 66'd0;
        end
    end else begin
        done <= 1'b0;
        if (start && !busy) begin
            busy <= 1'b1;
            for (i=0; i<16; i=i+1)
                accumulator[i] <= 66'd0;
            if (stream_valid && !stream_index[4])
                a_data[stream_index[3:0]] <= stream_data;
        end else if (input_fire && !input_is_b) begin
            a_data[stream_index[3:0]] <= stream_data;
        end else if (input_fire) begin
            accumulator[{2'd0,input_j}] <= accumulator[{2'd0,input_j}] + {2'd0,product0};
            accumulator[{2'd1,input_j}] <= accumulator[{2'd1,input_j}] + {2'd0,product1};
            accumulator[{2'd2,input_j}] <= accumulator[{2'd2,input_j}] + {2'd0,product2};
            accumulator[{2'd3,input_j}] <= accumulator[{2'd3,input_j}] + {2'd0,product3};
            if (stream_index == 5'd31) begin
                for (i=0; i<16; i=i+1)
                    result_snapshot[i] <= accumulator[i];
                result_snapshot[3]  <= accumulator[3]  + {2'd0,product0};
                result_snapshot[7]  <= accumulator[7]  + {2'd0,product1};
                result_snapshot[11] <= accumulator[11] + {2'd0,product2};
                result_snapshot[15] <= accumulator[15] + {2'd0,product3};
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end
end
endmodule
