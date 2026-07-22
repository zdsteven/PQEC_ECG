// Streaming 4x4 unsigned matrix multiplier for the evaluation path.
// External layout remains A[0..15], B[0..15].  Sixteen fixed C engines process
// one radix-4 digit plane per cycle.  Their private operand state lets group N
// compute while the input registers receive group N+1, sustaining one group
// per sixteen 50 MHz cycles (the SRAM stream's effective 100 Mword/s rate)
// with one physical core.  No Verilog multiplication operator or DSP is used.
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
reg [31:0] b_shift [0:15];
// Keep the four radix-4 operand states physically local to each C engine.
// The deliberate four-way replication removes the row/column-wide shifted-A
// nets which are cheap in registers but disproportionately expensive to route.
reg [65:0] c_a_shift [0:63];
reg [65:0] c_a3_shift [0:63];
reg [31:0] c_b_shift [0:63];
reg [65:0] accumulator [0:15];
reg [65:0] result_snapshot [0:15];
reg [3:0] digit_step;
reg       compute_active;

wire start_accept = start && !busy;
wire input_fire0 = (busy || start_accept) && stream_valid;
wire input_fire1 = (busy || start_accept) && stream_valid1;
wire input_is_b0 = stream_index[4];
wire input_is_b1 = stream_index1[4];
wire [3:0] input_pos0 = stream_index[3:0];
wire [3:0] input_pos1 = stream_index1[3:0];
wire launch_b0 = input_fire0 && input_is_b0;
wire launch_b1 = input_fire1 && input_is_b1;
// Stream indices 28/29 (B30/B31) arrive one cycle after the prior group's
// final digit.  The arithmetic state is then free and all A words are stable,
// so prepare the next group's operands before the B32/B33 launch cycle.
wire preload_operands = launch_b0 && (stream_index == 5'd28);
wire launch_last = (launch_b0 && (stream_index == 5'd31)) ||
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

wire [31:0] first_b_word [0:15];
genvar b;
generate
    for (b=0; b<16; b=b+1) begin : gen_first_b_word
        if (b == 14)
            assign first_b_word[b] = stream_data;
        else if (b == 15)
            assign first_b_word[b] = stream_data1;
        else
            assign first_b_word[b] = b_shift[b];
    end
endgenerate

wire [65:0] digit_sum [0:15];
genvar c;
generate
    for (c=0; c<16; c=c+1) begin : gen_digit_sum
        localparam integer ROW_BASE = (c/4)*4;
        localparam integer COL = c%4;
        wire [1:0] digit0 = launch_last ? first_b_word[COL][1:0]
                                        : c_b_shift[c*4][1:0];
        wire [1:0] digit1 = launch_last ? first_b_word[4+COL][1:0]
                                        : c_b_shift[c*4+1][1:0];
        wire [1:0] digit2 = launch_last ? first_b_word[8+COL][1:0]
                                        : c_b_shift[c*4+2][1:0];
        wire [1:0] digit3 = launch_last ? first_b_word[12+COL][1:0]
                                        : c_b_shift[c*4+3][1:0];
        wire [65:0] term0 = radix4_term(c_a_shift[c*4],
                                        c_a3_shift[c*4], digit0);
        wire [65:0] term1 = radix4_term(c_a_shift[c*4+1],
                                        c_a3_shift[c*4+1], digit1);
        wire [65:0] term2 = radix4_term(c_a_shift[c*4+2],
                                        c_a3_shift[c*4+2], digit2);
        wire [65:0] term3 = radix4_term(c_a_shift[c*4+3],
                                        c_a3_shift[c*4+3], digit3);
        assign digit_sum[c] = (term0 + term1) + (term2 + term3);
    end
endgenerate

integer i;
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
        digit_step <= 4'd0;
        compute_active <= 1'b0;
        for (i=0;i<16;i=i+1) begin
            a_data[i] = 32'd0;
            b_shift[i] = 32'd0;
            accumulator[i] = 66'd0;
            result_snapshot[i] = 66'd0;
        end
        for (i=0;i<64;i=i+1) begin
            c_a_shift[i] = 66'd0;
            c_a3_shift[i] = 66'd0;
            c_b_shift[i] = 32'd0;
        end
    end else begin
        done <= 1'b0;

        if (start_accept)
            busy <= 1'b1;

        // Loading is independent of compute_active.  Once a group launches,
        // c_* owns all of its arithmetic state and A/B may be overwritten by
        // the next group without disturbing the running calculation.
        if (input_fire0 || input_fire1) begin
            if (input_fire0 && !input_is_b0)
                a_data[input_pos0] <= stream_data;
            else if (launch_b0)
                b_shift[input_pos0] <= stream_data;
            if (input_fire1 && !input_is_b1)
                a_data[input_pos1] <= stream_data1;
            else if (launch_b1)
                b_shift[input_pos1] <= stream_data1;

            if (preload_operands) begin
                for (i=0;i<64;i=i+1) begin
                    c_a_shift[i] <= {34'd0,
                        a_data[(i/16)*4+(i%4)]};
                    c_a3_shift[i] <=
                        {34'd0,a_data[(i/16)*4+(i%4)]} +
                        {33'd0,a_data[(i/16)*4+(i%4)],1'b0};
                end
            end

            // B33 marks the end of input.  B32/B33 use a direct digit-zero
            // bypass while prior B words come from b_shift.  Load the private
            // compute state directly at this boundary, after the prior group
            // has retired, and advance it immediately to digit one.
            if (launch_last) begin
                busy <= 1'b0;
                compute_active <= 1'b1;
                digit_step <= 4'd1;
                for (i=0;i<16;i=i+1) begin
                    accumulator[i] <= digit_sum[i];
                end
                for (i=0;i<64;i=i+1) begin
                    c_a_shift[i] <= {c_a_shift[i][63:0],2'b0};
                    c_a3_shift[i] <= {c_a3_shift[i][63:0],2'b0};
                    c_b_shift[i] <= first_b_word[
                        (i%4)*4+((i/4)%4)] >> 2;
                end
            end
        end

        if (compute_active) begin
            for (i=0;i<16;i=i+1) begin
                accumulator[i] <= accumulator[i] + digit_sum[i];
                if (digit_step == 4'd15)
                    result_snapshot[i] <= accumulator[i] + digit_sum[i];
            end
            if (digit_step == 4'd15) begin
                compute_active <= 1'b0;
                done <= 1'b1;
            end else begin
                digit_step <= digit_step + 4'd1;
                for (i=0;i<64;i=i+1) begin
                    c_a_shift[i] <= {c_a_shift[i][63:0],2'b0};
                    c_a3_shift[i] <= {c_a3_shift[i][63:0],2'b0};
                    c_b_shift[i] <= c_b_shift[i] >> 2;
                end
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
