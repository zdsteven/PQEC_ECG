module Basemul_ctrl (
    input            aclk,
    input            aresetn,

    input            basemul_start,
    input            basemul_bank_in_we,
    input   [6:0]    basemul_bank_in_write_addr,
    input   [23:0]   basemul_bank_in_din,
    input   [31:0]   ntt_intt_read_data,

    output reg       basemul_state,
    output reg [6:0] basemul_request_addr,
    output  [23:0]   basemul_result,
    output           basemul_valid_out
);
    reg basemul_valid_in;
    reg [11:0] basemul_zeta;

    (* ram_style = "block" *) reg [23:0] basemul_bank_in [0:127];

    wire basemul_bank_in_en;
    wire [6:0] basemul_bank_in_addr;
    reg [23:0] basemul_bank_in_rdata;

    (* rom_style = "distributed" *) reg [11:0] zeta_rom [0:63];

    initial begin
        zeta_rom[0]  = 12'd17;
        zeta_rom[1]  = 12'd2761;
        zeta_rom[2]  = 12'd583;
        zeta_rom[3]  = 12'd2649;
        zeta_rom[4]  = 12'd1637;
        zeta_rom[5]  = 12'd723;
        zeta_rom[6]  = 12'd2288;
        zeta_rom[7]  = 12'd1100;
        zeta_rom[8]  = 12'd1409;
        zeta_rom[9]  = 12'd2662;
        zeta_rom[10] = 12'd3281;
        zeta_rom[11] = 12'd233;
        zeta_rom[12] = 12'd756;
        zeta_rom[13] = 12'd2156;
        zeta_rom[14] = 12'd3015;
        zeta_rom[15] = 12'd3050;
        zeta_rom[16] = 12'd1703;
        zeta_rom[17] = 12'd1651;
        zeta_rom[18] = 12'd2789;
        zeta_rom[19] = 12'd1789;
        zeta_rom[20] = 12'd1847;
        zeta_rom[21] = 12'd952;
        zeta_rom[22] = 12'd1461;
        zeta_rom[23] = 12'd2687;
        zeta_rom[24] = 12'd939;
        zeta_rom[25] = 12'd2308;
        zeta_rom[26] = 12'd2437;
        zeta_rom[27] = 12'd2388;
        zeta_rom[28] = 12'd733;
        zeta_rom[29] = 12'd2337;
        zeta_rom[30] = 12'd268;
        zeta_rom[31] = 12'd641;
        zeta_rom[32] = 12'd1584;
        zeta_rom[33] = 12'd2298;
        zeta_rom[34] = 12'd2037;
        zeta_rom[35] = 12'd3220;
        zeta_rom[36] = 12'd375;
        zeta_rom[37] = 12'd2549;
        zeta_rom[38] = 12'd2090;
        zeta_rom[39] = 12'd1645;
        zeta_rom[40] = 12'd1063;
        zeta_rom[41] = 12'd319;
        zeta_rom[42] = 12'd2773;
        zeta_rom[43] = 12'd757;
        zeta_rom[44] = 12'd2099;
        zeta_rom[45] = 12'd561;
        zeta_rom[46] = 12'd2466;
        zeta_rom[47] = 12'd2594;
        zeta_rom[48] = 12'd2804;
        zeta_rom[49] = 12'd1092;
        zeta_rom[50] = 12'd403;
        zeta_rom[51] = 12'd1026;
        zeta_rom[52] = 12'd1143;
        zeta_rom[53] = 12'd2150;
        zeta_rom[54] = 12'd2775;
        zeta_rom[55] = 12'd886;
        zeta_rom[56] = 12'd1722;
        zeta_rom[57] = 12'd1212;
        zeta_rom[58] = 12'd1874;
        zeta_rom[59] = 12'd1029;
        zeta_rom[60] = 12'd2110;
        zeta_rom[61] = 12'd2935;
        zeta_rom[62] = 12'd885;
        zeta_rom[63] = 12'd2154;
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            basemul_state <= 1'b0;
            basemul_request_addr <= 7'd0;
        end
        else begin
            case (basemul_state)
                1'b0: begin
                    if (basemul_start) begin
                        basemul_state <= 1'b1;
                        basemul_request_addr <= 7'd0;
                    end
                end
                1'b1: begin
                    basemul_request_addr <= basemul_request_addr + 1'b1;
                    if (basemul_request_addr == 7'd127) begin
                        basemul_state <= 1'b0;
                    end
                end
            endcase
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            basemul_valid_in <= 1'b0;
        end
        else begin
            basemul_valid_in <= basemul_state;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            basemul_zeta <= 12'd0;
        end
        else if (basemul_state) begin
            basemul_zeta <= basemul_request_addr[0] ?
                            12'd3329 - zeta_rom[basemul_request_addr[6:1]] :
                            zeta_rom[basemul_request_addr[6:1]];
        end
    end

    Basemul u_Basemul (
        .aclk      (aclk                                                 ),
        .aresetn   (aresetn                                              ),
        .valid_in  (basemul_valid_in                                     ),
        .a         ({ntt_intt_read_data[27:16], ntt_intt_read_data[11:0]}),
        .b         (basemul_bank_in_rdata                                ),
        .zeta      (basemul_zeta                                         ),
        .result    (basemul_result                                       ),
        .valid_out (basemul_valid_out                                    )
    );

    assign basemul_bank_in_en = basemul_state | basemul_bank_in_we;
    assign basemul_bank_in_addr = basemul_state ? basemul_request_addr : basemul_bank_in_write_addr;

    always @(posedge aclk) begin
        if (basemul_bank_in_en) begin
            basemul_bank_in_rdata <= basemul_bank_in[basemul_bank_in_addr];
            if (basemul_bank_in_we) begin
                basemul_bank_in[basemul_bank_in_addr] <= basemul_bank_in_din;
            end
        end
    end

endmodule
