module PE (
    input aclk,
    input aresetn,
    input signed [8:0] data,
    input signed [7:0] weight,
    input first,
    output reg signed [18:0] result
);
    wire signed [8:0] weight_ext;
    (* use_dsp = "yes" *) wire signed [17:0] mult_result;
    wire signed [18:0] mult_result_ext;

    assign weight_ext = $signed({weight[7], weight});
    assign mult_result = data * weight_ext;
    assign mult_result_ext = $signed({mult_result[17], mult_result});
    
    always @(posedge aclk) begin
        if(!aresetn) begin
            result <= 19'sd0;
        end
        else if(first) begin
            result <= mult_result_ext;
        end
        else begin
            result <= result + mult_result_ext;
        end
    end

endmodule
