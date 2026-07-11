module ECG_Result_Collector (
    input aclk,
    input aresetn,

    input fc2_out_valid,
    input [31:0] fc2_out_word,

    output reg [7:0] result_0,
    output reg [7:0] result_1,
    output reg [7:0] result_2,
    output reg [7:0] result_3,
    output reg [7:0] result_4,
    output reg [2:0] infer_result,
    output reg infer_done
);

    reg [2:0] result_counter;
    reg [7:0] result_compare;
    wire [7:0] fc2_result = fc2_out_word[7:0];

    always @(posedge aclk) begin
        if (!aresetn) begin
            result_counter <= 3'd0;
            infer_done <= 1'b0;
        end
        else if (fc2_out_valid) begin
            if (result_counter == 3'd4) begin
                result_counter <= 3'd0;
                infer_done <= 1'b1;
            end
            else begin
                result_counter <= result_counter + 3'd1;
                infer_done <= 1'b0;
            end
        end
        else begin
            result_counter <= 3'd0;
            infer_done <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            result_0 <= 8'd0;
            result_1 <= 8'd0;
            result_2 <= 8'd0;
            result_3 <= 8'd0;
            result_4 <= 8'd0;
            result_compare <= 8'd0;
            infer_result <= 3'd0;
        end
        else if (fc2_out_valid) begin
            case (result_counter)
                3'd0: begin
                    result_0 <= fc2_result;
                    result_compare <= fc2_result;
                    infer_result <= 3'd0;
                end
                3'd1: begin
                    result_1 <= fc2_result;
                    result_compare <= (fc2_result > result_compare) ? fc2_result : result_compare;
                    infer_result <= (fc2_result > result_compare) ? 3'd1 : infer_result;
                end
                3'd2: begin
                    result_2 <= fc2_result;
                    result_compare <= (fc2_result > result_compare) ? fc2_result : result_compare;
                    infer_result <= (fc2_result > result_compare) ? 3'd2 : infer_result;
                end
                3'd3: begin
                    result_3 <= fc2_result;
                    result_compare <= (fc2_result > result_compare) ? fc2_result : result_compare;
                    infer_result <= (fc2_result > result_compare) ? 3'd3 : infer_result;
                end
                3'd4: begin
                    result_4 <= fc2_result;
                    result_compare <= (fc2_result > result_compare) ? fc2_result : result_compare;
                    infer_result <= (fc2_result > result_compare) ? 3'd4 : infer_result;
                end
                default: ;
            endcase
        end
    end

endmodule
