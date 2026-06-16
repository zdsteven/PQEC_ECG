module NTT_INTT(
    input aclk,
    input aresetn,

    input load_en,
    input [23:0] load_data,

    input start,
    input [6:0] data_address,
    input mode,// 1 for NTT, 0 for INTT

    input  read_en,
    output wire [31:0] read_data,

    output reg done
);
    localparam signed [12:0] Q = 13'sd3329;
    
    localparam IDLE = 3'b001;
    localparam STAGE = 3'b010;
    localparam STAGE_WAIT = 3'b100;

//-------------------------------{ram rom}begin-----------------------------//
    (* ram_style = "block" *) reg [23:0] ntt_memA_0 [0:63];
    (* ram_style = "block" *) reg [23:0] ntt_memA_1 [0:63];
    (* ram_style = "block" *) reg [23:0] ntt_memB_0 [0:63];
    (* ram_style = "block" *) reg [23:0] ntt_memB_1 [0:63];

    (* rom_style = "distributed" *) reg [11:0] twiddle_rom [0:127];

    initial begin
        twiddle_rom[0] = 12'd1;
        twiddle_rom[1] = 12'd1729;
        twiddle_rom[2] = 12'd2580;
        twiddle_rom[3] = 12'd3289;
        twiddle_rom[4] = 12'd2642;
        twiddle_rom[5] = 12'd630;
        twiddle_rom[6] = 12'd1897;
        twiddle_rom[7] = 12'd848;
        twiddle_rom[8] = 12'd1062;
        twiddle_rom[9] = 12'd1919;
        twiddle_rom[10] = 12'd193;
        twiddle_rom[11] = 12'd797;
        twiddle_rom[12] = 12'd2786;
        twiddle_rom[13] = 12'd3260;
        twiddle_rom[14] = 12'd569;
        twiddle_rom[15] = 12'd1746;
        twiddle_rom[16] = 12'd296;
        twiddle_rom[17] = 12'd2447;
        twiddle_rom[18] = 12'd1339;
        twiddle_rom[19] = 12'd1476;
        twiddle_rom[20] = 12'd3046;
        twiddle_rom[21] = 12'd56;
        twiddle_rom[22] = 12'd2240;
        twiddle_rom[23] = 12'd1333;
        twiddle_rom[24] = 12'd1426;
        twiddle_rom[25] = 12'd2094;
        twiddle_rom[26] = 12'd535;
        twiddle_rom[27] = 12'd2882;
        twiddle_rom[28] = 12'd2393;
        twiddle_rom[29] = 12'd2879;
        twiddle_rom[30] = 12'd1974;
        twiddle_rom[31] = 12'd821;
        twiddle_rom[32] = 12'd289;
        twiddle_rom[33] = 12'd331;
        twiddle_rom[34] = 12'd3253;
        twiddle_rom[35] = 12'd1756;
        twiddle_rom[36] = 12'd1197;
        twiddle_rom[37] = 12'd2304;
        twiddle_rom[38] = 12'd2277;
        twiddle_rom[39] = 12'd2055;
        twiddle_rom[40] = 12'd650;
        twiddle_rom[41] = 12'd1977;
        twiddle_rom[42] = 12'd2513;
        twiddle_rom[43] = 12'd632;
        twiddle_rom[44] = 12'd2865;
        twiddle_rom[45] = 12'd33;
        twiddle_rom[46] = 12'd1320;
        twiddle_rom[47] = 12'd1915;
        twiddle_rom[48] = 12'd2319;
        twiddle_rom[49] = 12'd1435;
        twiddle_rom[50] = 12'd807;
        twiddle_rom[51] = 12'd452;
        twiddle_rom[52] = 12'd1438;
        twiddle_rom[53] = 12'd2868;
        twiddle_rom[54] = 12'd1534;
        twiddle_rom[55] = 12'd2402;
        twiddle_rom[56] = 12'd2647;
        twiddle_rom[57] = 12'd2617;
        twiddle_rom[58] = 12'd1481;
        twiddle_rom[59] = 12'd648;
        twiddle_rom[60] = 12'd2474;
        twiddle_rom[61] = 12'd3110;
        twiddle_rom[62] = 12'd1227;
        twiddle_rom[63] = 12'd910;
        twiddle_rom[64] = 12'd17;
        twiddle_rom[65] = 12'd2761;
        twiddle_rom[66] = 12'd583;
        twiddle_rom[67] = 12'd2649;
        twiddle_rom[68] = 12'd1637;
        twiddle_rom[69] = 12'd723;
        twiddle_rom[70] = 12'd2288;
        twiddle_rom[71] = 12'd1100;
        twiddle_rom[72] = 12'd1409;
        twiddle_rom[73] = 12'd2662;
        twiddle_rom[74] = 12'd3281;
        twiddle_rom[75] = 12'd233;
        twiddle_rom[76] = 12'd756;
        twiddle_rom[77] = 12'd2156;
        twiddle_rom[78] = 12'd3015;
        twiddle_rom[79] = 12'd3050;
        twiddle_rom[80] = 12'd1703;
        twiddle_rom[81] = 12'd1651;
        twiddle_rom[82] = 12'd2789;
        twiddle_rom[83] = 12'd1789;
        twiddle_rom[84] = 12'd1847;
        twiddle_rom[85] = 12'd952;
        twiddle_rom[86] = 12'd1461;
        twiddle_rom[87] = 12'd2687;
        twiddle_rom[88] = 12'd939;
        twiddle_rom[89] = 12'd2308;
        twiddle_rom[90] = 12'd2437;
        twiddle_rom[91] = 12'd2388;
        twiddle_rom[92] = 12'd733;
        twiddle_rom[93] = 12'd2337;
        twiddle_rom[94] = 12'd268;
        twiddle_rom[95] = 12'd641;
        twiddle_rom[96] = 12'd1584;
        twiddle_rom[97] = 12'd2298;
        twiddle_rom[98] = 12'd2037;
        twiddle_rom[99] = 12'd3220;
        twiddle_rom[100] = 12'd375;
        twiddle_rom[101] = 12'd2549;
        twiddle_rom[102] = 12'd2090;
        twiddle_rom[103] = 12'd1645;
        twiddle_rom[104] = 12'd1063;
        twiddle_rom[105] = 12'd319;
        twiddle_rom[106] = 12'd2773;
        twiddle_rom[107] = 12'd757;
        twiddle_rom[108] = 12'd2099;
        twiddle_rom[109] = 12'd561;
        twiddle_rom[110] = 12'd2466;
        twiddle_rom[111] = 12'd2594;
        twiddle_rom[112] = 12'd2804;
        twiddle_rom[113] = 12'd1092;
        twiddle_rom[114] = 12'd403;
        twiddle_rom[115] = 12'd1026;
        twiddle_rom[116] = 12'd1143;
        twiddle_rom[117] = 12'd2150;
        twiddle_rom[118] = 12'd2775;
        twiddle_rom[119] = 12'd886;
        twiddle_rom[120] = 12'd1722;
        twiddle_rom[121] = 12'd1212;
        twiddle_rom[122] = 12'd1874;
        twiddle_rom[123] = 12'd1029;
        twiddle_rom[124] = 12'd2110;
        twiddle_rom[125] = 12'd2935;
        twiddle_rom[126] = 12'd885;
        twiddle_rom[127] = 12'd2154;
    end

//--------------------------------{ram rom}end------------------------------//

//-------------------------------{NTT core}begin----------------------------//
    reg [2:0] state;
    reg src_bank;
    reg dst_bank;
    reg [2:0] stage_count;
    reg src_address_valid;
    reg mode_reg;

//-------------------------------{NTT core}end------------------------------//

//----------------------------------{BPU}begin------------------------------//
    reg bpu_valid_in;
    wire bpu_valid_out;

    reg  [11:0] bpu_0_a;
    reg  [11:0] bpu_0_b;
    wire [11:0] bpu_0_out_a;
    wire [11:0] bpu_0_out_b;
    reg  [11:0] bpu_1_a;
    reg  [11:0] bpu_1_b;
    wire [11:0] bpu_1_out_a;
    wire [11:0] bpu_1_out_b;
    reg  [11:0] bpu_2_a;
    reg  [11:0] bpu_2_b;
    wire [11:0] bpu_2_out_a;
    wire [11:0] bpu_2_out_b;
    reg  [11:0] bpu_3_a;
    reg  [11:0] bpu_3_b;
    wire [11:0] bpu_3_out_a;
    wire [11:0] bpu_3_out_b;

    reg  [11:0] bpu_zeta_01;
    reg  [11:0] bpu_zeta_23;
    reg  [6:0] bpu_zeta_addr_01;
    reg  [6:0] bpu_zeta_addr_23;
//----------------------------------{BPU}end--------------------------------//

//-------------------------------{ram access}begin--------------------------//
    wire memA_en_0a;
    wire memA_we_0a;
    wire [5:0] memA_addr_0a;
    wire [23:0] memA_din_0a;
    reg  [23:0] memA_rdata_0a;

    wire memA_en_0b;
    wire memA_we_0b;
    wire [5:0] memA_addr_0b;
    wire [23:0] memA_din_0b;
    reg  [23:0] memA_rdata_0b;

    wire memA_en_1a;
    wire memA_we_1a;
    wire [5:0] memA_addr_1a;
    wire [23:0] memA_din_1a;
    reg  [23:0] memA_rdata_1a;

    wire memA_en_1b;
    wire memA_we_1b;
    wire [5:0] memA_addr_1b;
    wire [23:0] memA_din_1b;
    reg  [23:0] memA_rdata_1b;

    wire memB_en_0a;
    wire memB_we_0a;
    wire [5:0] memB_addr_0a;
    wire [23:0] memB_din_0a;
    reg  [23:0] memB_rdata_0a;

    wire memB_en_0b;
    wire memB_we_0b;
    wire [5:0] memB_addr_0b;
    wire [23:0] memB_din_0b;
    reg  [23:0] memB_rdata_0b;

    wire memB_en_1a;
    wire memB_we_1a;
    wire [5:0] memB_addr_1a;
    wire [23:0] memB_din_1a;
    reg  [23:0] memB_rdata_1a;

    wire memB_en_1b;
    wire memB_we_1b;
    wire [5:0] memB_addr_1b;
    wire [23:0] memB_din_1b;
    reg  [23:0] memB_rdata_1b;

    reg  [6:0] data_address_reg;
    wire [23:0] load_data_modq;
    wire [23:0] read_data_modq;
//-------------------------------{ram access}end----------------------------//


//--------------------------------------------------------------------------------------------------------//
//--------------------------------------------------------------------------------------------------------//
//--------------------------------------------------------------------------------------------------------//


//-------------------------------{address}begin-----------------------------//
    reg [4:0] src_address;
    reg [4:0] dst_address;

    always @(posedge aclk) begin
        if(!aresetn) begin
            src_address <= 5'b0;
        end else if (state == STAGE) begin
            src_address <= src_address + 1'b1;
        end
    end

    always @(posedge aclk) begin
        if(!aresetn) begin
            dst_address <= 5'b0;
    end else if (bpu_valid_out) begin
            dst_address <= dst_address + 1'b1;
        end
    end
//-------------------------------{address}end-------------------------------//

//-------------------------------{NTT core}begin----------------------------//
    always @(posedge aclk) begin
        if(!aresetn) begin
            state <= IDLE;
            src_bank <= 1'b0;
            dst_bank <= 1'b1;
            src_address_valid <= 1'b0;
            stage_count <= 3'b0;
            mode_reg <= 1'b1;
            done <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        state <= STAGE;
                        src_bank <= 1'b0;
                        dst_bank <= 1'b1;
                        src_address_valid <= 1'b1;
                        mode_reg <= mode;
                    end
                end
                STAGE: begin
                    if (src_address == 5'd31) begin
                        state <= STAGE_WAIT;
                        src_address_valid <= 1'b0;
                    end
                end
                STAGE_WAIT: begin
                    if (bpu_valid_out && (dst_address == 5'd31)) begin
                        if (stage_count == 3'd6) begin
                            state <= IDLE;
                            done <= 1'b1;
                            stage_count <= 3'b0;
                        end else begin
                            state <= STAGE;
                            src_bank <= ~src_bank;
                            dst_bank <= ~dst_bank;
                            src_address_valid <= 1'b1;
                            stage_count <= stage_count + 1'b1;
                        end
                    end
                end
            endcase
        end
    end
//-------------------------------{NTT core}end------------------------------//

//-------------------------------{ram access}begin--------------------------//
    wire write_valid_stage_A = !dst_bank & bpu_valid_out;
    wire write_valid_stage_B = dst_bank & bpu_valid_out;
    wire read_valid_stage_A = !src_bank & src_address_valid;
    wire read_valid_stage_B = src_bank & src_address_valid;

    assign load_data_modq = {signed_to_modq($signed(load_data[23:12])), signed_to_modq($signed(load_data[11:0]))};
    
    wire [5:0] ntt_src_addr_a = {1'b0, src_address};
    wire [5:0] ntt_src_addr_b = {1'b1, src_address};
    wire [5:0] ntt_dst_addr_a = {dst_address, 1'b0};
    wire [5:0] ntt_dst_addr_b = {dst_address, 1'b1};
    wire [5:0] intt_src_addr_a = {src_address, 1'b0};
    wire [5:0] intt_src_addr_b = {src_address, 1'b1};
    wire [5:0] intt_dst_addr_a = {1'b0, dst_address};
    wire [5:0] intt_dst_addr_b = {1'b1, dst_address};

    wire [5:0] src_addr_a = mode_reg ? ntt_src_addr_a : intt_src_addr_a;
    wire [5:0] src_addr_b = mode_reg ? ntt_src_addr_b : intt_src_addr_b;
    wire [5:0] dst_addr_a = mode_reg ? ntt_dst_addr_a : intt_dst_addr_a;
    wire [5:0] dst_addr_b = mode_reg ? ntt_dst_addr_b : intt_dst_addr_b;

    wire [5:0] memA_addr_a = src_bank ? dst_addr_a : src_addr_a;
    wire [5:0] memA_addr_b = src_bank ? dst_addr_b : src_addr_b;
    wire [5:0] memB_addr_a = src_bank ? src_addr_a : dst_addr_a;
    wire [5:0] memB_addr_b = src_bank ? src_addr_b : dst_addr_b;

    wire [23:0] mem_din_0a = {bpu_1_out_a, bpu_0_out_a};
    wire [23:0] mem_din_0b = mode_reg ? {bpu_1_out_b, bpu_0_out_b} : {bpu_3_out_a, bpu_2_out_a};
    wire [23:0] mem_din_1a = mode_reg ? {bpu_3_out_a, bpu_2_out_a} : {bpu_1_out_b, bpu_0_out_b};
    wire [23:0] mem_din_1b = {bpu_3_out_b, bpu_2_out_b};

    assign memA_en_0a = memA_we_0a | read_valid_stage_A;
    assign memA_we_0a = write_valid_stage_A | (load_en & !data_address[6]);
    assign memA_addr_0a  =  load_en ? data_address[5:0] : memA_addr_a;
    assign memA_din_0a   =  load_en ? load_data_modq : mem_din_0a;

    assign memA_en_0b = memA_we_0b | read_valid_stage_A;
    assign memA_we_0b = write_valid_stage_A;
    assign memA_addr_0b = memA_addr_b;
    assign memA_din_0b = mem_din_0b;

    assign memA_en_1a = memA_we_1a | read_valid_stage_A;
    assign memA_we_1a = write_valid_stage_A | (load_en & data_address[6]);
    assign memA_addr_1a  =  load_en ? data_address[5:0] : memA_addr_a;
    assign memA_din_1a   =  load_en ? load_data_modq : mem_din_1a;

    assign memA_en_1b = memA_we_1b | read_valid_stage_A;
    assign memA_we_1b = write_valid_stage_A;
    assign memA_addr_1b = memA_addr_b;
    assign memA_din_1b = mem_din_1b;

    assign memB_en_0a = memB_we_0a | read_valid_stage_B | (read_en & !data_address[6]);
    assign memB_we_0a = write_valid_stage_B;
    assign memB_addr_0a  =  read_en ? data_address[5:0] : memB_addr_a;
    assign memB_din_0a = mem_din_0a;

    assign memB_en_0b = memB_we_0b | read_valid_stage_B;
    assign memB_we_0b = write_valid_stage_B;
    assign memB_addr_0b  =  memB_addr_b;
    assign memB_din_0b = mem_din_0b;

    assign memB_en_1a = memB_we_1a | read_valid_stage_B | (read_en & data_address[6]);
    assign memB_we_1a = write_valid_stage_B;
    assign memB_addr_1a  =  read_en ? data_address[5:0] : memB_addr_a;
    assign memB_din_1a = mem_din_1a;

    assign memB_en_1b = memB_we_1b | read_valid_stage_B;
    assign memB_we_1b = write_valid_stage_B;
    assign memB_addr_1b  =  memB_addr_b;
    assign memB_din_1b = mem_din_1b;

    always @(posedge aclk) begin
        if (memA_en_0a) begin
            memA_rdata_0a <= ntt_memA_0[memA_addr_0a];
            if (memA_we_0a) begin
                ntt_memA_0[memA_addr_0a] <= memA_din_0a;
            end
        end
    end

    always @(posedge aclk) begin
        if (memA_en_0b) begin
            memA_rdata_0b <= ntt_memA_0[memA_addr_0b];
            if (memA_we_0b) begin
                ntt_memA_0[memA_addr_0b] <= memA_din_0b;
            end
        end
    end

    always @(posedge aclk) begin
        if (memA_en_1a) begin
            memA_rdata_1a <= ntt_memA_1[memA_addr_1a];
            if (memA_we_1a) begin
                ntt_memA_1[memA_addr_1a] <= memA_din_1a;
            end
        end
    end

    always @(posedge aclk) begin
        if (memA_en_1b) begin
            memA_rdata_1b <= ntt_memA_1[memA_addr_1b];
            if (memA_we_1b) begin
                ntt_memA_1[memA_addr_1b] <= memA_din_1b;
            end
        end
    end

    always @(posedge aclk) begin
        if (memB_en_0a) begin
            memB_rdata_0a <= ntt_memB_0[memB_addr_0a];
            if (memB_we_0a) begin
                ntt_memB_0[memB_addr_0a] <= memB_din_0a;
            end
        end
    end

    always @(posedge aclk) begin
        if (memB_en_0b) begin
            memB_rdata_0b <= ntt_memB_0[memB_addr_0b];
            if (memB_we_0b) begin
                ntt_memB_0[memB_addr_0b] <= memB_din_0b;
            end
        end
    end

    always @(posedge aclk) begin
        if (memB_en_1a) begin
            memB_rdata_1a <= ntt_memB_1[memB_addr_1a];
            if (memB_we_1a) begin
                ntt_memB_1[memB_addr_1a] <= memB_din_1a;
            end
        end
    end

    always @(posedge aclk) begin
        if (memB_en_1b) begin
            memB_rdata_1b <= ntt_memB_1[memB_addr_1b];
            if (memB_we_1b) begin
                ntt_memB_1[memB_addr_1b] <= memB_din_1b;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            data_address_reg <= 7'b0;
        end else if (read_en) begin
            data_address_reg <= data_address;
        end
    end

    assign read_data_modq = data_address_reg[6] ? memB_rdata_1a : memB_rdata_0a;
    assign read_data = {modq_to_signed(read_data_modq[23:12]), modq_to_signed(read_data_modq[11:0])};
//--------------------------------{ram access}end---------------------------//

//----------------------------------{BPU}begin------------------------------//
    reg [5:0] valid_pending;

    always @(posedge aclk) begin
        if(!aresetn) begin
            bpu_valid_in <= 1'b0;
            valid_pending <= 6'b0;
        end else begin
            bpu_valid_in <= src_address_valid;
            valid_pending <= {valid_pending[4:0], bpu_valid_in};
        end
    end

    assign bpu_valid_out = valid_pending[5];

    always @(posedge aclk) begin
        if (!aresetn) begin
            bpu_0_a <= 12'd0;
            bpu_0_b <= 12'd0;
            bpu_1_a <= 12'd0;
            bpu_1_b <= 12'd0;
            bpu_2_a <= 12'd0;
            bpu_2_b <= 12'd0;
            bpu_3_a <= 12'd0;
            bpu_3_b <= 12'd0;
        end else begin
            bpu_0_a <= src_bank ? memB_rdata_0a[11:0] : memA_rdata_0a[11:0];
            bpu_1_a <= src_bank ? memB_rdata_0a[23:12] : memA_rdata_0a[23:12];
            bpu_2_b <= src_bank ? memB_rdata_1b[11:0] : memA_rdata_1b[11:0];
            bpu_3_b <= src_bank ? memB_rdata_1b[23:12] : memA_rdata_1b[23:12];

            bpu_0_b <= mode_reg ? (src_bank ? memB_rdata_1a[11:0]  : memA_rdata_1a[11:0])
                                : (src_bank ? memB_rdata_0b[11:0]  : memA_rdata_0b[11:0]);
            bpu_1_b <= mode_reg ? (src_bank ? memB_rdata_1a[23:12] : memA_rdata_1a[23:12])
                                : (src_bank ? memB_rdata_0b[23:12] : memA_rdata_0b[23:12]);
            bpu_2_a <= mode_reg ? (src_bank ? memB_rdata_0b[11:0]  : memA_rdata_0b[11:0])
                                : (src_bank ? memB_rdata_1a[11:0]  : memA_rdata_1a[11:0]);
            bpu_3_a <= mode_reg ? (src_bank ? memB_rdata_0b[23:12] : memA_rdata_0b[23:12])
                                : (src_bank ? memB_rdata_1a[23:12] : memA_rdata_1a[23:12]);
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            bpu_zeta_addr_01 <= 7'd0;
            bpu_zeta_addr_23 <= 7'd0;
        end else begin
            bpu_zeta_addr_01 <= mode_reg ? zeta_addr_gen_01(stage_count, src_address)
                                        :  izeta_addr_gen_01(stage_count, src_address);
            bpu_zeta_addr_23 <= mode_reg ? zeta_addr_gen_23(stage_count, src_address)
                                        :  izeta_addr_gen_23(stage_count, src_address);
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            bpu_zeta_01 <= 12'd0;
            bpu_zeta_23 <= 12'd0;
        end else begin
            bpu_zeta_01 <= twiddle_rom[bpu_zeta_addr_01];
            bpu_zeta_23 <= twiddle_rom[bpu_zeta_addr_23];
        end
    end

    BPU u_BPU_0(
        .sys_clk    (aclk           ),
        .sys_resetn (aresetn        ),
        .mode       (mode_reg       ),
        .a          (bpu_0_a        ),
        .b          (bpu_0_b        ),
        .zeta       (bpu_zeta_01    ),
        .out_a      (bpu_0_out_a    ),
        .out_b      (bpu_0_out_b    )
    );

    BPU u_BPU_1(
        .sys_clk    (aclk           ),
        .sys_resetn (aresetn        ),
        .mode       (mode_reg       ),
        .a          (bpu_1_a        ),
        .b          (bpu_1_b        ),
        .zeta       (bpu_zeta_01    ),
        .out_a      (bpu_1_out_a    ),
        .out_b      (bpu_1_out_b    )
    );

    BPU u_BPU_2(
        .sys_clk    (aclk           ),
        .sys_resetn (aresetn        ),
        .mode       (mode_reg       ),
        .a          (bpu_2_a        ),
        .b          (bpu_2_b        ),
        .zeta       (bpu_zeta_23    ),
        .out_a      (bpu_2_out_a    ),
        .out_b      (bpu_2_out_b    )
    );

    BPU u_BPU_3(
        .sys_clk    (aclk           ),
        .sys_resetn (aresetn        ),
        .mode       (mode_reg       ),
        .a          (bpu_3_a        ),
        .b          (bpu_3_b        ),
        .zeta       (bpu_zeta_23    ),
        .out_a      (bpu_3_out_a    ),
        .out_b      (bpu_3_out_b    )
    );
//----------------------------------{BPU}end--------------------------------//

    function [6:0] zeta_addr_gen_01;
        input [2:0] stage;
        input [4:0] addr;
        begin
            case (stage)
                3'd0: zeta_addr_gen_01 = 7'd1;
                3'd1: zeta_addr_gen_01 = {6'd1, addr[0]};
                3'd2: zeta_addr_gen_01 = {5'd1, addr[1:0]};
                3'd3: zeta_addr_gen_01 = {4'd1, addr[2:0]};
                3'd4: zeta_addr_gen_01 = {3'd1, addr[3:0]};
                3'd5: zeta_addr_gen_01 = {2'd1, addr};
                3'd6: zeta_addr_gen_01 = {2'd2, addr};
                default: zeta_addr_gen_01 = 7'd0;
            endcase
        end
    endfunction

    function [6:0] zeta_addr_gen_23;
        input [2:0] stage;
        input [4:0] addr;
        begin
            case (stage)
                3'd0: zeta_addr_gen_23 = 7'd1;
                3'd1: zeta_addr_gen_23 = {6'd1, addr[0]};
                3'd2: zeta_addr_gen_23 = {5'd1, addr[1:0]};
                3'd3: zeta_addr_gen_23 = {4'd1, addr[2:0]};
                3'd4: zeta_addr_gen_23 = {3'd1, addr[3:0]};
                3'd5: zeta_addr_gen_23 = {2'd1, addr};
                3'd6: zeta_addr_gen_23 = {2'd3, addr};
                default: zeta_addr_gen_23 = 7'd0;
            endcase
        end
    endfunction

    function [6:0] izeta_addr_gen_01;
        input [2:0] stage;
        input [4:0] addr;
        begin
            case (stage)
                3'd0: izeta_addr_gen_01 = {2'd3, ~addr};
                3'd1: izeta_addr_gen_01 = {2'd1, ~addr};
                3'd2: izeta_addr_gen_01 = {3'd1, ~addr[3:0]};
                3'd3: izeta_addr_gen_01 = {4'd1, ~addr[2:0]};
                3'd4: izeta_addr_gen_01 = {5'd1, ~addr[1:0]};
                3'd5: izeta_addr_gen_01 = {6'd1, ~addr[0]};
                3'd6: izeta_addr_gen_01 = 7'd1;
                default: izeta_addr_gen_01 = 7'd0;
            endcase
        end
    endfunction

    function [6:0] izeta_addr_gen_23;
        input [2:0] stage;
        input [4:0] addr;
        begin
            case (stage)
                3'd0: izeta_addr_gen_23 = {2'd2, ~addr};
                3'd1: izeta_addr_gen_23 = {2'd1, ~addr};
                3'd2: izeta_addr_gen_23 = {3'd1, ~addr[3:0]};
                3'd3: izeta_addr_gen_23 = {4'd1, ~addr[2:0]};
                3'd4: izeta_addr_gen_23 = {5'd1, ~addr[1:0]};
                3'd5: izeta_addr_gen_23 = {6'd1, ~addr[0]};
                3'd6: izeta_addr_gen_23 = 7'd1;
                default: izeta_addr_gen_23 = 7'd0;
            endcase
        end
    endfunction

    function [11:0] signed_to_modq;
        input signed [11:0] x;
        reg signed [11:0] x_plus_q;
        begin
            x_plus_q = x + Q;
            signed_to_modq = x[11] ? x_plus_q : x;
        end
    endfunction

    function signed [15:0] modq_to_signed;
        input [11:0] x;
        reg [11:0] x_minus_q;
        reg [11:0] x_minus_center_top;
        reg [11:0] centered;
        begin
            x_minus_q = x - Q;
            x_minus_center_top = x - 12'd1665;
            centered = x_minus_center_top[11] ? x : x_minus_q;
            modq_to_signed = {{4{centered[11]}}, centered};
        end
    endfunction



endmodule
