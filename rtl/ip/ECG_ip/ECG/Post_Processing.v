module Post_Processing (
    input aclk,
    input aresetn,

    input data_in_valid,
    input [75:0] pe_bank_result_0,
    input [75:0] pe_bank_result_1,
    input [75:0] pe_bank_result_2,
    input [75:0] pe_bank_result_3,
    input [75:0] pe_bank_result_4,

    input [1:0] stage,

    output reg data_out_valid,
    output reg [31:0] data_out
);

    localparam IDLE  = 5'b00001;
    localparam BANK_1 = 5'b00010;
    localparam BANK_2 = 5'b00100;
    localparam BANK_3 = 5'b01000;
    localparam BANK_4 = 5'b10000;

    reg [4:0] input_state;

    reg [75:0] pe_bank_result_buf_1;
    reg [75:0] pe_bank_result_buf_2;
    reg [75:0] pe_bank_result_buf_3;
    reg [75:0] pe_bank_result_buf_4;

    reg signed [18:0] requan_data_in_0;
    reg signed [18:0] requan_data_in_1;
    reg signed [18:0] requan_data_in_2;
    reg signed [18:0] requan_data_in_3;
    reg requan_data_in_valid;
    reg [1:0] requan_stage;

    wire [7:0] requan_data_out_0;
    wire [7:0] requan_data_out_1;
    wire [7:0] requan_data_out_2;
    wire [7:0] requan_data_out_3;
    wire [31:0] requan_data_word = {requan_data_out_3, requan_data_out_2, requan_data_out_1, requan_data_out_0};

    reg [31:0] pool_buf_0;
    reg [31:0] pool_buf_1;
    reg [31:0] pool_buf_2;
    reg [31:0] pool_buf_3;
    reg [31:0] pool_buf_4;
    reg output_active;
    reg output_active_now;

    reg [3:0] output_start_delay;
    reg [4:0] output_valid_delay;

    always @(posedge aclk) begin
        if(!aresetn) begin
            input_state <= IDLE;
            pe_bank_result_buf_1 <= 76'd0;
            pe_bank_result_buf_2 <= 76'd0;
            pe_bank_result_buf_3 <= 76'd0;
            pe_bank_result_buf_4 <= 76'd0;
            requan_data_in_0 <= 19'sd0;
            requan_data_in_1 <= 19'sd0;
            requan_data_in_2 <= 19'sd0;
            requan_data_in_3 <= 19'sd0;
            requan_data_in_valid <= 1'b0;
            requan_stage <= 2'd0;
            output_active <= 1'b1;
            output_active_now <= 1'b1;
        end
        else begin
            case(input_state)
                IDLE: begin
                    if(data_in_valid) begin
                        pe_bank_result_buf_1 <= pe_bank_result_1;
                        pe_bank_result_buf_2 <= pe_bank_result_2;
                        pe_bank_result_buf_3 <= pe_bank_result_3;
                        pe_bank_result_buf_4 <= pe_bank_result_4;
                        requan_stage <= stage;
                        feed_requan_bank(pe_bank_result_0);
                        if(stage[1] == 1'b0) begin
                            output_active <= ~output_active;
                        end
                        input_state <= BANK_1;
                    end
                    else begin
                        requan_data_in_valid <= 1'b0;
                    end
                end
                BANK_1: begin
                    feed_requan_bank(pe_bank_result_buf_1);
                    input_state <= BANK_2;
                end
                BANK_2: begin
                    feed_requan_bank(pe_bank_result_buf_2);
                    input_state <= BANK_3;
                end
                BANK_3: begin
                    feed_requan_bank(pe_bank_result_buf_3);
                    input_state <= BANK_4;
                end
                BANK_4: begin
                    output_active_now <= output_active;
                    feed_requan_bank(pe_bank_result_buf_4);
                    input_state <= IDLE;
                end
                default: begin
                    input_state <= IDLE;
                end
            endcase
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            pool_buf_0 <= 32'd0;
            pool_buf_1 <= 32'd0;
            pool_buf_2 <= 32'd0;
            pool_buf_3 <= 32'd0;
            pool_buf_4 <= 32'd0;
            data_out <= 32'd0;
            output_valid_delay <= 5'd0;
        end
        else begin
            output_valid_delay <= {output_valid_delay[3:0], output_start_delay[3]};
            if (output_valid_delay[0]) begin
                if(requan_stage[1]) begin
                    data_out <= requan_data_word;
                end
                else begin
                    if(output_active_now) begin
                        data_out <= max_u8_word(pool_buf_0, requan_data_word);
                    end
                    else begin
                        pool_buf_0 <= requan_data_word;
                    end
                end
            end
            else if (output_valid_delay[1]) begin
                if(requan_stage[1]) begin
                    data_out <= requan_data_word;
                end
                else begin
                    if(output_active_now) begin
                        data_out <= max_u8_word(pool_buf_1, requan_data_word);
                    end
                    else begin
                        pool_buf_1 <= requan_data_word;
                    end
                end
            end
            else if (output_valid_delay[2]) begin
                if(requan_stage[1]) begin
                    data_out <= requan_data_word;
                end
                else begin
                    if(output_active_now) begin
                        data_out <= max_u8_word(pool_buf_2, requan_data_word);
                    end
                    else begin
                        pool_buf_2 <= requan_data_word;
                    end
                end
            end
            else if (output_valid_delay[3]) begin
                if(requan_stage[1]) begin
                    data_out <= requan_data_word;
                end
                else begin
                    if(output_active_now) begin
                        data_out <= max_u8_word(pool_buf_3, requan_data_word);
                    end
                    else begin
                        pool_buf_3 <= requan_data_word;
                    end
                end
            end
            else if (output_valid_delay[4]) begin
                if(requan_stage[1]) begin
                    data_out <= requan_data_word;
                end
                else begin
                    if(output_active_now) begin
                        data_out <= max_u8_word(pool_buf_4, requan_data_word);
                    end
                    else begin
                        pool_buf_4 <= requan_data_word;
                    end
                end
            end
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            data_out_valid <= 1'b0;
        end
        else begin
            if(output_active_now & (|output_valid_delay)) begin
                data_out_valid <= 1'b1;
            end
            else begin
                data_out_valid <= 1'b0;
            end
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            output_start_delay <= 4'd0;
        end
        else begin
            output_start_delay <= {output_start_delay[2:0], data_in_valid};
        end
    end

    Requan_ReLU u_Requan_ReLU_0 (
        .aclk(aclk),
        .aresetn(aresetn),
        .data_in(requan_data_in_0),
        .data_in_valid(requan_data_in_valid),
        .stage(requan_stage),
        .data_ReLU(requan_data_out_0)
    );

    Requan_ReLU u_Requan_ReLU_1 (
        .aclk(aclk),
        .aresetn(aresetn),
        .data_in(requan_data_in_1),
        .data_in_valid(requan_data_in_valid),
        .stage(requan_stage),
        .data_ReLU(requan_data_out_1)
    );

    Requan_ReLU u_Requan_ReLU_2 (
        .aclk(aclk),
        .aresetn(aresetn),
        .data_in(requan_data_in_2),
        .data_in_valid(requan_data_in_valid),
        .stage(requan_stage),
        .data_ReLU(requan_data_out_2)
    );

    Requan_ReLU u_Requan_ReLU_3 (
        .aclk(aclk),
        .aresetn(aresetn),
        .data_in(requan_data_in_3),
        .data_in_valid(requan_data_in_valid),
        .stage(requan_stage),
        .data_ReLU(requan_data_out_3)
    );

    task feed_requan_bank;
        input [75:0] bank_result;
        begin
            requan_data_in_0 <= $signed(bank_result[18:0]);
            requan_data_in_1 <= $signed(bank_result[37:19]);
            requan_data_in_2 <= $signed(bank_result[56:38]);
            requan_data_in_3 <= $signed(bank_result[75:57]);
            requan_data_in_valid <= 1'b1;
        end
    endtask

    function [31:0] max_u8_word;
        input [31:0] data_a;
        input [31:0] data_b;
        begin
            max_u8_word[7:0] =
                (data_a[7:0] > data_b[7:0]) ? data_a[7:0] : data_b[7:0];
            max_u8_word[15:8] =
                (data_a[15:8] > data_b[15:8]) ? data_a[15:8] : data_b[15:8];
            max_u8_word[23:16] =
                (data_a[23:16] > data_b[23:16]) ? data_a[23:16] : data_b[23:16];
            max_u8_word[31:24] =
                (data_a[31:24] > data_b[31:24]) ? data_a[31:24] : data_b[31:24];
        end
    endfunction

endmodule
