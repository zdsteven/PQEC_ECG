module ECG (
    input aclk,
    input aresetn,

    input load_ecg_en,
    input [31:0] load_ecg_data,
    input [5:0] load_ecg_address,

    input start_inference,

    output [7:0] result_0,
    output [7:0] result_1,
    output [7:0] result_2,
    output [7:0] result_3,
    output [7:0] result_4,
    output [2:0] infer_result,
    output infer_done
);  
    localparam IDLE  = 5'b00001;
    localparam CONV1 = 5'b00010;
    localparam CONV2 = 5'b00100;
    localparam FC1   = 5'b01000;
    localparam FC2   = 5'b10000;


//-------------------------------{ram rom}begin-----------------------------//

    (* ram_style = "distributed" *) reg [31:0] ecg_data_in [0:49];
    (* ram_style = "block" *) reg [31:0] pool_1 [0:479];
    (* ram_style = "block" *) reg [31:0] pool_2 [0:224];
    (* ram_style = "distributed" *) reg [31:0] fc_middle [0:24];

//-------------------------------{ram rom}end-------------------------------//

//-------------------------------{ram rom access}begin----------------------//
    wire ecg_data_we;
    wire [5:0] ecg_data_waddr;
    wire [31:0] ecg_data_din;
    wire ecg_data_re;
    wire [5:0] ecg_data_raddr;
    reg [31:0] ecg_data_rdata;

    wire pool_1_we;
    reg [8:0] pool_1_waddr;
    wire [31:0] pool_1_din;
    wire pool_1_re;
    wire [8:0] pool_1_raddr;
    reg [31:0] pool_1_rdata;

    wire pool_2_we;
    reg [7:0] pool_2_waddr;
    wire [31:0] pool_2_din;
    wire pool_2_re;
    wire [7:0] pool_2_raddr;
    reg [31:0] pool_2_rdata;

    wire fc_middle_we;
    reg [4:0] fc_middle_waddr;
    wire [31:0] fc_middle_din;
    wire fc_middle_re;
    wire [4:0] fc_middle_raddr;
    reg [31:0] fc_middle_rdata;
//-------------------------------{ram rom access}end------------------------//

//-------------------------------{FSM_Ctrl}begin----------------------------//
    reg [4:0] current_state;
    reg [4:0] next_state;
    reg [3:0] current_stage;
    reg [3:0] current_stage_reg;
//-------------------------------{FSM_Ctrl}end------------------------------//

//-------------------------------{address}begin-----------------------------//
    reg [7:0] ecg_data_addr_base;
    reg [7:0] ecg_data_addr_offset;
    reg [7:0] ecg_data_addr_add;
    reg [1:0] ecg_data_sel;

    reg conv1_en;
    reg [2:0] conv1_weight_addr;

    reg [10:0] pool_1_addr_base;
    reg [10:0] pool_1_addr_offset;
    reg [10:0] pool_1_addr_add;
    reg [1:0] pool_1_sel;

    reg conv2_en;
    reg [7:0] conv2_weight_addr;

    reg [2:0] pool_2_addr_base;
    reg [9:0] pool_2_addr_offset;
    reg [9:0] pool_2_addr_add;
    reg [1:0] pool_2_sel;

    reg fc1_en;
    reg [12:0] fc1_weight_addr;

    reg [6:0] fc_middle_addr_offset;
    reg [6:0] fc_middle_addr_add;
    reg [1:0] fc_middle_sel;

    reg fc2_en;
    reg [6:0] fc2_weight_addr;
//-------------------------------{address}end-------------------------------//

//-------------------------------{Processing_Element}begin------------------//
    reg [1:0] post_processing_stage;

    reg signed [8:0] pe_bank_data_in;
    wire [31:0] pe_bank_weight_in [0:4];
    reg pe_first;
    wire signed [18:0] pe_bank_result [0:19];
    wire pe_result_valid;
    wire [31:0] pe_post_result_out;
    wire pe_post_result_valid;

    reg [7:0] ecg_data_pe_in;
    reg [2:0] conv1_result_valid;

    reg [7:0] pool_1_pe_in;
    reg [2:0] conv2_result_valid;

    reg [7:0] pool_2_pe_in;
    reg [2:0] fc1_result_valid;

    reg [7:0] fc_middle_pe_in;
    reg [2:0] fc2_result_valid;
//-------------------------------{Processing_Element}end--------------------//

//--------------------------------------------------------------------------------------------------------//
//--------------------------------------------------------------------------------------------------------//
//--------------------------------------------------------------------------------------------------------//

//-------------------------------{FSM_Ctrl}begin----------------------------//

    always @(posedge aclk) begin
        if(!aresetn) begin
            current_state <= IDLE;
        end
        else begin
            current_state <= next_state;
        end
    end

    always @(*) begin
        case(current_state)
            IDLE: begin
                if(start_inference) begin
                    next_state = CONV1;
                end
                else begin
                    next_state = IDLE;
                end
            end
            CONV1: begin
                if(ecg_data_addr_base == 8'd191 && ecg_data_addr_offset == 8'd6) begin
                    next_state = CONV2;
                end
                else begin
                    next_state = CONV1;
                end
            end
            CONV2: begin
                if(pool_1_addr_base == 11'd1780 && pool_1_addr_offset == 11'd139) begin
                    next_state = FC1;
                end
                else begin
                    next_state = CONV2;
                end
            end
            FC1: begin
                if(pool_2_addr_base == 3'd4 && pool_2_addr_offset == 10'd899) begin
                    next_state = FC2;
                end
                else begin
                    next_state = FC1;
                end
            end
            FC2: begin
                if(fc_middle_addr_offset == 7'd99) begin
                    next_state = IDLE;
                end
                else begin
                    next_state = FC2;
                end
            end
            default: begin
                next_state = IDLE;
            end
        endcase
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            current_stage <= 4'd0;
            current_stage_reg <= 4'd0;
        end
        else begin
            current_stage <= current_state[4:1];
            current_stage_reg <= current_stage;
        end
    end

//-------------------------------{FSM_Ctrl}end------------------------------//

//-------------------------------{address}begin-----------------------------//
    always @(posedge aclk) begin
        if(!aresetn) begin
            ecg_data_addr_base <= 8'd0;
            ecg_data_addr_offset <= 8'd0;
        end
        else if (current_state[1]) begin
            if (ecg_data_addr_offset == 8'd6) begin
                ecg_data_addr_offset <= 8'd0;
                ecg_data_addr_base <= ecg_data_addr_base + 8'd1;
            end
            else begin
                ecg_data_addr_offset <= ecg_data_addr_offset + 8'd1;
            end
        end
        else begin
            ecg_data_addr_base <= 8'd0;
            ecg_data_addr_offset <= 8'd0;
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            pool_1_addr_base <= 11'd0;
            pool_1_addr_offset <= 11'd0;
        end
        else if (current_state[2]) begin
            if (pool_1_addr_offset == 11'd139) begin
                pool_1_addr_offset <= 11'd0;
                pool_1_addr_base <= pool_1_addr_base + 11'd20;
            end
            else begin
                pool_1_addr_offset <= pool_1_addr_offset + 11'd1;
            end
        end
        else begin
            pool_1_addr_base <= 11'd0;
            pool_1_addr_offset <= 11'd0;
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            pool_2_addr_base <= 3'd0;
            pool_2_addr_offset <= 10'd0;
        end
        else if (current_state[3]) begin
            if (pool_2_addr_offset == 10'd899) begin
                pool_2_addr_offset <= 10'd0;
                pool_2_addr_base <= pool_2_addr_base + 10'd1;
            end
            else begin
                pool_2_addr_offset <= pool_2_addr_offset + 10'd1;
            end
        end
        else begin
            pool_2_addr_base <= 3'd0;
            pool_2_addr_offset <= 10'd0;
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            fc_middle_addr_offset <= 7'd0;
        end
        else if (current_state[4]) begin
            if (fc_middle_addr_offset == 7'd99) begin
                fc_middle_addr_offset <= 7'd0;
            end
            else begin
                fc_middle_addr_offset <= fc_middle_addr_offset + 7'd1;
            end
        end
        else begin
            fc_middle_addr_offset <= 7'd0;
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            ecg_data_addr_add <= 8'd0;
            pool_1_addr_add <= 11'd0;
            pool_2_addr_add <= 10'd0;
            fc_middle_addr_add <= 7'd0;
            ecg_data_sel <= 2'd0;
            pool_1_sel <= 2'd0;
            pool_2_sel <= 2'd0;
            fc_middle_sel <= 2'd0;
            conv1_en <= 1'b0;
            conv2_en <= 1'b0;
            fc1_en <= 1'b0;
            fc2_en <= 1'b0;
        end
        else begin
            ecg_data_addr_add <= ecg_data_addr_base + ecg_data_addr_offset;
            pool_1_addr_add <= pool_1_addr_base + pool_1_addr_offset;
            pool_2_addr_add <= pool_2_addr_offset;
            fc_middle_addr_add <= fc_middle_addr_offset;
            ecg_data_sel <= ecg_data_addr_add[1:0];
            pool_1_sel <= pool_1_addr_add[1:0];
            pool_2_sel <= pool_2_addr_add[1:0];
            fc_middle_sel <= fc_middle_addr_add[1:0];
            conv1_en <= current_state[1];
            conv2_en <= current_state[2];
            fc1_en <= current_state[3];
            fc2_en <= current_state[4];
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            conv1_weight_addr <= 3'd0;
            conv2_weight_addr <= 8'd0;
        end
        else begin
            conv1_weight_addr <= ecg_data_addr_offset[2:0];
            conv2_weight_addr <= pool_1_addr_offset[7:0];
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            fc1_weight_addr <= 13'd0;
        end
        else if (fc1_en) begin
            if (fc1_weight_addr == 13'd4499) begin
                fc1_weight_addr <= 13'd0;
            end
            else begin
                fc1_weight_addr <= fc1_weight_addr + 13'd1;
            end
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            fc2_weight_addr <= 7'd0;
        end
        else if (fc2_en) begin
            if (fc2_weight_addr == 7'd99) begin
                fc2_weight_addr <= 7'd0;
            end
            else begin
                fc2_weight_addr <= fc2_weight_addr + 7'd1;
            end
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            pool_1_waddr <= 9'd0;
        end
        else if(pool_1_we) begin
            if(pool_1_waddr == 9'd479) begin
                pool_1_waddr <= 9'd0;
            end
            else begin
                pool_1_waddr <= pool_1_waddr + 9'd1;
            end
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            pool_2_waddr <= 8'd0;
        end
        else if(pool_2_we) begin
            if(pool_2_waddr == 8'd224) begin
                pool_2_waddr <= 8'd0;
            end
            else begin
                pool_2_waddr <= pool_2_waddr + 8'd1;
            end
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            fc_middle_waddr <= 5'd0;
        end
        else if(fc_middle_we) begin
            if(fc_middle_waddr == 5'd24) begin
                fc_middle_waddr <= 5'd0;
            end
            else begin
                fc_middle_waddr <= fc_middle_waddr + 5'd1;
            end
        end
    end

//-------------------------------{address}end-------------------------------//

//-------------------------------{Processing_Element}begin------------------//
    assign pe_result_valid =  (post_processing_stage == 2'd0) ? conv1_result_valid[2] 
                            : (post_processing_stage == 2'd1) ? conv2_result_valid[2] 
                            : (post_processing_stage == 2'd2) ? fc1_result_valid[2] 
                            : (post_processing_stage == 2'd3) ? fc2_result_valid[2] 
                            : 1'b0;

    always @(posedge aclk) begin
        if(!aresetn) begin
            pe_bank_data_in <= 9'sd0;
            pe_first <= 1'b0;
        end
        else begin
            if(current_stage_reg[0]) begin
                pe_bank_data_in <= $signed({1'b0, ecg_data_pe_in}) - 9'sd150;
                pe_first <= (ecg_data_addr_offset == 8'd2);
            end
            else if(current_stage_reg[1]) begin
                pe_bank_data_in <= $signed({1'b0, pool_1_pe_in}) - 9'sd139;
                pe_first <= (pool_1_addr_offset == 11'd2);
            end
            else if(current_stage_reg[2]) begin
                pe_bank_data_in <= $signed({1'b0, pool_2_pe_in}) - 9'sd137;
                pe_first <= (pool_2_addr_offset == 10'd2);
            end
            else if(current_stage_reg[3]) begin
                pe_bank_data_in <= $signed({1'b0, fc_middle_pe_in}) - 9'sd142;
                pe_first <= (fc_middle_addr_offset == 7'd2);
            end
        end
    end

    always @(*) begin
        ecg_data_pe_in  = select_byte(ecg_data_rdata, ecg_data_sel);
        pool_1_pe_in    = select_byte(pool_1_rdata, pool_1_sel);
        pool_2_pe_in    = select_byte(pool_2_rdata, pool_2_sel);
        fc_middle_pe_in = select_byte(fc_middle_rdata, fc_middle_sel);
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            conv1_result_valid <= 3'd0;
            conv2_result_valid <= 3'd0;
            fc1_result_valid <= 3'd0;
            fc2_result_valid <= 3'd0;
        end
        else begin
            conv1_result_valid <= {conv1_result_valid[1:0], (conv1_weight_addr == 3'd6)};
            conv2_result_valid <= {conv2_result_valid[1:0], (conv2_weight_addr == 8'd139)};
            fc1_result_valid <= {fc1_result_valid[1:0], (pool_2_addr_add == 10'd899)};
            fc2_result_valid <= {fc2_result_valid[1:0], (fc2_weight_addr == 7'd99)};
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            post_processing_stage <= 2'd0;
        end
        else begin
            if (conv1_weight_addr == 3'd6) begin
                post_processing_stage <= 2'd0;
            end
            else if(conv2_weight_addr == 8'd139) begin
                post_processing_stage <= 2'd1;
            end
            else if(pool_2_addr_add == 10'd899) begin
                post_processing_stage <= 2'd2;
            end
            else if(fc2_weight_addr == 7'd99) begin
                post_processing_stage <= 2'd3;
            end
            else begin
                post_processing_stage <= post_processing_stage;
            end
        end
    end

    ECG_Weight_ROM u_ECG_Weight_ROM (
        .aclk(aclk),
        .aresetn(aresetn),
        .current_stage_reg(current_stage_reg),
        .conv1_en(conv1_en),
        .conv1_weight_addr(conv1_weight_addr),
        .conv2_en(conv2_en),
        .conv2_weight_addr(conv2_weight_addr),
        .fc1_en(fc1_en),
        .fc1_weight_addr(fc1_weight_addr),
        .fc2_en(fc2_en),
        .fc2_weight_addr(fc2_weight_addr),
        .weight_bank_0(pe_bank_weight_in[0]),
        .weight_bank_1(pe_bank_weight_in[1]),
        .weight_bank_2(pe_bank_weight_in[2]),
        .weight_bank_3(pe_bank_weight_in[3]),
        .weight_bank_4(pe_bank_weight_in[4])
    );

    genvar i;
    generate
        for (i = 0; i < 5; i = i + 1) begin : gen_PE_bank
            PE_bank u_PE_bank (
                .aclk(aclk),
                .aresetn(aresetn),
                .data(pe_bank_data_in),
                .weight(pe_bank_weight_in[i]),
                .first(pe_first),
                .result_0(pe_bank_result[(i << 2) + 0]),
                .result_1(pe_bank_result[(i << 2) + 1]),
                .result_2(pe_bank_result[(i << 2) + 2]),
                .result_3(pe_bank_result[(i << 2) + 3])
            );
        end
    endgenerate

    Post_Processing u_Post_Processing(
    .aclk               (aclk),
    .aresetn            (aresetn),
    .data_in_valid      (pe_result_valid),
    .pe_bank_result_0   ({pe_bank_result[3], pe_bank_result[2], pe_bank_result[1], pe_bank_result[0]}),
    .pe_bank_result_1   ({pe_bank_result[7], pe_bank_result[6], pe_bank_result[5], pe_bank_result[4]}),
    .pe_bank_result_2   ({pe_bank_result[11], pe_bank_result[10], pe_bank_result[9], pe_bank_result[8]}),
    .pe_bank_result_3   ({pe_bank_result[15], pe_bank_result[14], pe_bank_result[13], pe_bank_result[12]}),
    .pe_bank_result_4   ({pe_bank_result[19], pe_bank_result[18], pe_bank_result[17], pe_bank_result[16]}),
    .stage              (post_processing_stage),
    .data_out_valid     (pe_post_result_valid),
    .data_out           (pe_post_result_out)
);
    
//-------------------------------{Processing_Element}end--------------------//

//-------------------------------{ram rom access}begin----------------------//
    assign ecg_data_we = load_ecg_en;
    assign ecg_data_waddr = load_ecg_address;
    assign ecg_data_din = load_ecg_data;
    assign ecg_data_re = conv1_en;
    assign ecg_data_raddr = ecg_data_addr_add[7:2];

    always @(posedge aclk) begin
        if(ecg_data_we) begin
            ecg_data_in[ecg_data_waddr] <= ecg_data_din;
        end
    end
    always @(posedge aclk) begin
        if(ecg_data_re) begin
            ecg_data_rdata <= ecg_data_in[ecg_data_raddr];
        end
    end

    assign pool_1_we = pe_post_result_valid & (post_processing_stage == 2'd0);
    assign pool_1_din = pe_post_result_out;
    assign pool_1_re = conv2_en;
    assign pool_1_raddr = pool_1_addr_add[10:2];

    always @(posedge aclk) begin
        if(pool_1_we) begin
            pool_1[pool_1_waddr] <= pool_1_din;
        end
    end
    always @(posedge aclk) begin
        if(pool_1_re) begin
            pool_1_rdata <= pool_1[pool_1_raddr];
        end
    end

    assign pool_2_we = pe_post_result_valid & (post_processing_stage == 2'd1);
    assign pool_2_din = pe_post_result_out;
    assign pool_2_re = fc1_en;
    assign pool_2_raddr = pool_2_addr_add[9:2];

    always @(posedge aclk) begin
        if(pool_2_we) begin
            pool_2[pool_2_waddr] <= pool_2_din;
        end
    end
    always @(posedge aclk) begin
        if(pool_2_re) begin
            pool_2_rdata <= pool_2[pool_2_raddr];
        end
    end

    assign fc_middle_we = pe_post_result_valid & (post_processing_stage == 2'd2);
    assign fc_middle_din = pe_post_result_out;
    assign fc_middle_re = fc2_en;
    assign fc_middle_raddr = fc_middle_addr_add[6:2];

    always @(posedge aclk) begin
        if(fc_middle_we) begin
            fc_middle[fc_middle_waddr] <= fc_middle_din;
        end
    end
    always @(posedge aclk) begin
        if(fc_middle_re) begin
            fc_middle_rdata <= fc_middle[fc_middle_raddr];
        end
    end

    ECG_Result_Collector u_ECG_Result_Collector (
        .aclk(aclk),
        .aresetn(aresetn),
        .fc2_out_valid(pe_post_result_valid & (post_processing_stage == 2'd3)),
        .fc2_out_word(pe_post_result_out),
        .result_0(result_0),
        .result_1(result_1),
        .result_2(result_2),
        .result_3(result_3),
        .result_4(result_4),
        .infer_result(infer_result),
        .infer_done(infer_done)
    );
//-------------------------------{ram rom access}end------------------------//

    function [7:0] select_byte;
        input [31:0] word;
        input [1:0] sel;
        begin
            case(sel)
                2'b00: select_byte = word[7:0];
                2'b01: select_byte = word[15:8];
                2'b10: select_byte = word[23:16];
                2'b11: select_byte = word[31:24];
                default: select_byte = 8'd0;
            endcase
        end
    endfunction
    

endmodule
