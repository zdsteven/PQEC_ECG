module axi_fft_top #(
    parameter FFT_POINTS = 256,
    parameter FFT_STAGES = 8
) (
    input            s_awvalid,
    output           s_awready,
    input   [31:0]   s_awaddr,
    input   [4:0]    s_awid,
    input   [7:0]    s_awlen,
    input   [2:0]    s_awsize,
    input   [1:0]    s_awburst,
    input   [0:0]    s_awlock,
    input   [3:0]    s_awcache,
    input   [2:0]    s_awprot,
    input            s_wvalid,
    output           s_wready,
    input   [31:0]   s_wdata,
    input   [3:0]    s_wstrb,
    input            s_wlast,
    output           s_bvalid,
    input            s_bready,
    output  [4:0]    s_bid,
    output  [1:0]    s_bresp,
    input            s_arvalid,
    output           s_arready,
    input   [31:0]   s_araddr,
    input   [4:0]    s_arid,
    input   [7:0]    s_arlen,
    input   [2:0]    s_arsize,
    input   [1:0]    s_arburst,
    input   [0:0]    s_arlock,
    input   [3:0]    s_arcache,
    input   [2:0]    s_arprot,
    output           s_rvalid,
    input            s_rready,
    output  [31:0]   s_rdata,
    output  [4:0]    s_rid,
    output  [1:0]    s_rresp,
    output           s_rlast,
    output reg       fft_finish,
    input            aclk,
    input            aresetn
);

localparam CTRL_ADDR       = 16'h0000;
localparam STATUS_ADDR     = 16'h0004;
localparam POINTS_ADDR     = 16'h0008;
localparam SCALE_ADDR      = 16'h000c;
localparam DEBUG_ADDR      = 16'h0010;
localparam DATA_BASE_ADDR  = 16'h0100;
localparam DATA_LAST_ADDR  = DATA_BASE_ADDR + FFT_POINTS * 4 - 4;

localparam ST_IDLE    = 3'd0;
localparam ST_READ    = 3'd1;
localparam ST_MUL     = 3'd2;
localparam ST_PACK    = 3'd3;
localparam ST_WRITE   = 3'd4;

//-------------------------------{axi ctrl}begin----------------------------//
reg         busy, write, R_or_W;
reg         s_wready_r;
reg [4 :0]  buf_id;
reg [31:0]  buf_addr;
reg [7 :0]  buf_len;
reg [2 :0]  buf_size;
reg [1 :0]  buf_burst;
reg         buf_lock;
reg [3 :0]  buf_cache;
reg [2 :0]  buf_prot;

reg [31:0]  s_rdata_r;
reg         s_rvalid_r, s_rlast_r;
reg         s_bvalid_r;

reg         read_pending;
reg         read_pending_is_sample;
reg [31:0]  reg_read_data_pending;

wire ar_enter = s_arvalid & s_arready;
wire r_retire = s_rvalid_r & s_rready & s_rlast_r;
wire aw_enter = s_awvalid & s_awready;
wire w_enter  = s_wvalid & s_wready_r & s_wlast;
wire b_retire = s_bvalid_r & s_bready;
//--------------------------------{axi ctrl}end-----------------------------//

//-------------------------------{fft core}begin----------------------------//
reg         done;
reg [2:0]   fft_state;
reg [2:0]   stage_idx;
reg [7:0]   block_base;
reg [7:0]   j_idx;
reg         src_bank;
reg         dst_bank;

reg [7:0]   addr_a_r;
reg [7:0]   addr_b_r;
reg [31:0]  a_data_r;
reg [31:0]  out0_packed_r;
reg [31:0]  out1_packed_r;
reg signed [15:0] tw_re_r, tw_im_r;
reg signed [31:0] bw_re_r, bw_im_r;
//--------------------------------{fft core}end-----------------------------//

//-------------------------------{ram rom}begin-----------------------------//
(* ram_style = "block" *) reg [31:0] fft_mem0 [0:FFT_POINTS-1];
(* ram_style = "block" *) reg [31:0] fft_mem1 [0:FFT_POINTS-1];
(* rom_style = "distributed" *) reg [31:0] twiddle_rom [0:127];

reg [31:0] fft_mem0_rdata_a;
reg [31:0] fft_mem0_rdata_b;
reg [31:0] fft_mem1_rdata_a;
reg [31:0] fft_mem1_rdata_b;
//--------------------------------{ram rom}end------------------------------//

//-------------------------------{address decode}begin----------------------//
wire ar_sample_hit_current = (s_araddr[15:0] >= DATA_BASE_ADDR) && (s_araddr[15:0] <= DATA_LAST_ADDR);
wire aw_sample_hit_current = (s_awaddr[15:0] >= DATA_BASE_ADDR) && (s_awaddr[15:0] <= DATA_LAST_ADDR);
wire ar_sample_allowed     = (fft_state == ST_IDLE) || !ar_sample_hit_current;
wire aw_sample_allowed     = (fft_state == ST_IDLE) || !aw_sample_hit_current;

wire sample_read_launch = ar_enter & ar_sample_hit_current;
wire [7:0] sample_read_launch_index = (s_araddr[15:0] - DATA_BASE_ADDR) >> 2;

wire ctrl_write = w_enter & (buf_addr[15:0] == CTRL_ADDR);
wire sample_write_hit = w_enter & (buf_addr[15:0] >= DATA_BASE_ADDR) & (buf_addr[15:0] <= DATA_LAST_ADDR);
wire [7:0] sample_write_index = (buf_addr[15:0] - DATA_BASE_ADDR) >> 2;

wire [31:0] status_data = {30'd0, done, (fft_state != ST_IDLE)};
wire [31:0] debug_data  = {3'd0, src_bank, dst_bank, stage_idx, block_base, j_idx, 8'd0};
wire [31:0] ar_reg_rdata_d =
    s_araddr[15:0] == CTRL_ADDR    ? 32'd0         :
    s_araddr[15:0] == STATUS_ADDR  ? status_data   :
    s_araddr[15:0] == POINTS_ADDR  ? FFT_POINTS    :
    s_araddr[15:0] == SCALE_ADDR   ? 32'd8         :
    s_araddr[15:0] == DEBUG_ADDR   ? debug_data    :
    32'd0;
//--------------------------------{address decode}end-----------------------//

//-------------------------------{fft datapath}begin------------------------//
wire [7:0] stage_half = 8'd1 << stage_idx;
wire [8:0] stage_span = 9'd2 << stage_idx;
wire [7:0] idx_a      = block_base + j_idx;
wire [7:0] idx_b      = idx_a + stage_half;

wire [6:0]  twiddle_index = calc_twiddle_index(stage_idx, j_idx);
wire [31:0] tw_pair       = twiddle_rom[twiddle_index];
wire [31:0] fft_src_rdata_a = src_bank ? fft_mem1_rdata_a : fft_mem0_rdata_a;
wire [31:0] fft_src_rdata_b = src_bank ? fft_mem1_rdata_b : fft_mem0_rdata_b;

wire signed [15:0] a_re_w = a_data_r[15:0];
wire signed [15:0] a_im_w = a_data_r[31:16];
wire signed [15:0] b_re_w = fft_src_rdata_b[15:0];
wire signed [15:0] b_im_w = fft_src_rdata_b[31:16];

(* use_dsp = "no" *) wire signed [31:0] mul_rr = b_re_w * tw_re_r;
(* use_dsp = "no" *) wire signed [31:0] mul_ii = b_im_w * tw_im_r;
(* use_dsp = "no" *) wire signed [31:0] mul_ri = b_re_w * tw_im_r;
(* use_dsp = "no" *) wire signed [31:0] mul_ir = b_im_w * tw_re_r;

wire signed [31:0] bw_re_calc = (mul_rr >>> 15) - (mul_ii >>> 15);
wire signed [31:0] bw_im_calc = (mul_ri >>> 15) + (mul_ir >>> 15);
wire signed [31:0] out0_re_calc = ($signed(a_re_w) + bw_re_r) >>> 1;
wire signed [31:0] out0_im_calc = ($signed(a_im_w) + bw_im_r) >>> 1;
wire signed [31:0] out1_re_calc = ($signed(a_re_w) - bw_re_r) >>> 1;
wire signed [31:0] out1_im_calc = ($signed(a_im_w) - bw_im_r) >>> 1;
//--------------------------------{fft datapath}end-------------------------//

//-------------------------------{ram access}begin--------------------------//
wire fft_read  = (fft_state == ST_READ);
wire fft_write = (fft_state == ST_WRITE);

wire mem0_write_sample = sample_write_hit & (fft_state == ST_IDLE);
wire mem0_en_a = sample_read_launch | (fft_read & !src_bank) | (fft_write & !dst_bank);
wire mem0_we_a = fft_write & !dst_bank;
wire [7:0] mem0_addr_a =
    sample_read_launch ? sample_read_launch_index :
    (fft_read & !src_bank) ? idx_a               :
    addr_a_r;
wire [31:0] mem0_din_a = out0_packed_r;

wire mem0_en_b = mem0_write_sample | (fft_read & !src_bank) | (fft_write & !dst_bank);
wire mem0_we_b = mem0_write_sample | (fft_write & !dst_bank);
wire [7:0] mem0_addr_b =
    mem0_write_sample ? sample_write_index :
    (fft_read & !src_bank) ? idx_b         :
    addr_b_r;
wire [31:0] mem0_din_b = mem0_write_sample ? s_wdata : out1_packed_r;

wire mem1_en_a = (fft_read & src_bank) | (fft_write & dst_bank);
wire mem1_we_a = fft_write & dst_bank;
wire [7:0] mem1_addr_a = (fft_read & src_bank) ? idx_a : addr_a_r;
wire [31:0] mem1_din_a = out0_packed_r;

wire mem1_en_b = (fft_read & src_bank) | (fft_write & dst_bank);
wire mem1_we_b = fft_write & dst_bank;
wire [7:0] mem1_addr_b = (fft_read & src_bank) ? idx_b : addr_b_r;
wire [31:0] mem1_din_b = out1_packed_r;
//--------------------------------{ram access}end---------------------------//

assign s_arready = ~busy & (!R_or_W | !s_awvalid) & ar_sample_allowed;
assign s_awready = ~busy & ( R_or_W | !s_arvalid) & aw_sample_allowed;

assign s_wready = s_wready_r;
assign s_rvalid = s_rvalid_r;
assign s_rdata  = s_rdata_r;
assign s_rid    = buf_id;
assign s_rresp  = 2'b0;
assign s_rlast  = s_rlast_r;
assign s_bvalid = s_bvalid_r;
assign s_bid    = buf_id;
assign s_bresp  = 2'b0;

//-------------------------------{twiddle rom}begin-------------------------//
initial begin
    twiddle_rom[7'd0]   = {16'h0000, 16'h7fff};
    twiddle_rom[7'd1]   = {16'hfcdc, 16'h7ff5};
    twiddle_rom[7'd2]   = {16'hf9b8, 16'h7fd8};
    twiddle_rom[7'd3]   = {16'hf696, 16'h7fa6};
    twiddle_rom[7'd4]   = {16'hf374, 16'h7f61};
    twiddle_rom[7'd5]   = {16'hf055, 16'h7f09};
    twiddle_rom[7'd6]   = {16'hed38, 16'h7e9c};
    twiddle_rom[7'd7]   = {16'hea1e, 16'h7e1d};
    twiddle_rom[7'd8]   = {16'he707, 16'h7d89};
    twiddle_rom[7'd9]   = {16'he3f5, 16'h7ce3};
    twiddle_rom[7'd10]  = {16'he0e6, 16'h7c29};
    twiddle_rom[7'd11]  = {16'hdddd, 16'h7b5c};
    twiddle_rom[7'd12]  = {16'hdad8, 16'h7a7c};
    twiddle_rom[7'd13]  = {16'hd7da, 16'h7989};
    twiddle_rom[7'd14]  = {16'hd4e1, 16'h7884};
    twiddle_rom[7'd15]  = {16'hd1ef, 16'h776b};
    twiddle_rom[7'd16]  = {16'hcf05, 16'h7641};
    twiddle_rom[7'd17]  = {16'hcc21, 16'h7504};
    twiddle_rom[7'd18]  = {16'hc946, 16'h73b5};
    twiddle_rom[7'd19]  = {16'hc674, 16'h7254};
    twiddle_rom[7'd20]  = {16'hc3aa, 16'h70e2};
    twiddle_rom[7'd21]  = {16'hc0e9, 16'h6f5e};
    twiddle_rom[7'd22]  = {16'hbe32, 16'h6dc9};
    twiddle_rom[7'd23]  = {16'hbb86, 16'h6c23};
    twiddle_rom[7'd24]  = {16'hb8e4, 16'h6a6d};
    twiddle_rom[7'd25]  = {16'hb64c, 16'h68a6};
    twiddle_rom[7'd26]  = {16'hb3c1, 16'h66cf};
    twiddle_rom[7'd27]  = {16'hb141, 16'h64e8};
    twiddle_rom[7'd28]  = {16'haecd, 16'h62f1};
    twiddle_rom[7'd29]  = {16'hac65, 16'h60eb};
    twiddle_rom[7'd30]  = {16'haa0b, 16'h5ed7};
    twiddle_rom[7'd31]  = {16'ha7be, 16'h5cb3};
    twiddle_rom[7'd32]  = {16'ha57e, 16'h5a82};
    twiddle_rom[7'd33]  = {16'ha34d, 16'h5842};
    twiddle_rom[7'd34]  = {16'ha129, 16'h55f5};
    twiddle_rom[7'd35]  = {16'h9f15, 16'h539b};
    twiddle_rom[7'd36]  = {16'h9d0f, 16'h5133};
    twiddle_rom[7'd37]  = {16'h9b18, 16'h4ebf};
    twiddle_rom[7'd38]  = {16'h9931, 16'h4c3f};
    twiddle_rom[7'd39]  = {16'h975a, 16'h49b4};
    twiddle_rom[7'd40]  = {16'h9593, 16'h471c};
    twiddle_rom[7'd41]  = {16'h93dd, 16'h447a};
    twiddle_rom[7'd42]  = {16'h9237, 16'h41ce};
    twiddle_rom[7'd43]  = {16'h90a2, 16'h3f17};
    twiddle_rom[7'd44]  = {16'h8f1e, 16'h3c56};
    twiddle_rom[7'd45]  = {16'h8dac, 16'h398c};
    twiddle_rom[7'd46]  = {16'h8c4b, 16'h36ba};
    twiddle_rom[7'd47]  = {16'h8afc, 16'h33df};
    twiddle_rom[7'd48]  = {16'h89bf, 16'h30fb};
    twiddle_rom[7'd49]  = {16'h8895, 16'h2e11};
    twiddle_rom[7'd50]  = {16'h877c, 16'h2b1f};
    twiddle_rom[7'd51]  = {16'h8677, 16'h2826};
    twiddle_rom[7'd52]  = {16'h8584, 16'h2528};
    twiddle_rom[7'd53]  = {16'h84a4, 16'h2223};
    twiddle_rom[7'd54]  = {16'h83d7, 16'h1f1a};
    twiddle_rom[7'd55]  = {16'h831d, 16'h1c0b};
    twiddle_rom[7'd56]  = {16'h8277, 16'h18f9};
    twiddle_rom[7'd57]  = {16'h81e3, 16'h15e2};
    twiddle_rom[7'd58]  = {16'h8164, 16'h12c8};
    twiddle_rom[7'd59]  = {16'h80f7, 16'h0fab};
    twiddle_rom[7'd60]  = {16'h809f, 16'h0c8c};
    twiddle_rom[7'd61]  = {16'h805a, 16'h096a};
    twiddle_rom[7'd62]  = {16'h8028, 16'h0648};
    twiddle_rom[7'd63]  = {16'h800b, 16'h0324};
    twiddle_rom[7'd64]  = {16'h8001, 16'h0000};
    twiddle_rom[7'd65]  = {16'h800b, 16'hfcdc};
    twiddle_rom[7'd66]  = {16'h8028, 16'hf9b8};
    twiddle_rom[7'd67]  = {16'h805a, 16'hf696};
    twiddle_rom[7'd68]  = {16'h809f, 16'hf374};
    twiddle_rom[7'd69]  = {16'h80f7, 16'hf055};
    twiddle_rom[7'd70]  = {16'h8164, 16'hed38};
    twiddle_rom[7'd71]  = {16'h81e3, 16'hea1e};
    twiddle_rom[7'd72]  = {16'h8277, 16'he707};
    twiddle_rom[7'd73]  = {16'h831d, 16'he3f5};
    twiddle_rom[7'd74]  = {16'h83d7, 16'he0e6};
    twiddle_rom[7'd75]  = {16'h84a4, 16'hdddd};
    twiddle_rom[7'd76]  = {16'h8584, 16'hdad8};
    twiddle_rom[7'd77]  = {16'h8677, 16'hd7da};
    twiddle_rom[7'd78]  = {16'h877c, 16'hd4e1};
    twiddle_rom[7'd79]  = {16'h8895, 16'hd1ef};
    twiddle_rom[7'd80]  = {16'h89bf, 16'hcf05};
    twiddle_rom[7'd81]  = {16'h8afc, 16'hcc21};
    twiddle_rom[7'd82]  = {16'h8c4b, 16'hc946};
    twiddle_rom[7'd83]  = {16'h8dac, 16'hc674};
    twiddle_rom[7'd84]  = {16'h8f1e, 16'hc3aa};
    twiddle_rom[7'd85]  = {16'h90a2, 16'hc0e9};
    twiddle_rom[7'd86]  = {16'h9237, 16'hbe32};
    twiddle_rom[7'd87]  = {16'h93dd, 16'hbb86};
    twiddle_rom[7'd88]  = {16'h9593, 16'hb8e4};
    twiddle_rom[7'd89]  = {16'h975a, 16'hb64c};
    twiddle_rom[7'd90]  = {16'h9931, 16'hb3c1};
    twiddle_rom[7'd91]  = {16'h9b18, 16'hb141};
    twiddle_rom[7'd92]  = {16'h9d0f, 16'haecd};
    twiddle_rom[7'd93]  = {16'h9f15, 16'hac65};
    twiddle_rom[7'd94]  = {16'ha129, 16'haa0b};
    twiddle_rom[7'd95]  = {16'ha34d, 16'ha7be};
    twiddle_rom[7'd96]  = {16'ha57e, 16'ha57e};
    twiddle_rom[7'd97]  = {16'ha7be, 16'ha34d};
    twiddle_rom[7'd98]  = {16'haa0b, 16'ha129};
    twiddle_rom[7'd99]  = {16'hac65, 16'h9f15};
    twiddle_rom[7'd100] = {16'haecd, 16'h9d0f};
    twiddle_rom[7'd101] = {16'hb141, 16'h9b18};
    twiddle_rom[7'd102] = {16'hb3c1, 16'h9931};
    twiddle_rom[7'd103] = {16'hb64c, 16'h975a};
    twiddle_rom[7'd104] = {16'hb8e4, 16'h9593};
    twiddle_rom[7'd105] = {16'hbb86, 16'h93dd};
    twiddle_rom[7'd106] = {16'hbe32, 16'h9237};
    twiddle_rom[7'd107] = {16'hc0e9, 16'h90a2};
    twiddle_rom[7'd108] = {16'hc3aa, 16'h8f1e};
    twiddle_rom[7'd109] = {16'hc674, 16'h8dac};
    twiddle_rom[7'd110] = {16'hc946, 16'h8c4b};
    twiddle_rom[7'd111] = {16'hcc21, 16'h8afc};
    twiddle_rom[7'd112] = {16'hcf05, 16'h89bf};
    twiddle_rom[7'd113] = {16'hd1ef, 16'h8895};
    twiddle_rom[7'd114] = {16'hd4e1, 16'h877c};
    twiddle_rom[7'd115] = {16'hd7da, 16'h8677};
    twiddle_rom[7'd116] = {16'hdad8, 16'h8584};
    twiddle_rom[7'd117] = {16'hdddd, 16'h84a4};
    twiddle_rom[7'd118] = {16'he0e6, 16'h83d7};
    twiddle_rom[7'd119] = {16'he3f5, 16'h831d};
    twiddle_rom[7'd120] = {16'he707, 16'h8277};
    twiddle_rom[7'd121] = {16'hea1e, 16'h81e3};
    twiddle_rom[7'd122] = {16'hed38, 16'h8164};
    twiddle_rom[7'd123] = {16'hf055, 16'h80f7};
    twiddle_rom[7'd124] = {16'hf374, 16'h809f};
    twiddle_rom[7'd125] = {16'hf696, 16'h805a};
    twiddle_rom[7'd126] = {16'hf9b8, 16'h8028};
    twiddle_rom[7'd127] = {16'hfcdc, 16'h800b};
end
//--------------------------------{twiddle rom}end--------------------------//

//-------------------------------{axi ctrl}begin----------------------------//
always @(posedge aclk) begin
    if (~aresetn) begin
        busy <= 1'b0;
    end
    else if (ar_enter | aw_enter) begin
        busy <= 1'b1;
    end
    else if (r_retire | b_retire) begin
        busy <= 1'b0;
    end
end

always @(posedge aclk) begin
    if (~aresetn) begin
        R_or_W    <= 1'b0;
        buf_id    <= 5'b0;
        buf_addr  <= 32'b0;
        buf_len   <= 8'b0;
        buf_size  <= 3'b0;
        buf_burst <= 2'b0;
        buf_lock  <= 1'b0;
        buf_cache <= 4'b0;
        buf_prot  <= 3'b0;
    end
    else if (ar_enter | aw_enter) begin
        R_or_W    <= ar_enter;
        buf_id    <= ar_enter ? s_arid    : s_awid;
        buf_addr  <= ar_enter ? s_araddr  : s_awaddr;
        buf_len   <= ar_enter ? s_arlen   : s_awlen;
        buf_size  <= ar_enter ? s_arsize  : s_awsize;
        buf_burst <= ar_enter ? s_arburst : s_awburst;
        buf_lock  <= ar_enter ? s_arlock  : s_awlock;
        buf_cache <= ar_enter ? s_arcache : s_awcache;
        buf_prot  <= ar_enter ? s_arprot  : s_awprot;
    end
end

always @(posedge aclk) begin
    if (~aresetn) begin
        write <= 1'b0;
    end
    else if (aw_enter) begin
        write <= 1'b1;
    end
    else if (ar_enter) begin
        write <= 1'b0;
    end
end

always @(posedge aclk) begin
    if (~aresetn) begin
        s_wready_r <= 1'b0;
    end
    else if (aw_enter) begin
        s_wready_r <= 1'b1;
    end
    else if (w_enter) begin
        s_wready_r <= 1'b0;
    end
end

always @(posedge aclk) begin
    if (~aresetn) begin
        s_bvalid_r <= 1'b0;
    end
    else if (w_enter) begin
        s_bvalid_r <= 1'b1;
    end
    else if (b_retire) begin
        s_bvalid_r <= 1'b0;
    end
end

always @(posedge aclk) begin
    if (~aresetn) begin
        s_rdata_r  <= 32'b0;
        s_rvalid_r <= 1'b0;
        s_rlast_r  <= 1'b0;
    end
    else if (read_pending) begin
        s_rdata_r  <= read_pending_is_sample ? fft_mem0_rdata_a : reg_read_data_pending;
        s_rvalid_r <= 1'b1;
        s_rlast_r  <= 1'b1;
    end
    else if (r_retire) begin
        s_rvalid_r <= 1'b0;
    end
end

always @(posedge aclk) begin
    if (~aresetn) begin
        read_pending <= 1'b0;
        read_pending_is_sample <= 1'b0;
        reg_read_data_pending <= 32'd0;
    end
    else begin
        if (read_pending) begin
            read_pending <= 1'b0;
        end

        if (ar_enter) begin
            read_pending <= 1'b1;
            read_pending_is_sample <= ar_sample_hit_current;
            if (!ar_sample_hit_current) begin
                reg_read_data_pending <= ar_reg_rdata_d;
            end
        end
    end
end
//--------------------------------{axi ctrl}end-----------------------------//

//-------------------------------{ram access}begin--------------------------//
always @(posedge aclk) begin
    if (mem0_en_a) begin
        fft_mem0_rdata_a <= fft_mem0[mem0_addr_a];
        if (mem0_we_a) begin
            fft_mem0[mem0_addr_a] <= mem0_din_a;
        end
    end
end

always @(posedge aclk) begin
    if (mem0_en_b) begin
        fft_mem0_rdata_b <= fft_mem0[mem0_addr_b];
        if (mem0_we_b) begin
            fft_mem0[mem0_addr_b] <= mem0_din_b;
        end
    end
end

always @(posedge aclk) begin
    if (mem1_en_a) begin
        fft_mem1_rdata_a <= fft_mem1[mem1_addr_a];
        if (mem1_we_a) begin
            fft_mem1[mem1_addr_a] <= mem1_din_a;
        end
    end
end

always @(posedge aclk) begin
    if (mem1_en_b) begin
        fft_mem1_rdata_b <= fft_mem1[mem1_addr_b];
        if (mem1_we_b) begin
            fft_mem1[mem1_addr_b] <= mem1_din_b;
        end
    end
end
//--------------------------------{ram access}end---------------------------//

//-------------------------------{fft core}begin----------------------------//
always @(posedge aclk) begin
    if (!aresetn) begin
        done         <= 1'b0;
        fft_state    <= ST_IDLE;
        stage_idx    <= 3'd0;
        block_base   <= 8'd0;
        j_idx        <= 8'd0;
        src_bank     <= 1'b0;
        dst_bank     <= 1'b1;
        addr_a_r     <= 8'd0;
        addr_b_r     <= 8'd0;
        a_data_r     <= 32'd0;
        out0_packed_r<= 32'd0;
        out1_packed_r<= 32'd0;
        tw_re_r      <= 16'sd0;
        tw_im_r      <= 16'sd0;
        bw_re_r      <= 32'sd0;
        bw_im_r      <= 32'sd0;
        fft_finish   <= 1'b0;
    end
    else begin
        fft_finish <= 1'b0;

        if (ctrl_write && s_wdata[1]) begin
            done <= 1'b0;
        end

        case (fft_state)
            ST_IDLE: begin
                stage_idx  <= 3'd0;
                block_base <= 8'd0;
                j_idx      <= 8'd0;
                if (ctrl_write && s_wdata[0]) begin
                    done      <= 1'b0;
                    src_bank  <= 1'b0;
                    dst_bank  <= 1'b1;
                    fft_state <= ST_READ;
                end
            end

            ST_READ: begin
                addr_a_r  <= idx_a;
                addr_b_r  <= idx_b;
                tw_re_r   <= tw_pair[15:0];
                tw_im_r   <= tw_pair[31:16];
                fft_state <= ST_MUL;
            end

            ST_MUL: begin
                a_data_r  <= fft_src_rdata_a;
                bw_re_r   <= bw_re_calc;
                bw_im_r   <= bw_im_calc;
                fft_state <= ST_PACK;
            end

            ST_PACK: begin
                out0_packed_r <= {sat16(out0_im_calc), sat16(out0_re_calc)};
                out1_packed_r <= {sat16(out1_im_calc), sat16(out1_re_calc)};
                fft_state     <= ST_WRITE;
            end

            ST_WRITE: begin
                if ((j_idx + 1'b1) < stage_half) begin
                    j_idx      <= j_idx + 1'b1;
                    fft_state  <= ST_READ;
                end
                else if ((block_base + stage_span) < FFT_POINTS) begin
                    j_idx      <= 8'd0;
                    block_base <= block_base + stage_span[7:0];
                    fft_state  <= ST_READ;
                end
                else if (stage_idx == FFT_STAGES - 1) begin
                    fft_state  <= ST_IDLE;
                    done       <= 1'b1;
                    fft_finish <= 1'b1;
                end
                else begin
                    src_bank   <= dst_bank;
                    dst_bank   <= src_bank;
                    stage_idx  <= stage_idx + 1'b1;
                    block_base <= 8'd0;
                    j_idx      <= 8'd0;
                    fft_state  <= ST_READ;
                end
            end

            default: begin
                fft_state <= ST_IDLE;
            end
        endcase
    end
end
//--------------------------------{fft core}end-----------------------------//

function signed [15:0] sat16;
    input signed [31:0] value;
    begin
        if (value > 32'sd32767) begin
            sat16 = 16'sh7fff;
        end
        else if (value < -32'sd32768) begin
            sat16 = -16'sd32768;
        end
        else begin
            sat16 = value[15:0];
        end
    end
endfunction

function [6:0] calc_twiddle_index;
    input [2:0] stage;
    input [7:0] j;
    begin
        case (stage)
            3'd0: calc_twiddle_index = 7'd0;
            3'd1: calc_twiddle_index = {j[0],   6'd0};
            3'd2: calc_twiddle_index = {j[1:0], 5'd0};
            3'd3: calc_twiddle_index = {j[2:0], 4'd0};
            3'd4: calc_twiddle_index = {j[3:0], 3'd0};
            3'd5: calc_twiddle_index = {j[4:0], 2'd0};
            3'd6: calc_twiddle_index = {j[5:0], 1'd0};
            default: calc_twiddle_index = j[6:0];
        endcase
    end
endfunction

endmodule
