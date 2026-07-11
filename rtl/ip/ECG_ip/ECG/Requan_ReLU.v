module Requan_ReLU (
    input aclk,
    input aresetn,

    input signed [18:0] data_in,
    input data_in_valid,

    input [1:0] stage,

    output reg [7:0] data_ReLU
);

    localparam signed [17:0] MULT_CONV1 = 18'sd50203;
    localparam signed [17:0] MULT_CONV2 = 18'sd19708;
    localparam signed [17:0] MULT_FC1   = 18'sd36685;
    localparam signed [17:0] MULT_FC2   = 18'sd108313;

    localparam signed [36:0] ROUNDING_OFFSET = 37'sd4194304; // 2^22

    reg signed [17:0] multiplier_selected;
    reg [7:0] zero_point_selected;
    reg [7:0] clamp_min_selected;
    reg [7:0] clamp_max_selected;

    always @(*) begin
        case(stage)
            2'd0: begin
                multiplier_selected = MULT_CONV1;
                zero_point_selected = 8'd139;
                clamp_min_selected = 8'd139;
                clamp_max_selected = 8'd224;
            end
            2'd1: begin
                multiplier_selected = MULT_CONV2;
                zero_point_selected = 8'd137;
                clamp_min_selected = 8'd137;
                clamp_max_selected = 8'd158;
            end
            2'd2: begin
                multiplier_selected = MULT_FC1;
                zero_point_selected = 8'd142;
                clamp_min_selected = 8'd142;
                clamp_max_selected = 8'd158;
            end
            2'd3: begin
                multiplier_selected = MULT_FC2;
                zero_point_selected = 8'd125;
                clamp_min_selected = 8'd0;
                clamp_max_selected = 8'd255;
            end
            default: ;
        endcase
    end

    // Pipeline stage 1: signed multiply.
    (* use_dsp = "yes" *) reg signed [36:0] product_s1;
    reg [7:0] zero_point_s1;
    reg [7:0] clamp_min_s1;
    reg [7:0] clamp_max_s1;

    // Pipeline stage 2: signed round-to-nearest and arithmetic right shift.
    reg signed [18:0] rounded_s2;
    reg [7:0] zero_point_s2;
    reg [7:0] clamp_min_s2;
    reg [7:0] clamp_max_s2;

    // Pipeline stage 3: add the output zero-point.
    reg signed [19:0] offset_s3;
    reg [7:0] clamp_min_s3;
    reg [7:0] clamp_max_s3;


    always @(posedge aclk) begin
        if(!aresetn) begin
            product_s1 <= 37'sd0;
            zero_point_s1 <= 8'd0;
            clamp_min_s1 <= 8'd0;
            clamp_max_s1 <= 8'd0;

            rounded_s2 <= 19'sd0;
            zero_point_s2 <= 8'd0;
            clamp_min_s2 <= 8'd0;
            clamp_max_s2 <= 8'd0;

            offset_s3 <= 20'sd0;
            clamp_min_s3 <= 8'd0;
            clamp_max_s3 <= 8'd0;

            data_ReLU <= 8'd0;
        end
        else begin
            // Stage 1
            if(data_in_valid) begin
                product_s1 <= data_in * multiplier_selected;
                zero_point_s1 <= zero_point_selected;
                clamp_min_s1 <= clamp_min_selected;
                clamp_max_s1 <= clamp_max_selected;
            end

            // Stage 2. Apply the rounding to the magnitude so negative and positive values are treated symmetrically.
            if(product_s1 >= 0) begin
                rounded_s2 <= (product_s1 + ROUNDING_OFFSET) >>> 23;
            end
            else begin
                rounded_s2 <= -(((-product_s1) + ROUNDING_OFFSET) >>> 23);
            end

            zero_point_s2 <= zero_point_s1;
            clamp_min_s2 <= clamp_min_s1;
            clamp_max_s2 <= clamp_max_s1;

            // Stage 3
            offset_s3 <=
                $signed({rounded_s2[18], rounded_s2})
                + $signed({12'd0, zero_point_s2});
            clamp_min_s3 <= clamp_min_s2;
            clamp_max_s3 <= clamp_max_s2;

            // Stage 4. Clamp thresholds are already expressed in the quantized output domain.
            if(offset_s3 < $signed({12'd0, clamp_min_s3})) begin
                data_ReLU <= clamp_min_s3;
            end
            else if(offset_s3 > $signed({12'd0, clamp_max_s3})) begin
                data_ReLU <= clamp_max_s3;
            end
            else begin
                data_ReLU <= offset_s3[7:0];
            end
        end
    end

endmodule
