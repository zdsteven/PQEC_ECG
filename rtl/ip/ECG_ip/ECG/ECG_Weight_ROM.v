module ECG_Weight_ROM (
    input aclk,
    input aresetn,

    input [3:0] current_stage_reg,

    input conv1_en,
    input [2:0] conv1_weight_addr,

    input conv2_en,
    input [7:0] conv2_weight_addr,

    input fc1_en,
    input [12:0] fc1_weight_addr,

    input fc2_en,
    input [6:0] fc2_weight_addr,

    output reg [31:0] weight_bank_0,
    output reg [31:0] weight_bank_1,
    output reg [31:0] weight_bank_2,
    output reg [31:0] weight_bank_3,
    output reg [31:0] weight_bank_4
);

    //weight
    wire [31:0] conv1_weight_0 [0:6];
    wire [31:0] conv1_weight_1 [0:6];
    wire [31:0] conv1_weight_2 [0:6];
    wire [31:0] conv1_weight_3 [0:6];
    wire [31:0] conv1_weight_4 [0:6];
    reg [31:0] conv2_weight_0 [0:139];
    reg [31:0] conv2_weight_1 [0:139];
    reg [31:0] conv2_weight_2 [0:139];
    reg [31:0] conv2_weight_3 [0:139];
    reg [31:0] conv2_weight_4 [0:139];
    reg [31:0] fc1_weight_0 [0:4499];
    reg [31:0] fc1_weight_1 [0:4499];
    reg [31:0] fc1_weight_2 [0:4499];
    reg [31:0] fc1_weight_3 [0:4499];
    reg [31:0] fc1_weight_4 [0:4499];
    reg [39:0] fc2_weight [0:99];

    reg [31:0] conv1_weight_pe_in [0:4];
    reg [31:0] conv2_weight_pe_in [0:4];
    reg [31:0] fc1_weight_pe_in [0:4];
    reg [31:0] fc2_weight_pe_in [0:4];

    always @(posedge aclk) begin
        if(!aresetn) begin
            conv1_weight_pe_in[0] <= 32'd0;
            conv1_weight_pe_in[1] <= 32'd0;
            conv1_weight_pe_in[2] <= 32'd0;
            conv1_weight_pe_in[3] <= 32'd0;
            conv1_weight_pe_in[4] <= 32'd0;
        end
        else if (conv1_en) begin
            conv1_weight_pe_in[0] <= conv1_weight_0[conv1_weight_addr];
            conv1_weight_pe_in[1] <= conv1_weight_1[conv1_weight_addr];
            conv1_weight_pe_in[2] <= conv1_weight_2[conv1_weight_addr];
            conv1_weight_pe_in[3] <= conv1_weight_3[conv1_weight_addr];
            conv1_weight_pe_in[4] <= conv1_weight_4[conv1_weight_addr];
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            conv2_weight_pe_in[0] <= 32'd0;
            conv2_weight_pe_in[1] <= 32'd0;
            conv2_weight_pe_in[2] <= 32'd0;
            conv2_weight_pe_in[3] <= 32'd0;
            conv2_weight_pe_in[4] <= 32'd0;
        end
        else if (conv2_en) begin
            conv2_weight_pe_in[0] <= conv2_weight_0[conv2_weight_addr];
            conv2_weight_pe_in[1] <= conv2_weight_1[conv2_weight_addr];
            conv2_weight_pe_in[2] <= conv2_weight_2[conv2_weight_addr];
            conv2_weight_pe_in[3] <= conv2_weight_3[conv2_weight_addr];
            conv2_weight_pe_in[4] <= conv2_weight_4[conv2_weight_addr];
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            fc1_weight_pe_in[0] <= 32'd0;
            fc1_weight_pe_in[1] <= 32'd0;
            fc1_weight_pe_in[2] <= 32'd0;
            fc1_weight_pe_in[3] <= 32'd0;
            fc1_weight_pe_in[4] <= 32'd0;
        end
        else if (fc1_en) begin
            fc1_weight_pe_in[0] <= fc1_weight_0[fc1_weight_addr];
            fc1_weight_pe_in[1] <= fc1_weight_1[fc1_weight_addr];
            fc1_weight_pe_in[2] <= fc1_weight_2[fc1_weight_addr];
            fc1_weight_pe_in[3] <= fc1_weight_3[fc1_weight_addr];
            fc1_weight_pe_in[4] <= fc1_weight_4[fc1_weight_addr];
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            fc2_weight_pe_in[0] <= 32'd0;
            fc2_weight_pe_in[1] <= 32'd0;
            fc2_weight_pe_in[2] <= 32'd0;
            fc2_weight_pe_in[3] <= 32'd0;
            fc2_weight_pe_in[4] <= 32'd0;
        end
        else if (fc2_en) begin
            fc2_weight_pe_in[0] <= {24'd0, fc2_weight[fc2_weight_addr][7:0]};
            fc2_weight_pe_in[1] <= {24'd0, fc2_weight[fc2_weight_addr][15:8]};
            fc2_weight_pe_in[2] <= {24'd0, fc2_weight[fc2_weight_addr][23:16]};
            fc2_weight_pe_in[3] <= {24'd0, fc2_weight[fc2_weight_addr][31:24]};
            fc2_weight_pe_in[4] <= {24'd0, fc2_weight[fc2_weight_addr][39:32]};
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            weight_bank_0 <= 32'd0;
            weight_bank_1 <= 32'd0;
            weight_bank_2 <= 32'd0;
            weight_bank_3 <= 32'd0;
            weight_bank_4 <= 32'd0;
        end
        else begin
            if(current_stage_reg[0]) begin
                weight_bank_0 <= conv1_weight_pe_in[0];
                weight_bank_1 <= conv1_weight_pe_in[1];
                weight_bank_2 <= conv1_weight_pe_in[2];
                weight_bank_3 <= conv1_weight_pe_in[3];
                weight_bank_4 <= conv1_weight_pe_in[4];
            end
            else if(current_stage_reg[1]) begin
                weight_bank_0 <= conv2_weight_pe_in[0];
                weight_bank_1 <= conv2_weight_pe_in[1];
                weight_bank_2 <= conv2_weight_pe_in[2];
                weight_bank_3 <= conv2_weight_pe_in[3];
                weight_bank_4 <= conv2_weight_pe_in[4];
            end
            else if(current_stage_reg[2]) begin
                weight_bank_0 <= fc1_weight_pe_in[0];
                weight_bank_1 <= fc1_weight_pe_in[1];
                weight_bank_2 <= fc1_weight_pe_in[2];
                weight_bank_3 <= fc1_weight_pe_in[3];
                weight_bank_4 <= fc1_weight_pe_in[4];
            end
            else if(current_stage_reg[3]) begin
                weight_bank_0 <= fc2_weight_pe_in[0];
                weight_bank_1 <= fc2_weight_pe_in[1];
                weight_bank_2 <= fc2_weight_pe_in[2];
                weight_bank_3 <= fc2_weight_pe_in[3];
                weight_bank_4 <= fc2_weight_pe_in[4];
            end
        end
    end

    /*initialize conv1 weight*/
    assign conv1_weight_0[0] = 32'h4D09261A;
    assign conv1_weight_0[1] = 32'h4BF80D29;
    assign conv1_weight_0[2] = 32'h11FC1DFD;
    assign conv1_weight_0[3] = 32'hF52AF20F;
    assign conv1_weight_0[4] = 32'hC91AF8EB;
    assign conv1_weight_0[5] = 32'hB61D0819;
    assign conv1_weight_0[6] = 32'hBC1AD1F5;

    assign conv1_weight_1[0] = 32'hFF2C08CE;
    assign conv1_weight_1[1] = 32'hEB21F8C9;
    assign conv1_weight_1[2] = 32'h0CD80AD8;
    assign conv1_weight_1[3] = 32'h10C7DAEB;
    assign conv1_weight_1[4] = 32'hFAB3E0FC;
    assign conv1_weight_1[5] = 32'h10C00012;
    assign conv1_weight_1[6] = 32'hE7BBF234;

    assign conv1_weight_2[0] = 32'h05F5DFE0;
    assign conv1_weight_2[1] = 32'h2BE3F6E7;
    assign conv1_weight_2[2] = 32'h29200BDA;
    assign conv1_weight_2[3] = 32'h3016260C;
    assign conv1_weight_2[4] = 32'h1518030D;
    assign conv1_weight_2[5] = 32'hBB0333F6;
    assign conv1_weight_2[6] = 32'hAC2B11FD;

    assign conv1_weight_3[0] = 32'hD005F443;
    assign conv1_weight_3[1] = 32'hD00DF11D;
    assign conv1_weight_3[2] = 32'hD538DF20;
    assign conv1_weight_3[3] = 32'hD615EFE7;
    assign conv1_weight_3[4] = 32'hDE4116FE;
    assign conv1_weight_3[5] = 32'h2023F4E1;
    assign conv1_weight_3[6] = 32'h230AF5CF;

    assign conv1_weight_4[0] = 32'h9DD71E86;
    assign conv1_weight_4[1] = 32'h96D7FE96;
    assign conv1_weight_4[2] = 32'hA909FCAA;
    assign conv1_weight_4[3] = 32'hD91F1C07;
    assign conv1_weight_4[4] = 32'h051B0603;
    assign conv1_weight_4[5] = 32'h282DF85E;
    assign conv1_weight_4[6] = 32'h7421D67F;

// synopsys translate_off
`ifndef SYNTHESIS
    initial begin
        $readmemh("conv2_weight_0.mem", conv2_weight_0);
        $readmemh("conv2_weight_1.mem", conv2_weight_1);
        $readmemh("conv2_weight_2.mem", conv2_weight_2);
        $readmemh("conv2_weight_3.mem", conv2_weight_3);
        $readmemh("conv2_weight_4.mem", conv2_weight_4);
        $readmemh("fc1_weight_0.mem", fc1_weight_0);
        $readmemh("fc1_weight_1.mem", fc1_weight_1);
        $readmemh("fc1_weight_2.mem", fc1_weight_2);
        $readmemh("fc1_weight_3.mem", fc1_weight_3);
        $readmemh("fc1_weight_4.mem", fc1_weight_4);
        $readmemh("fc2_weight.mem", fc2_weight);
    end
`endif
// synopsys translate_on

endmodule
