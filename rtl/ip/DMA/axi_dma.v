module axi_dma (
    input            s_awvalid,
    output           s_awready,
    input   [31:0]   s_awaddr,
    input   [4:0]    s_awid,
    input   [7:0]    s_awlen,
    input   [2:0]    s_awsize,
    input   [1:0]    s_awburst,
    input            s_awlock,
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
    input            s_arlock,
    input   [3:0]    s_arcache,
    input   [2:0]    s_arprot,
    output           s_rvalid,
    input            s_rready,
    output  [31:0]   s_rdata,
    output  [4:0]    s_rid,
    output  [1:0]    s_rresp,
    output           s_rlast,

    output  [3:0]    m_arid,
    output  [31:0]   m_araddr,
    output  [7:0]    m_arlen,
    output  [2:0]    m_arsize,
    output  [1:0]    m_arburst,
    output           m_arlock,
    output  [3:0]    m_arcache,
    output  [2:0]    m_arprot,
    output           m_arvalid,
    input            m_arready,
    input   [3:0]    m_rid,
    input   [31:0]   m_rdata,
    input   [1:0]    m_rresp,
    input            m_rlast,
    input            m_rvalid,
    output           m_rready,
    output  [3:0]    m_awid,
    output  [31:0]   m_awaddr,
    output  [7:0]    m_awlen,
    output  [2:0]    m_awsize,
    output  [1:0]    m_awburst,
    output           m_awlock,
    output  [3:0]    m_awcache,
    output  [2:0]    m_awprot,
    output           m_awvalid,
    input            m_awready,
    output  [31:0]   m_wdata,
    output  [3:0]    m_wstrb,
    output           m_wlast,
    output           m_wvalid,
    input            m_wready,
    input   [3:0]    m_bid,
    input   [1:0]    m_bresp,
    input            m_bvalid,
    output           m_bready,

    output reg       dma_finish,
    input            aclk,
    input            aresetn
);

    // Register map used by the CPU-side AXI slave port.
    // CTRL bit0 starts normal DMA, bit1 clears DONE, bit2 selects matmul batch mode.
    // In matmul mode bit3 skips result writeback and only folds generated words into CRC32.
    // In normal DMA LEN is a byte count. In matmul batch mode LEN is the group count.
    localparam CTRL_ADDR      = 16'h0000;
    localparam STATUS_ADDR    = 16'h0004;
    localparam SRC_ADDR       = 16'h0008;
    localparam DST_ADDR       = 16'h000c;
    localparam LEN_ADDR       = 16'h0010;
    localparam CUR_SRC_ADDR   = 16'h0014;
    localparam CUR_DST_ADDR   = 16'h0018;
    localparam REMAIN_ADDR    = 16'h001c;
    localparam VERSION_ADDR   = 16'h0020;
    localparam MATMUL_CRC_ADDR = 16'h0024;

    localparam DEFAULT_BURST_MAX_WORDS = 8'd64;
    localparam KYBER_BURST_MAX_WORDS   = 8'd128;

    // One master FSM is shared by legacy memcpy/stream DMA and the matmul batch path.
    // Matmul has its own internal read/compute/write pipeline under M_MM_PIPE.
    localparam M_IDLE      = 5'd0;
    localparam M_AR        = 5'd1;
    localparam M_R         = 5'd2;
    localparam M_AW        = 5'd3;
    localparam M_W         = 5'd4;
    localparam M_B         = 5'd5;
    localparam M_STREAM    = 5'd6;
    localparam M_MM_PIPE   = 5'd7;

    localparam RD_IDLE = 2'd0;
    localparam RD_AR   = 2'd1;
    localparam RD_R    = 2'd2;
    localparam WR_IDLE = 2'd0;
    localparam WR_AW   = 2'd1;
    localparam WR_W    = 2'd2;
    localparam WR_B    = 2'd3;

    localparam MM_CALC_IDLE  = 2'd0;
    localparam MM_CALC_RUN   = 2'd1;
    localparam MM_CALC_STORE = 2'd2;

    reg axi_busy, axi_write, axi_r_or_w;
    reg s_wready_r;
    reg [4:0] buf_id;
    reg [31:0] buf_addr;
    reg [7:0] buf_len;
    reg [2:0] buf_size;
    reg [1:0] buf_burst;
    reg buf_lock;
    reg [3:0] buf_cache;
    reg [2:0] buf_prot;
    reg [31:0] s_rdata_r;
    reg s_rvalid_r;
    reg s_rlast_r;
    reg s_bvalid_r;

    reg [31:0] dma_src_addr;
    reg [31:0] dma_dst_addr;
    reg [31:0] dma_len_cfg;
    reg [31:0] dma_cur_src;
    reg [31:0] dma_cur_dst;
    reg [31:0] dma_remain;
    reg dma_busy;
    reg dma_done;
    reg dma_error;
    reg [4:0] dma_state;
    reg matmul_crc_only;

    reg m_arvalid_r;
    reg [31:0] m_araddr_r;
    reg [7:0] m_arlen_r;
    reg m_rready_r;
    reg m_awvalid_r;
    reg [31:0] m_awaddr_r;
    reg [7:0] m_awlen_r;
    reg m_wvalid_r;
    reg [31:0] m_wdata_r;
    reg m_wlast_r;
    reg m_bready_r;
    reg [7:0] dma_burst_words;
    reg [7:0] dma_rd_cnt;
    reg [7:0] dma_wr_cnt;
    reg dma_src_burst_en;
    reg dma_dst_burst_en;
    reg [31:0] dma_buf [0:127];
    reg [1:0] stream_rd_state;
    reg [1:0] stream_wr_state;
    reg [7:0] stream_rd_beats;
    reg [7:0] stream_wr_beats;
    reg [6:0] stream_fifo_wr_ptr;
    reg [6:0] stream_fifo_rd_ptr;
    reg [7:0] stream_fifo_count;
    reg [31:0] stream_rd_addr;
    reg [31:0] stream_wr_addr;
    reg [31:0] stream_rd_remain;
    reg [31:0] stream_wr_remain;

    // Matmul batch registers. The batch engine reads A/B from ExtRAM, computes C,
    // writes the 48-word packed result, and folds those same words into CRC32.
    reg [31:0] matmul_crc;
    reg [31:0] mm_crc_state;
    reg [31:0] mm_groups_left;
    reg [31:0] mm_read_left;
    reg [5:0] mm_rd_cnt;
    reg [1:0] mm_rd_state;
    reg [1:0] mm_wr_state;
    reg [1:0] mm_calc_state;
    reg mm_rd_slot;
    reg mm_calc_in_slot;
    reg mm_calc_out_slot;
    reg mm_wr_slot;
    reg mm_in0_valid;
    reg mm_in1_valid;
    reg mm_out0_valid;
    reg mm_out1_valid;
    reg [1:0] mm_calc_k;
    reg [4:0] mm_calc_bit;
    reg [5:0] mm_wr_cnt;
    reg [31:0] mm_in0 [0:31];
    reg [31:0] mm_in1 [0:31];
    reg [31:0] mm_out0 [0:47];
    reg [31:0] mm_out1 [0:47];
    reg [31:0] mm_a [0:15];
    reg [31:0] mm_b [0:15];
    reg [65:0] mm_c [0:15];
    reg [65:0] mm_a_shift [0:3];
    reg [65:0] mm_a_shift2 [0:3];
    reg [65:0] mm_a_shift3 [0:3];
    reg [65:0] mm_a_shift4 [0:3];
    reg [65:0] mm_a_shift5 [0:3];
    reg [65:0] mm_a_shift6 [0:3];
    reg [65:0] mm_a_shift7 [0:3];
    integer i;

    wire ar_enter = s_arvalid & s_arready;
    wire r_retire = s_rvalid_r & s_rready & s_rlast_r;
    wire aw_enter = s_awvalid & s_awready;
    wire w_enter  = s_wvalid & s_wready_r & s_wlast;
    wire b_retire = s_bvalid_r & s_bready;

    wire write_ctrl    = w_enter & (buf_addr[15:0] == CTRL_ADDR);
    wire write_src     = w_enter & (buf_addr[15:0] == SRC_ADDR);
    wire write_dst     = w_enter & (buf_addr[15:0] == DST_ADDR);
    wire write_len     = w_enter & (buf_addr[15:0] == LEN_ADDR);
    wire ctrl_start    = write_ctrl & s_wdata[0];
    wire ctrl_clr_done = write_ctrl & s_wdata[1];
    wire ctrl_matmul   = write_ctrl & s_wdata[2];
    wire ctrl_matmul_crc_only = write_ctrl & s_wdata[3];
    wire m_ar_fire = m_arvalid_r & m_arready;
    wire m_r_fire  = m_rready_r & m_rvalid;
    wire m_aw_fire = m_awvalid_r & m_awready;
    wire m_w_fire  = m_wvalid_r & m_wready;
    wire m_b_fire  = m_bready_r & m_bvalid;
    wire stream_push = m_r_fire & (m_rresp == 2'b00);
    wire stream_pop = m_w_fire;

    wire cfg_invalid = (dma_len_cfg == 32'd0) |
                       (dma_src_addr[1:0] != 2'b00) |
                       (dma_dst_addr[1:0] != 2'b00) |
                       (dma_len_cfg[1:0] != 2'b00);
    wire matmul_cfg_invalid = (dma_len_cfg == 32'd0) |
                              (dma_src_addr[1:0] != 2'b00) |
                              (dma_dst_addr[1:0] != 2'b00);
    wire kyber_src_cfg = (dma_src_addr[31:20] == 12'h1f6);
    wire kyber_dst_cfg = (dma_dst_addr[31:20] == 12'h1f6);
    wire matmul_src_cfg = (dma_src_addr[31:20] == 12'h1f5);
    wire matmul_dst_cfg = (dma_dst_addr[31:20] == 12'h1f5);
    wire src_burst_allow_cfg = (dma_src_addr[28:24] != 5'h1f) | kyber_src_cfg | matmul_src_cfg;
    wire dst_burst_allow_cfg = (dma_dst_addr[28:24] != 5'h1f) | kyber_dst_cfg | matmul_dst_cfg;
    wire chunk_allow_cfg = src_burst_allow_cfg | dst_burst_allow_cfg;
    wire stream_cfg = kyber_src_cfg ^ kyber_dst_cfg;
    wire [7:0] burst_max_words = (kyber_src_cfg | kyber_dst_cfg) ? KYBER_BURST_MAX_WORDS : DEFAULT_BURST_MAX_WORDS;
    wire [31:0] burst_max_bytes = ({24'd0, burst_max_words} << 2);
    wire [7:0] stream_fifo_space = 8'd128 - stream_fifo_count;
    wire [7:0] stream_fifo_space_next = stream_fifo_space + (stream_pop ? 8'd1 : 8'd0) - (stream_push ? 8'd1 : 8'd0);
    wire [31:0] stream_rd_remain_next = stream_rd_remain - 32'd1;
    wire [7:0] stream_rd_words_cap = (stream_rd_remain > {24'd0, burst_max_words}) ? burst_max_words : stream_rd_remain[7:0];
    wire [7:0] stream_rd_words_space = (stream_fifo_space < stream_rd_words_cap) ? stream_fifo_space : stream_rd_words_cap;
    wire [7:0] stream_rd_words_calc = src_burst_allow_cfg ? stream_rd_words_space : 8'd1;
    wire [7:0] stream_rd_words_cap_next = (stream_rd_remain_next > {24'd0, burst_max_words}) ? burst_max_words : stream_rd_remain_next[7:0];
    wire [7:0] stream_rd_words_space_next = (stream_fifo_space_next < stream_rd_words_cap_next) ? stream_fifo_space_next : stream_rd_words_cap_next;
    wire [7:0] stream_rd_words_calc_next = src_burst_allow_cfg ? stream_rd_words_space_next : 8'd1;
    wire [7:0] stream_wr_words_cap = (stream_wr_remain > {24'd0, burst_max_words}) ? burst_max_words : stream_wr_remain[7:0];
    wire [7:0] stream_wr_words_fifo = (stream_fifo_count < stream_wr_words_cap) ? stream_fifo_count : stream_wr_words_cap;
    wire [7:0] stream_wr_words_calc = dst_burst_allow_cfg ? stream_wr_words_fifo : 8'd1;
    wire [7:0] dma_words_from_len = chunk_allow_cfg ? ((dma_len_cfg > burst_max_bytes) ? burst_max_words : dma_len_cfg[9:2]) : 8'd1;
    wire [31:0] dma_burst_bytes = ({24'd0, dma_burst_words} << 2);
    wire [31:0] dma_remain_next = dma_remain - dma_burst_bytes;
    wire [31:0] dma_next_src = dma_cur_src + dma_burst_bytes;
    wire [31:0] dma_next_dst = dma_cur_dst + dma_burst_bytes;
    wire src_burst_allow_next = (dma_next_src[28:24] != 5'h1f);
    wire dst_burst_allow_next = (dma_next_dst[28:24] != 5'h1f);
    wire chunk_allow_next = src_burst_allow_next | dst_burst_allow_next;
    wire [7:0] dma_words_from_next = chunk_allow_next ? ((dma_remain_next > burst_max_bytes) ? burst_max_words : dma_remain_next[9:2]) : 8'd1;
    wire [5:0] mm_wr_word_next = mm_wr_cnt + 6'd1;
    wire [5:0] mm_wr_word_next2 = mm_wr_cnt + 6'd2;
    wire [4:0] mm_calc_pair_next = mm_calc_bit + 5'd3;
    wire [1:0] mm_calc_next_k = mm_calc_k + 2'd1;
    wire mm_read_slot0_free = !mm_in0_valid && !((mm_calc_state != MM_CALC_IDLE) && (mm_calc_in_slot == 1'b0));
    wire mm_read_slot1_free = !mm_in1_valid && !((mm_calc_state != MM_CALC_IDLE) && (mm_calc_in_slot == 1'b1));
    wire mm_output_slot0_free = !mm_out0_valid && !((mm_calc_state != MM_CALC_IDLE) && (mm_calc_out_slot == 1'b0));
    wire mm_output_slot1_free = !mm_out1_valid && !((mm_calc_state != MM_CALC_IDLE) && (mm_calc_out_slot == 1'b1));

    wire [31:0] status_data = {29'd0, dma_error, dma_done, dma_busy};
    wire [31:0] rdata_d =   buf_addr[15:0] == CTRL_ADDR    ? 32'd0        :
                            buf_addr[15:0] == STATUS_ADDR  ? status_data   :
                            buf_addr[15:0] == SRC_ADDR     ? dma_src_addr  :
                            buf_addr[15:0] == DST_ADDR     ? dma_dst_addr  :
                            buf_addr[15:0] == LEN_ADDR     ? dma_len_cfg   :
                            buf_addr[15:0] == CUR_SRC_ADDR ? dma_cur_src   :
                            buf_addr[15:0] == CUR_DST_ADDR ? dma_cur_dst   :
                            buf_addr[15:0] == REMAIN_ADDR  ? dma_remain    :
                            buf_addr[15:0] == VERSION_ADDR ? 32'h444d_4132 :
                            buf_addr[15:0] == MATMUL_CRC_ADDR ? matmul_crc  :
                            32'd0;

    assign s_arready = ~axi_busy & (!axi_r_or_w | !s_awvalid);
    assign s_awready = ~axi_busy & ( axi_r_or_w | !s_arvalid);

    // IEEE CRC-32 update for one little-endian 32-bit word. This is equivalent
    // to processing bytes [7:0], [15:8], [23:16], [31:24] with polynomial
    // 0xedb88320, but allows the write channel to run one result word per cycle.
    function [31:0] crc32_next_word;
        input [31:0] crc_in;
        input [31:0] data_in;
        begin
            crc32_next_word[0] = crc_in[0] ^ crc_in[1] ^ crc_in[2] ^ crc_in[3] ^ crc_in[4] ^ crc_in[6] ^ crc_in[7] ^ crc_in[8] ^ crc_in[16] ^ crc_in[20] ^ crc_in[22] ^ crc_in[23] ^ crc_in[26] ^ data_in[0] ^ data_in[1] ^ data_in[2] ^ data_in[3] ^ data_in[4] ^ data_in[6] ^ data_in[7] ^ data_in[8] ^ data_in[16] ^ data_in[20] ^ data_in[22] ^ data_in[23] ^ data_in[26];
            crc32_next_word[1] = crc_in[1] ^ crc_in[2] ^ crc_in[3] ^ crc_in[4] ^ crc_in[5] ^ crc_in[7] ^ crc_in[8] ^ crc_in[9] ^ crc_in[17] ^ crc_in[21] ^ crc_in[23] ^ crc_in[24] ^ crc_in[27] ^ data_in[1] ^ data_in[2] ^ data_in[3] ^ data_in[4] ^ data_in[5] ^ data_in[7] ^ data_in[8] ^ data_in[9] ^ data_in[17] ^ data_in[21] ^ data_in[23] ^ data_in[24] ^ data_in[27];
            crc32_next_word[2] = crc_in[0] ^ crc_in[2] ^ crc_in[3] ^ crc_in[4] ^ crc_in[5] ^ crc_in[6] ^ crc_in[8] ^ crc_in[9] ^ crc_in[10] ^ crc_in[18] ^ crc_in[22] ^ crc_in[24] ^ crc_in[25] ^ crc_in[28] ^ data_in[0] ^ data_in[2] ^ data_in[3] ^ data_in[4] ^ data_in[5] ^ data_in[6] ^ data_in[8] ^ data_in[9] ^ data_in[10] ^ data_in[18] ^ data_in[22] ^ data_in[24] ^ data_in[25] ^ data_in[28];
            crc32_next_word[3] = crc_in[1] ^ crc_in[3] ^ crc_in[4] ^ crc_in[5] ^ crc_in[6] ^ crc_in[7] ^ crc_in[9] ^ crc_in[10] ^ crc_in[11] ^ crc_in[19] ^ crc_in[23] ^ crc_in[25] ^ crc_in[26] ^ crc_in[29] ^ data_in[1] ^ data_in[3] ^ data_in[4] ^ data_in[5] ^ data_in[6] ^ data_in[7] ^ data_in[9] ^ data_in[10] ^ data_in[11] ^ data_in[19] ^ data_in[23] ^ data_in[25] ^ data_in[26] ^ data_in[29];
            crc32_next_word[4] = crc_in[2] ^ crc_in[4] ^ crc_in[5] ^ crc_in[6] ^ crc_in[7] ^ crc_in[8] ^ crc_in[10] ^ crc_in[11] ^ crc_in[12] ^ crc_in[20] ^ crc_in[24] ^ crc_in[26] ^ crc_in[27] ^ crc_in[30] ^ data_in[2] ^ data_in[4] ^ data_in[5] ^ data_in[6] ^ data_in[7] ^ data_in[8] ^ data_in[10] ^ data_in[11] ^ data_in[12] ^ data_in[20] ^ data_in[24] ^ data_in[26] ^ data_in[27] ^ data_in[30];
            crc32_next_word[5] = crc_in[0] ^ crc_in[3] ^ crc_in[5] ^ crc_in[6] ^ crc_in[7] ^ crc_in[8] ^ crc_in[9] ^ crc_in[11] ^ crc_in[12] ^ crc_in[13] ^ crc_in[21] ^ crc_in[25] ^ crc_in[27] ^ crc_in[28] ^ crc_in[31] ^ data_in[0] ^ data_in[3] ^ data_in[5] ^ data_in[6] ^ data_in[7] ^ data_in[8] ^ data_in[9] ^ data_in[11] ^ data_in[12] ^ data_in[13] ^ data_in[21] ^ data_in[25] ^ data_in[27] ^ data_in[28] ^ data_in[31];
            crc32_next_word[6] = crc_in[0] ^ crc_in[2] ^ crc_in[3] ^ crc_in[9] ^ crc_in[10] ^ crc_in[12] ^ crc_in[13] ^ crc_in[14] ^ crc_in[16] ^ crc_in[20] ^ crc_in[23] ^ crc_in[28] ^ crc_in[29] ^ data_in[0] ^ data_in[2] ^ data_in[3] ^ data_in[9] ^ data_in[10] ^ data_in[12] ^ data_in[13] ^ data_in[14] ^ data_in[16] ^ data_in[20] ^ data_in[23] ^ data_in[28] ^ data_in[29];
            crc32_next_word[7] = crc_in[1] ^ crc_in[3] ^ crc_in[4] ^ crc_in[10] ^ crc_in[11] ^ crc_in[13] ^ crc_in[14] ^ crc_in[15] ^ crc_in[17] ^ crc_in[21] ^ crc_in[24] ^ crc_in[29] ^ crc_in[30] ^ data_in[1] ^ data_in[3] ^ data_in[4] ^ data_in[10] ^ data_in[11] ^ data_in[13] ^ data_in[14] ^ data_in[15] ^ data_in[17] ^ data_in[21] ^ data_in[24] ^ data_in[29] ^ data_in[30];
            crc32_next_word[8] = crc_in[0] ^ crc_in[2] ^ crc_in[4] ^ crc_in[5] ^ crc_in[11] ^ crc_in[12] ^ crc_in[14] ^ crc_in[15] ^ crc_in[16] ^ crc_in[18] ^ crc_in[22] ^ crc_in[25] ^ crc_in[30] ^ crc_in[31] ^ data_in[0] ^ data_in[2] ^ data_in[4] ^ data_in[5] ^ data_in[11] ^ data_in[12] ^ data_in[14] ^ data_in[15] ^ data_in[16] ^ data_in[18] ^ data_in[22] ^ data_in[25] ^ data_in[30] ^ data_in[31];
            crc32_next_word[9] = crc_in[0] ^ crc_in[2] ^ crc_in[4] ^ crc_in[5] ^ crc_in[7] ^ crc_in[8] ^ crc_in[12] ^ crc_in[13] ^ crc_in[15] ^ crc_in[17] ^ crc_in[19] ^ crc_in[20] ^ crc_in[22] ^ crc_in[31] ^ data_in[0] ^ data_in[2] ^ data_in[4] ^ data_in[5] ^ data_in[7] ^ data_in[8] ^ data_in[12] ^ data_in[13] ^ data_in[15] ^ data_in[17] ^ data_in[19] ^ data_in[20] ^ data_in[22] ^ data_in[31];
            crc32_next_word[10] = crc_in[0] ^ crc_in[2] ^ crc_in[4] ^ crc_in[5] ^ crc_in[7] ^ crc_in[9] ^ crc_in[13] ^ crc_in[14] ^ crc_in[18] ^ crc_in[21] ^ crc_in[22] ^ crc_in[26] ^ data_in[0] ^ data_in[2] ^ data_in[4] ^ data_in[5] ^ data_in[7] ^ data_in[9] ^ data_in[13] ^ data_in[14] ^ data_in[18] ^ data_in[21] ^ data_in[22] ^ data_in[26];
            crc32_next_word[11] = crc_in[1] ^ crc_in[3] ^ crc_in[5] ^ crc_in[6] ^ crc_in[8] ^ crc_in[10] ^ crc_in[14] ^ crc_in[15] ^ crc_in[19] ^ crc_in[22] ^ crc_in[23] ^ crc_in[27] ^ data_in[1] ^ data_in[3] ^ data_in[5] ^ data_in[6] ^ data_in[8] ^ data_in[10] ^ data_in[14] ^ data_in[15] ^ data_in[19] ^ data_in[22] ^ data_in[23] ^ data_in[27];
            crc32_next_word[12] = crc_in[2] ^ crc_in[4] ^ crc_in[6] ^ crc_in[7] ^ crc_in[9] ^ crc_in[11] ^ crc_in[15] ^ crc_in[16] ^ crc_in[20] ^ crc_in[23] ^ crc_in[24] ^ crc_in[28] ^ data_in[2] ^ data_in[4] ^ data_in[6] ^ data_in[7] ^ data_in[9] ^ data_in[11] ^ data_in[15] ^ data_in[16] ^ data_in[20] ^ data_in[23] ^ data_in[24] ^ data_in[28];
            crc32_next_word[13] = crc_in[0] ^ crc_in[3] ^ crc_in[5] ^ crc_in[7] ^ crc_in[8] ^ crc_in[10] ^ crc_in[12] ^ crc_in[16] ^ crc_in[17] ^ crc_in[21] ^ crc_in[24] ^ crc_in[25] ^ crc_in[29] ^ data_in[0] ^ data_in[3] ^ data_in[5] ^ data_in[7] ^ data_in[8] ^ data_in[10] ^ data_in[12] ^ data_in[16] ^ data_in[17] ^ data_in[21] ^ data_in[24] ^ data_in[25] ^ data_in[29];
            crc32_next_word[14] = crc_in[0] ^ crc_in[1] ^ crc_in[4] ^ crc_in[6] ^ crc_in[8] ^ crc_in[9] ^ crc_in[11] ^ crc_in[13] ^ crc_in[17] ^ crc_in[18] ^ crc_in[22] ^ crc_in[25] ^ crc_in[26] ^ crc_in[30] ^ data_in[0] ^ data_in[1] ^ data_in[4] ^ data_in[6] ^ data_in[8] ^ data_in[9] ^ data_in[11] ^ data_in[13] ^ data_in[17] ^ data_in[18] ^ data_in[22] ^ data_in[25] ^ data_in[26] ^ data_in[30];
            crc32_next_word[15] = crc_in[1] ^ crc_in[2] ^ crc_in[5] ^ crc_in[7] ^ crc_in[9] ^ crc_in[10] ^ crc_in[12] ^ crc_in[14] ^ crc_in[18] ^ crc_in[19] ^ crc_in[23] ^ crc_in[26] ^ crc_in[27] ^ crc_in[31] ^ data_in[1] ^ data_in[2] ^ data_in[5] ^ data_in[7] ^ data_in[9] ^ data_in[10] ^ data_in[12] ^ data_in[14] ^ data_in[18] ^ data_in[19] ^ data_in[23] ^ data_in[26] ^ data_in[27] ^ data_in[31];
            crc32_next_word[16] = crc_in[1] ^ crc_in[4] ^ crc_in[7] ^ crc_in[10] ^ crc_in[11] ^ crc_in[13] ^ crc_in[15] ^ crc_in[16] ^ crc_in[19] ^ crc_in[22] ^ crc_in[23] ^ crc_in[24] ^ crc_in[26] ^ crc_in[27] ^ crc_in[28] ^ data_in[1] ^ data_in[4] ^ data_in[7] ^ data_in[10] ^ data_in[11] ^ data_in[13] ^ data_in[15] ^ data_in[16] ^ data_in[19] ^ data_in[22] ^ data_in[23] ^ data_in[24] ^ data_in[26] ^ data_in[27] ^ data_in[28];
            crc32_next_word[17] = crc_in[2] ^ crc_in[5] ^ crc_in[8] ^ crc_in[11] ^ crc_in[12] ^ crc_in[14] ^ crc_in[16] ^ crc_in[17] ^ crc_in[20] ^ crc_in[23] ^ crc_in[24] ^ crc_in[25] ^ crc_in[27] ^ crc_in[28] ^ crc_in[29] ^ data_in[2] ^ data_in[5] ^ data_in[8] ^ data_in[11] ^ data_in[12] ^ data_in[14] ^ data_in[16] ^ data_in[17] ^ data_in[20] ^ data_in[23] ^ data_in[24] ^ data_in[25] ^ data_in[27] ^ data_in[28] ^ data_in[29];
            crc32_next_word[18] = crc_in[0] ^ crc_in[3] ^ crc_in[6] ^ crc_in[9] ^ crc_in[12] ^ crc_in[13] ^ crc_in[15] ^ crc_in[17] ^ crc_in[18] ^ crc_in[21] ^ crc_in[24] ^ crc_in[25] ^ crc_in[26] ^ crc_in[28] ^ crc_in[29] ^ crc_in[30] ^ data_in[0] ^ data_in[3] ^ data_in[6] ^ data_in[9] ^ data_in[12] ^ data_in[13] ^ data_in[15] ^ data_in[17] ^ data_in[18] ^ data_in[21] ^ data_in[24] ^ data_in[25] ^ data_in[26] ^ data_in[28] ^ data_in[29] ^ data_in[30];
            crc32_next_word[19] = crc_in[0] ^ crc_in[1] ^ crc_in[4] ^ crc_in[7] ^ crc_in[10] ^ crc_in[13] ^ crc_in[14] ^ crc_in[16] ^ crc_in[18] ^ crc_in[19] ^ crc_in[22] ^ crc_in[25] ^ crc_in[26] ^ crc_in[27] ^ crc_in[29] ^ crc_in[30] ^ crc_in[31] ^ data_in[0] ^ data_in[1] ^ data_in[4] ^ data_in[7] ^ data_in[10] ^ data_in[13] ^ data_in[14] ^ data_in[16] ^ data_in[18] ^ data_in[19] ^ data_in[22] ^ data_in[25] ^ data_in[26] ^ data_in[27] ^ data_in[29] ^ data_in[30] ^ data_in[31];
            crc32_next_word[20] = crc_in[0] ^ crc_in[3] ^ crc_in[4] ^ crc_in[5] ^ crc_in[6] ^ crc_in[7] ^ crc_in[11] ^ crc_in[14] ^ crc_in[15] ^ crc_in[16] ^ crc_in[17] ^ crc_in[19] ^ crc_in[22] ^ crc_in[27] ^ crc_in[28] ^ crc_in[30] ^ crc_in[31] ^ data_in[0] ^ data_in[3] ^ data_in[4] ^ data_in[5] ^ data_in[6] ^ data_in[7] ^ data_in[11] ^ data_in[14] ^ data_in[15] ^ data_in[16] ^ data_in[17] ^ data_in[19] ^ data_in[22] ^ data_in[27] ^ data_in[28] ^ data_in[30] ^ data_in[31];
            crc32_next_word[21] = crc_in[0] ^ crc_in[2] ^ crc_in[3] ^ crc_in[5] ^ crc_in[12] ^ crc_in[15] ^ crc_in[17] ^ crc_in[18] ^ crc_in[22] ^ crc_in[26] ^ crc_in[28] ^ crc_in[29] ^ crc_in[31] ^ data_in[0] ^ data_in[2] ^ data_in[3] ^ data_in[5] ^ data_in[12] ^ data_in[15] ^ data_in[17] ^ data_in[18] ^ data_in[22] ^ data_in[26] ^ data_in[28] ^ data_in[29] ^ data_in[31];
            crc32_next_word[22] = crc_in[2] ^ crc_in[7] ^ crc_in[8] ^ crc_in[13] ^ crc_in[18] ^ crc_in[19] ^ crc_in[20] ^ crc_in[22] ^ crc_in[26] ^ crc_in[27] ^ crc_in[29] ^ crc_in[30] ^ data_in[2] ^ data_in[7] ^ data_in[8] ^ data_in[13] ^ data_in[18] ^ data_in[19] ^ data_in[20] ^ data_in[22] ^ data_in[26] ^ data_in[27] ^ data_in[29] ^ data_in[30];
            crc32_next_word[23] = crc_in[0] ^ crc_in[3] ^ crc_in[8] ^ crc_in[9] ^ crc_in[14] ^ crc_in[19] ^ crc_in[20] ^ crc_in[21] ^ crc_in[23] ^ crc_in[27] ^ crc_in[28] ^ crc_in[30] ^ crc_in[31] ^ data_in[0] ^ data_in[3] ^ data_in[8] ^ data_in[9] ^ data_in[14] ^ data_in[19] ^ data_in[20] ^ data_in[21] ^ data_in[23] ^ data_in[27] ^ data_in[28] ^ data_in[30] ^ data_in[31];
            crc32_next_word[24] = crc_in[2] ^ crc_in[3] ^ crc_in[6] ^ crc_in[7] ^ crc_in[8] ^ crc_in[9] ^ crc_in[10] ^ crc_in[15] ^ crc_in[16] ^ crc_in[21] ^ crc_in[23] ^ crc_in[24] ^ crc_in[26] ^ crc_in[28] ^ crc_in[29] ^ crc_in[31] ^ data_in[2] ^ data_in[3] ^ data_in[6] ^ data_in[7] ^ data_in[8] ^ data_in[9] ^ data_in[10] ^ data_in[15] ^ data_in[16] ^ data_in[21] ^ data_in[23] ^ data_in[24] ^ data_in[26] ^ data_in[28] ^ data_in[29] ^ data_in[31];
            crc32_next_word[25] = crc_in[1] ^ crc_in[2] ^ crc_in[6] ^ crc_in[9] ^ crc_in[10] ^ crc_in[11] ^ crc_in[17] ^ crc_in[20] ^ crc_in[23] ^ crc_in[24] ^ crc_in[25] ^ crc_in[26] ^ crc_in[27] ^ crc_in[29] ^ crc_in[30] ^ data_in[1] ^ data_in[2] ^ data_in[6] ^ data_in[9] ^ data_in[10] ^ data_in[11] ^ data_in[17] ^ data_in[20] ^ data_in[23] ^ data_in[24] ^ data_in[25] ^ data_in[26] ^ data_in[27] ^ data_in[29] ^ data_in[30];
            crc32_next_word[26] = crc_in[2] ^ crc_in[3] ^ crc_in[7] ^ crc_in[10] ^ crc_in[11] ^ crc_in[12] ^ crc_in[18] ^ crc_in[21] ^ crc_in[24] ^ crc_in[25] ^ crc_in[26] ^ crc_in[27] ^ crc_in[28] ^ crc_in[30] ^ crc_in[31] ^ data_in[2] ^ data_in[3] ^ data_in[7] ^ data_in[10] ^ data_in[11] ^ data_in[12] ^ data_in[18] ^ data_in[21] ^ data_in[24] ^ data_in[25] ^ data_in[26] ^ data_in[27] ^ data_in[28] ^ data_in[30] ^ data_in[31];
            crc32_next_word[27] = crc_in[0] ^ crc_in[1] ^ crc_in[2] ^ crc_in[6] ^ crc_in[7] ^ crc_in[11] ^ crc_in[12] ^ crc_in[13] ^ crc_in[16] ^ crc_in[19] ^ crc_in[20] ^ crc_in[23] ^ crc_in[25] ^ crc_in[27] ^ crc_in[28] ^ crc_in[29] ^ crc_in[31] ^ data_in[0] ^ data_in[1] ^ data_in[2] ^ data_in[6] ^ data_in[7] ^ data_in[11] ^ data_in[12] ^ data_in[13] ^ data_in[16] ^ data_in[19] ^ data_in[20] ^ data_in[23] ^ data_in[25] ^ data_in[27] ^ data_in[28] ^ data_in[29] ^ data_in[31];
            crc32_next_word[28] = crc_in[0] ^ crc_in[4] ^ crc_in[6] ^ crc_in[12] ^ crc_in[13] ^ crc_in[14] ^ crc_in[16] ^ crc_in[17] ^ crc_in[21] ^ crc_in[22] ^ crc_in[23] ^ crc_in[24] ^ crc_in[28] ^ crc_in[29] ^ crc_in[30] ^ data_in[0] ^ data_in[4] ^ data_in[6] ^ data_in[12] ^ data_in[13] ^ data_in[14] ^ data_in[16] ^ data_in[17] ^ data_in[21] ^ data_in[22] ^ data_in[23] ^ data_in[24] ^ data_in[28] ^ data_in[29] ^ data_in[30];
            crc32_next_word[29] = crc_in[0] ^ crc_in[1] ^ crc_in[5] ^ crc_in[7] ^ crc_in[13] ^ crc_in[14] ^ crc_in[15] ^ crc_in[17] ^ crc_in[18] ^ crc_in[22] ^ crc_in[23] ^ crc_in[24] ^ crc_in[25] ^ crc_in[29] ^ crc_in[30] ^ crc_in[31] ^ data_in[0] ^ data_in[1] ^ data_in[5] ^ data_in[7] ^ data_in[13] ^ data_in[14] ^ data_in[15] ^ data_in[17] ^ data_in[18] ^ data_in[22] ^ data_in[23] ^ data_in[24] ^ data_in[25] ^ data_in[29] ^ data_in[30] ^ data_in[31];
            crc32_next_word[30] = crc_in[3] ^ crc_in[4] ^ crc_in[7] ^ crc_in[14] ^ crc_in[15] ^ crc_in[18] ^ crc_in[19] ^ crc_in[20] ^ crc_in[22] ^ crc_in[24] ^ crc_in[25] ^ crc_in[30] ^ crc_in[31] ^ data_in[3] ^ data_in[4] ^ data_in[7] ^ data_in[14] ^ data_in[15] ^ data_in[18] ^ data_in[19] ^ data_in[20] ^ data_in[22] ^ data_in[24] ^ data_in[25] ^ data_in[30] ^ data_in[31];
            crc32_next_word[31] = crc_in[0] ^ crc_in[1] ^ crc_in[2] ^ crc_in[3] ^ crc_in[5] ^ crc_in[6] ^ crc_in[7] ^ crc_in[15] ^ crc_in[19] ^ crc_in[21] ^ crc_in[22] ^ crc_in[25] ^ crc_in[31] ^ data_in[0] ^ data_in[1] ^ data_in[2] ^ data_in[3] ^ data_in[5] ^ data_in[6] ^ data_in[7] ^ data_in[15] ^ data_in[19] ^ data_in[21] ^ data_in[22] ^ data_in[25] ^ data_in[31];
        end
    endfunction

    function [31:0] crc32_next_2words;
        input [31:0] crc_in;
        input [31:0] word0;
        input [31:0] word1;
        reg [31:0] crc1;
        begin
            crc1 = crc32_next_word(crc_in, word0);
            crc32_next_2words = crc32_next_word(crc1, word1);
        end
    endfunction

    // Convert the internal 66-bit C matrix into the contest result format:
    // low 32 bits, high 32 bits, then the top 2 bits zero-extended to 32 bits.
    function [31:0] mm_result_word;
        input [5:0] word_index;
        begin
            case (word_index)
                6'd0:  mm_result_word = mm_c[0][31:0];
                6'd1:  mm_result_word = mm_c[0][63:32];
                6'd2:  mm_result_word = {30'b0, mm_c[0][65:64]};
                6'd3:  mm_result_word = mm_c[1][31:0];
                6'd4:  mm_result_word = mm_c[1][63:32];
                6'd5:  mm_result_word = {30'b0, mm_c[1][65:64]};
                6'd6:  mm_result_word = mm_c[2][31:0];
                6'd7:  mm_result_word = mm_c[2][63:32];
                6'd8:  mm_result_word = {30'b0, mm_c[2][65:64]};
                6'd9:  mm_result_word = mm_c[3][31:0];
                6'd10: mm_result_word = mm_c[3][63:32];
                6'd11: mm_result_word = {30'b0, mm_c[3][65:64]};
                6'd12: mm_result_word = mm_c[4][31:0];
                6'd13: mm_result_word = mm_c[4][63:32];
                6'd14: mm_result_word = {30'b0, mm_c[4][65:64]};
                6'd15: mm_result_word = mm_c[5][31:0];
                6'd16: mm_result_word = mm_c[5][63:32];
                6'd17: mm_result_word = {30'b0, mm_c[5][65:64]};
                6'd18: mm_result_word = mm_c[6][31:0];
                6'd19: mm_result_word = mm_c[6][63:32];
                6'd20: mm_result_word = {30'b0, mm_c[6][65:64]};
                6'd21: mm_result_word = mm_c[7][31:0];
                6'd22: mm_result_word = mm_c[7][63:32];
                6'd23: mm_result_word = {30'b0, mm_c[7][65:64]};
                6'd24: mm_result_word = mm_c[8][31:0];
                6'd25: mm_result_word = mm_c[8][63:32];
                6'd26: mm_result_word = {30'b0, mm_c[8][65:64]};
                6'd27: mm_result_word = mm_c[9][31:0];
                6'd28: mm_result_word = mm_c[9][63:32];
                6'd29: mm_result_word = {30'b0, mm_c[9][65:64]};
                6'd30: mm_result_word = mm_c[10][31:0];
                6'd31: mm_result_word = mm_c[10][63:32];
                6'd32: mm_result_word = {30'b0, mm_c[10][65:64]};
                6'd33: mm_result_word = mm_c[11][31:0];
                6'd34: mm_result_word = mm_c[11][63:32];
                6'd35: mm_result_word = {30'b0, mm_c[11][65:64]};
                6'd36: mm_result_word = mm_c[12][31:0];
                6'd37: mm_result_word = mm_c[12][63:32];
                6'd38: mm_result_word = {30'b0, mm_c[12][65:64]};
                6'd39: mm_result_word = mm_c[13][31:0];
                6'd40: mm_result_word = mm_c[13][63:32];
                6'd41: mm_result_word = {30'b0, mm_c[13][65:64]};
                6'd42: mm_result_word = mm_c[14][31:0];
                6'd43: mm_result_word = mm_c[14][63:32];
                6'd44: mm_result_word = {30'b0, mm_c[14][65:64]};
                6'd45: mm_result_word = mm_c[15][31:0];
                6'd46: mm_result_word = mm_c[15][63:32];
                6'd47: mm_result_word = {30'b0, mm_c[15][65:64]};
                default: mm_result_word = 32'd0;
            endcase
        end
    endfunction

    function [31:0] mm_out_word;
        input slot;
        input [5:0] word_index;
        begin
            if (slot == 1'b0) begin
                mm_out_word = mm_out0[word_index];
            end
            else begin
                mm_out_word = mm_out1[word_index];
            end
        end
    endfunction

    function [65:0] mm_addend3;
        input [1:0] row;
        input [1:0] col;
        reg [2:0] b_triplet;
        reg [31:0] b_word;
        begin
            b_word = mm_b[{mm_calc_k, col}];
            if (mm_calc_bit == 5'd30) begin
                b_triplet = {1'b0, b_word[31], b_word[30]};
            end
            else begin
                b_triplet = {
                    b_word[mm_calc_bit + 5'd2],
                    b_word[mm_calc_bit + 5'd1],
                    b_word[mm_calc_bit]
                };
            end

            case (b_triplet)
                3'd0: mm_addend3 = 66'd0;
                3'd1: mm_addend3 = mm_a_shift[row];
                3'd2: mm_addend3 = mm_a_shift2[row];
                3'd3: mm_addend3 = mm_a_shift3[row];
                3'd4: mm_addend3 = mm_a_shift4[row];
                3'd5: mm_addend3 = mm_a_shift5[row];
                3'd6: mm_addend3 = mm_a_shift6[row];
                default: mm_addend3 = mm_a_shift7[row];
            endcase
        end
    endfunction

    task mm_load_row_multiples;
        input [1:0] row;
        input [31:0] a_word;
        reg [65:0] x1;
        reg [65:0] x2;
        reg [65:0] x3;
        reg [65:0] x4;
        begin
            x1 = {34'd0, a_word};
            x2 = {33'd0, a_word, 1'b0};
            x3 = x1 + x2;
            x4 = {32'd0, a_word, 2'b0};
            mm_a_shift[row] <= x1;
            mm_a_shift2[row] <= x2;
            mm_a_shift3[row] <= x3;
            mm_a_shift4[row] <= x4;
            mm_a_shift5[row] <= x1 + x4;
            mm_a_shift6[row] <= x2 + x4;
            mm_a_shift7[row] <= x3 + x4;
        end
    endtask

    always @(posedge aclk) begin
        if (~aresetn) begin
            axi_busy <= 1'b0;
        end
        else if (ar_enter | aw_enter) begin
            axi_busy <= 1'b1;
        end
        else if (r_retire | b_retire) begin
            axi_busy <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            axi_r_or_w <= 1'b0;
            buf_id <= 5'b0;
            buf_addr <= 32'b0;
            buf_len <= 8'b0;
            buf_size <= 3'b0;
            buf_burst <= 2'b0;
            buf_lock <= 1'b0;
            buf_cache <= 4'b0;
            buf_prot <= 3'b0;
        end
        else if (ar_enter | aw_enter) begin
            axi_r_or_w <= ar_enter;
            buf_id <= ar_enter ? s_arid : s_awid;
            buf_addr <= ar_enter ? s_araddr : s_awaddr;
            buf_len <= ar_enter ? s_arlen : s_awlen;
            buf_size <= ar_enter ? s_arsize : s_awsize;
            buf_burst <= ar_enter ? s_arburst : s_awburst;
            buf_lock <= ar_enter ? s_arlock : s_awlock;
            buf_cache <= ar_enter ? s_arcache : s_awcache;
            buf_prot <= ar_enter ? s_arprot : s_awprot;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            axi_write <= 1'b0;
        end
        else if (aw_enter) begin
            axi_write <= 1'b1;
        end
        else if (ar_enter) begin
            axi_write <= 1'b0;
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
            s_rdata_r <= 32'b0;
            s_rvalid_r <= 1'b0;
            s_rlast_r <= 1'b0;
        end
        else if (axi_busy & !axi_write & !r_retire) begin
            s_rdata_r <= rdata_d;
            s_rvalid_r <= 1'b1;
            s_rlast_r <= 1'b1;
        end
        else if (r_retire) begin
            s_rvalid_r <= 1'b0;
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
        if (!aresetn) begin
            dma_src_addr <= 32'd0;
            dma_dst_addr <= 32'd0;
            dma_len_cfg <= 32'd0;
            dma_cur_src <= 32'd0;
            dma_cur_dst <= 32'd0;
            dma_remain <= 32'd0;
            dma_busy <= 1'b0;
            dma_done <= 1'b0;
            dma_error <= 1'b0;
            dma_state <= M_IDLE;
            matmul_crc_only <= 1'b0;
            dma_finish <= 1'b0;
            m_arvalid_r <= 1'b0;
            m_araddr_r <= 32'd0;
            m_arlen_r <= 8'd0;
            m_rready_r <= 1'b0;
            m_awvalid_r <= 1'b0;
            m_awaddr_r <= 32'd0;
            m_awlen_r <= 8'd0;
            m_wvalid_r <= 1'b0;
            m_wdata_r <= 32'd0;
            m_wlast_r <= 1'b0;
            m_bready_r <= 1'b0;
            dma_burst_words <= 8'd0;
            dma_rd_cnt <= 8'd0;
            dma_wr_cnt <= 8'd0;
            dma_src_burst_en <= 1'b0;
            dma_dst_burst_en <= 1'b0;
            stream_rd_state <= RD_IDLE;
            stream_wr_state <= WR_IDLE;
            stream_rd_beats <= 8'd0;
            stream_wr_beats <= 8'd0;
            stream_fifo_wr_ptr <= 7'd0;
            stream_fifo_rd_ptr <= 7'd0;
            stream_fifo_count <= 8'd0;
            stream_rd_addr <= 32'd0;
            stream_wr_addr <= 32'd0;
            stream_rd_remain <= 32'd0;
            stream_wr_remain <= 32'd0;
            matmul_crc <= 32'd0;
            mm_crc_state <= 32'hffff_ffff;
            mm_groups_left <= 32'd0;
            mm_read_left <= 32'd0;
            mm_rd_cnt <= 6'd0;
            mm_rd_state <= RD_IDLE;
            mm_wr_state <= WR_IDLE;
            mm_calc_state <= MM_CALC_IDLE;
            mm_rd_slot <= 1'b0;
            mm_calc_in_slot <= 1'b0;
            mm_calc_out_slot <= 1'b0;
            mm_wr_slot <= 1'b0;
            mm_in0_valid <= 1'b0;
            mm_in1_valid <= 1'b0;
            mm_out0_valid <= 1'b0;
            mm_out1_valid <= 1'b0;
            mm_calc_k <= 2'd0;
            mm_calc_bit <= 5'd0;
            mm_wr_cnt <= 6'd0;
            for (i = 0; i < 16; i = i + 1) begin
                mm_a[i] <= 32'd0;
                mm_b[i] <= 32'd0;
                mm_c[i] <= 66'd0;
            end
            for (i = 0; i < 4; i = i + 1) begin
                mm_a_shift[i] <= 66'd0;
                mm_a_shift2[i] <= 66'd0;
                mm_a_shift3[i] <= 66'd0;
                mm_a_shift4[i] <= 66'd0;
                mm_a_shift5[i] <= 66'd0;
                mm_a_shift6[i] <= 66'd0;
                mm_a_shift7[i] <= 66'd0;
            end
        end
        else begin
            dma_finish <= 1'b0;

            if (write_src) begin
                dma_src_addr <= s_wdata;
            end
            if (write_dst) begin
                dma_dst_addr <= s_wdata;
            end
            if (write_len) begin
                dma_len_cfg <= s_wdata;
            end
            if (ctrl_clr_done) begin
                dma_done <= 1'b0;
            end

            case (dma_state)
                M_IDLE: begin
                    if (ctrl_start & ~dma_busy) begin
                        m_arvalid_r <= 1'b0;
                        m_rready_r <= 1'b0;
                        m_awvalid_r <= 1'b0;
                        m_wvalid_r <= 1'b0;
                        m_bready_r <= 1'b0;
                        m_wlast_r <= 1'b0;
                        dma_rd_cnt <= 8'd0;
                        dma_wr_cnt <= 8'd0;

                        if (ctrl_matmul) begin
                            // Batch matmul mode: SRC points to A/B groups, DST points
                            // to the packed C result area, LEN is number of groups.
                            if (matmul_cfg_invalid) begin
                                dma_busy <= 1'b0;
                                dma_done <= 1'b1;
                                dma_error <= 1'b1;
                                dma_finish <= 1'b1;
                            end
                            else begin
                                dma_busy <= 1'b1;
                                dma_done <= 1'b0;
                                dma_error <= 1'b0;
                                matmul_crc_only <= ctrl_matmul_crc_only;
                                dma_cur_src <= dma_src_addr;
                                dma_cur_dst <= dma_dst_addr;
                                dma_remain <= dma_len_cfg;
                                matmul_crc <= 32'd0;
                                mm_crc_state <= 32'hffff_ffff;
                                mm_groups_left <= dma_len_cfg;
                                mm_read_left <= dma_len_cfg;
                                mm_rd_cnt <= 6'd0;
                                mm_rd_state <= RD_IDLE;
                                mm_wr_state <= WR_IDLE;
                                mm_calc_state <= MM_CALC_IDLE;
                                mm_rd_slot <= 1'b0;
                                mm_calc_in_slot <= 1'b0;
                                mm_calc_out_slot <= 1'b0;
                                mm_wr_slot <= 1'b0;
                                mm_in0_valid <= 1'b0;
                                mm_in1_valid <= 1'b0;
                                mm_out0_valid <= 1'b0;
                                mm_out1_valid <= 1'b0;
                                mm_calc_k <= 2'd0;
                                mm_calc_bit <= 5'd0;
                                mm_wr_cnt <= 6'd0;
                                m_araddr_r <= 32'd0;
                                m_arlen_r <= 8'd0;
                                m_arvalid_r <= 1'b0;
                                m_rready_r <= 1'b0;
                                dma_state <= M_MM_PIPE;
                            end
                        end
                        else if (cfg_invalid) begin
                            dma_busy <= 1'b0;
                            dma_done <= 1'b1;
                            dma_error <= 1'b1;
                            dma_finish <= 1'b1;
                            matmul_crc_only <= 1'b0;
                        end
                        else if (stream_cfg) begin
                            dma_busy <= 1'b1;
                            dma_done <= 1'b0;
                            dma_error <= 1'b0;
                            matmul_crc_only <= 1'b0;
                            dma_cur_src <= dma_src_addr;
                            dma_cur_dst <= dma_dst_addr;
                            dma_remain <= dma_len_cfg;
                            stream_rd_addr <= dma_src_addr;
                            stream_wr_addr <= dma_dst_addr;
                            stream_rd_remain <= (dma_len_cfg >> 2);
                            stream_wr_remain <= (dma_len_cfg >> 2);
                            stream_fifo_wr_ptr <= 7'd0;
                            stream_fifo_rd_ptr <= 7'd0;
                            stream_fifo_count <= 8'd0;
                            stream_rd_state <= RD_IDLE;
                            stream_wr_state <= WR_IDLE;
                            stream_rd_beats <= 8'd0;
                            stream_wr_beats <= 8'd0;
                            dma_src_burst_en <= src_burst_allow_cfg;
                            dma_dst_burst_en <= dst_burst_allow_cfg;
                            dma_state <= M_STREAM;
                        end
                        else begin
                            dma_busy <= 1'b1;
                            dma_done <= 1'b0;
                            dma_error <= 1'b0;
                            matmul_crc_only <= 1'b0;
                            dma_cur_src <= dma_src_addr;
                            dma_cur_dst <= dma_dst_addr;
                            dma_remain <= dma_len_cfg;
                            m_araddr_r <= dma_src_addr;
                            dma_burst_words <= dma_words_from_len;
                            dma_src_burst_en <= src_burst_allow_cfg;
                            dma_dst_burst_en <= dst_burst_allow_cfg;
                            m_arlen_r <= src_burst_allow_cfg ? ({1'b0, dma_words_from_len} - 8'd1) : 8'd0;
                            m_arvalid_r <= 1'b1;
                            m_rready_r <= 1'b0;
                            dma_state <= M_AR;
                        end
                    end
                end

                M_MM_PIPE: begin
                    case (mm_rd_state)
                        RD_IDLE: begin
                            if ((mm_read_left != 32'd0) && (mm_read_slot0_free || mm_read_slot1_free)) begin
                                mm_rd_slot <= mm_read_slot0_free ? 1'b0 : 1'b1;
                                mm_rd_cnt <= 6'd0;
                                m_araddr_r <= dma_cur_src;
                                m_arlen_r <= 8'd31;
                                m_arvalid_r <= 1'b1;
                                mm_rd_state <= RD_AR;
                            end
                        end
                        RD_AR: begin
                            if (m_ar_fire) begin
                                m_arvalid_r <= 1'b0;
                                m_rready_r <= 1'b1;
                                mm_rd_state <= RD_R;
                            end
                        end
                        RD_R: begin
                            if (m_r_fire) begin
                                if (m_rresp != 2'b00) begin
                                    m_rready_r <= 1'b0;
                                    m_arvalid_r <= 1'b0;
                                    m_awvalid_r <= 1'b0;
                                    m_wvalid_r <= 1'b0;
                                    m_bready_r <= 1'b0;
                                    m_wlast_r <= 1'b0;
                                    dma_busy <= 1'b0;
                                    dma_done <= 1'b1;
                                    dma_error <= 1'b1;
                                    dma_finish <= 1'b1;
                                    mm_rd_state <= RD_IDLE;
                                    mm_wr_state <= WR_IDLE;
                                    mm_calc_state <= MM_CALC_IDLE;
                                    dma_state <= M_IDLE;
                                end
                                else begin
                                    if (mm_rd_slot == 1'b0) begin
                                        mm_in0[mm_rd_cnt] <= m_rdata;
                                    end
                                    else begin
                                        mm_in1[mm_rd_cnt] <= m_rdata;
                                    end
                                    dma_cur_src <= dma_cur_src + 32'd4;
                                    if (mm_rd_cnt == 6'd31) begin
                                        m_rready_r <= 1'b0;
                                        mm_rd_cnt <= 6'd0;
                                        mm_read_left <= mm_read_left - 32'd1;
                                        if (mm_rd_slot == 1'b0) begin
                                            mm_in0_valid <= 1'b1;
                                        end
                                        else begin
                                            mm_in1_valid <= 1'b1;
                                        end
                                        mm_rd_state <= RD_IDLE;
                                    end
                                    else begin
                                        mm_rd_cnt <= mm_rd_cnt + 6'd1;
                                    end
                                end
                            end
                        end
                        default: begin
                            mm_rd_state <= RD_IDLE;
                        end
                    endcase

                    case (mm_calc_state)
                        MM_CALC_IDLE: begin
                            if ((mm_in0_valid || mm_in1_valid) && (mm_output_slot0_free || mm_output_slot1_free)) begin
                                mm_calc_in_slot <= mm_in0_valid ? 1'b0 : 1'b1;
                                mm_calc_out_slot <= mm_output_slot0_free ? 1'b0 : 1'b1;
                                mm_calc_k <= 2'd0;
                                mm_calc_bit <= 5'd0;
                                for (i = 0; i < 16; i = i + 1) begin
                                    mm_c[i] <= 66'd0;
                                end

                                if (mm_in0_valid) begin
                                    for (i = 0; i < 16; i = i + 1) begin
                                        mm_a[i] <= mm_in0[i];
                                        mm_b[i] <= mm_in0[i + 16];
                                    end
                                    mm_load_row_multiples(2'd0, mm_in0[0]);
                                    mm_load_row_multiples(2'd1, mm_in0[4]);
                                    mm_load_row_multiples(2'd2, mm_in0[8]);
                                    mm_load_row_multiples(2'd3, mm_in0[12]);
                                    mm_in0_valid <= 1'b0;
                                end
                                else begin
                                    for (i = 0; i < 16; i = i + 1) begin
                                        mm_a[i] <= mm_in1[i];
                                        mm_b[i] <= mm_in1[i + 16];
                                    end
                                    mm_load_row_multiples(2'd0, mm_in1[0]);
                                    mm_load_row_multiples(2'd1, mm_in1[4]);
                                    mm_load_row_multiples(2'd2, mm_in1[8]);
                                    mm_load_row_multiples(2'd3, mm_in1[12]);
                                    mm_in1_valid <= 1'b0;
                                end
                                mm_calc_state <= MM_CALC_RUN;
                            end
                        end
                        MM_CALC_RUN: begin
                            mm_c[0] <= mm_c[0] + mm_addend3(2'd0, 2'd0);
                            mm_c[1] <= mm_c[1] + mm_addend3(2'd0, 2'd1);
                            mm_c[2] <= mm_c[2] + mm_addend3(2'd0, 2'd2);
                            mm_c[3] <= mm_c[3] + mm_addend3(2'd0, 2'd3);
                            mm_c[4] <= mm_c[4] + mm_addend3(2'd1, 2'd0);
                            mm_c[5] <= mm_c[5] + mm_addend3(2'd1, 2'd1);
                            mm_c[6] <= mm_c[6] + mm_addend3(2'd1, 2'd2);
                            mm_c[7] <= mm_c[7] + mm_addend3(2'd1, 2'd3);
                            mm_c[8] <= mm_c[8] + mm_addend3(2'd2, 2'd0);
                            mm_c[9] <= mm_c[9] + mm_addend3(2'd2, 2'd1);
                            mm_c[10] <= mm_c[10] + mm_addend3(2'd2, 2'd2);
                            mm_c[11] <= mm_c[11] + mm_addend3(2'd2, 2'd3);
                            mm_c[12] <= mm_c[12] + mm_addend3(2'd3, 2'd0);
                            mm_c[13] <= mm_c[13] + mm_addend3(2'd3, 2'd1);
                            mm_c[14] <= mm_c[14] + mm_addend3(2'd3, 2'd2);
                            mm_c[15] <= mm_c[15] + mm_addend3(2'd3, 2'd3);

                            if ((mm_calc_k == 2'd3) && (mm_calc_bit == 5'd30)) begin
                                mm_calc_state <= MM_CALC_STORE;
                            end
                            else if (mm_calc_bit == 5'd30) begin
                                mm_calc_bit <= 5'd0;
                                mm_calc_k <= mm_calc_next_k;
                                case (mm_calc_next_k)
                                    2'd1: begin
                                        mm_load_row_multiples(2'd0, mm_a[1]);
                                        mm_load_row_multiples(2'd1, mm_a[5]);
                                        mm_load_row_multiples(2'd2, mm_a[9]);
                                        mm_load_row_multiples(2'd3, mm_a[13]);
                                    end
                                    2'd2: begin
                                        mm_load_row_multiples(2'd0, mm_a[2]);
                                        mm_load_row_multiples(2'd1, mm_a[6]);
                                        mm_load_row_multiples(2'd2, mm_a[10]);
                                        mm_load_row_multiples(2'd3, mm_a[14]);
                                    end
                                    default: begin
                                        mm_load_row_multiples(2'd0, mm_a[3]);
                                        mm_load_row_multiples(2'd1, mm_a[7]);
                                        mm_load_row_multiples(2'd2, mm_a[11]);
                                        mm_load_row_multiples(2'd3, mm_a[15]);
                                    end
                                endcase
                            end
                            else begin
                                mm_calc_bit <= mm_calc_pair_next;
                                for (i = 0; i < 4; i = i + 1) begin
                                    mm_a_shift[i] <= {mm_a_shift[i][62:0], 3'b0};
                                    mm_a_shift2[i] <= {mm_a_shift2[i][62:0], 3'b0};
                                    mm_a_shift3[i] <= {mm_a_shift3[i][62:0], 3'b0};
                                    mm_a_shift4[i] <= {mm_a_shift4[i][62:0], 3'b0};
                                    mm_a_shift5[i] <= {mm_a_shift5[i][62:0], 3'b0};
                                    mm_a_shift6[i] <= {mm_a_shift6[i][62:0], 3'b0};
                                    mm_a_shift7[i] <= {mm_a_shift7[i][62:0], 3'b0};
                                end
                            end
                        end
                        MM_CALC_STORE: begin
                            if (mm_calc_out_slot == 1'b0) begin
                                mm_out0[0] <= mm_result_word(6'd0);
                                mm_out0[1] <= mm_result_word(6'd1);
                                mm_out0[2] <= mm_result_word(6'd2);
                                mm_out0[3] <= mm_result_word(6'd3);
                                mm_out0[4] <= mm_result_word(6'd4);
                                mm_out0[5] <= mm_result_word(6'd5);
                                mm_out0[6] <= mm_result_word(6'd6);
                                mm_out0[7] <= mm_result_word(6'd7);
                                mm_out0[8] <= mm_result_word(6'd8);
                                mm_out0[9] <= mm_result_word(6'd9);
                                mm_out0[10] <= mm_result_word(6'd10);
                                mm_out0[11] <= mm_result_word(6'd11);
                                mm_out0[12] <= mm_result_word(6'd12);
                                mm_out0[13] <= mm_result_word(6'd13);
                                mm_out0[14] <= mm_result_word(6'd14);
                                mm_out0[15] <= mm_result_word(6'd15);
                                mm_out0[16] <= mm_result_word(6'd16);
                                mm_out0[17] <= mm_result_word(6'd17);
                                mm_out0[18] <= mm_result_word(6'd18);
                                mm_out0[19] <= mm_result_word(6'd19);
                                mm_out0[20] <= mm_result_word(6'd20);
                                mm_out0[21] <= mm_result_word(6'd21);
                                mm_out0[22] <= mm_result_word(6'd22);
                                mm_out0[23] <= mm_result_word(6'd23);
                                mm_out0[24] <= mm_result_word(6'd24);
                                mm_out0[25] <= mm_result_word(6'd25);
                                mm_out0[26] <= mm_result_word(6'd26);
                                mm_out0[27] <= mm_result_word(6'd27);
                                mm_out0[28] <= mm_result_word(6'd28);
                                mm_out0[29] <= mm_result_word(6'd29);
                                mm_out0[30] <= mm_result_word(6'd30);
                                mm_out0[31] <= mm_result_word(6'd31);
                                mm_out0[32] <= mm_result_word(6'd32);
                                mm_out0[33] <= mm_result_word(6'd33);
                                mm_out0[34] <= mm_result_word(6'd34);
                                mm_out0[35] <= mm_result_word(6'd35);
                                mm_out0[36] <= mm_result_word(6'd36);
                                mm_out0[37] <= mm_result_word(6'd37);
                                mm_out0[38] <= mm_result_word(6'd38);
                                mm_out0[39] <= mm_result_word(6'd39);
                                mm_out0[40] <= mm_result_word(6'd40);
                                mm_out0[41] <= mm_result_word(6'd41);
                                mm_out0[42] <= mm_result_word(6'd42);
                                mm_out0[43] <= mm_result_word(6'd43);
                                mm_out0[44] <= mm_result_word(6'd44);
                                mm_out0[45] <= mm_result_word(6'd45);
                                mm_out0[46] <= mm_result_word(6'd46);
                                mm_out0[47] <= mm_result_word(6'd47);
                            end
                            else begin
                                mm_out1[0] <= mm_result_word(6'd0);
                                mm_out1[1] <= mm_result_word(6'd1);
                                mm_out1[2] <= mm_result_word(6'd2);
                                mm_out1[3] <= mm_result_word(6'd3);
                                mm_out1[4] <= mm_result_word(6'd4);
                                mm_out1[5] <= mm_result_word(6'd5);
                                mm_out1[6] <= mm_result_word(6'd6);
                                mm_out1[7] <= mm_result_word(6'd7);
                                mm_out1[8] <= mm_result_word(6'd8);
                                mm_out1[9] <= mm_result_word(6'd9);
                                mm_out1[10] <= mm_result_word(6'd10);
                                mm_out1[11] <= mm_result_word(6'd11);
                                mm_out1[12] <= mm_result_word(6'd12);
                                mm_out1[13] <= mm_result_word(6'd13);
                                mm_out1[14] <= mm_result_word(6'd14);
                                mm_out1[15] <= mm_result_word(6'd15);
                                mm_out1[16] <= mm_result_word(6'd16);
                                mm_out1[17] <= mm_result_word(6'd17);
                                mm_out1[18] <= mm_result_word(6'd18);
                                mm_out1[19] <= mm_result_word(6'd19);
                                mm_out1[20] <= mm_result_word(6'd20);
                                mm_out1[21] <= mm_result_word(6'd21);
                                mm_out1[22] <= mm_result_word(6'd22);
                                mm_out1[23] <= mm_result_word(6'd23);
                                mm_out1[24] <= mm_result_word(6'd24);
                                mm_out1[25] <= mm_result_word(6'd25);
                                mm_out1[26] <= mm_result_word(6'd26);
                                mm_out1[27] <= mm_result_word(6'd27);
                                mm_out1[28] <= mm_result_word(6'd28);
                                mm_out1[29] <= mm_result_word(6'd29);
                                mm_out1[30] <= mm_result_word(6'd30);
                                mm_out1[31] <= mm_result_word(6'd31);
                                mm_out1[32] <= mm_result_word(6'd32);
                                mm_out1[33] <= mm_result_word(6'd33);
                                mm_out1[34] <= mm_result_word(6'd34);
                                mm_out1[35] <= mm_result_word(6'd35);
                                mm_out1[36] <= mm_result_word(6'd36);
                                mm_out1[37] <= mm_result_word(6'd37);
                                mm_out1[38] <= mm_result_word(6'd38);
                                mm_out1[39] <= mm_result_word(6'd39);
                                mm_out1[40] <= mm_result_word(6'd40);
                                mm_out1[41] <= mm_result_word(6'd41);
                                mm_out1[42] <= mm_result_word(6'd42);
                                mm_out1[43] <= mm_result_word(6'd43);
                                mm_out1[44] <= mm_result_word(6'd44);
                                mm_out1[45] <= mm_result_word(6'd45);
                                mm_out1[46] <= mm_result_word(6'd46);
                                mm_out1[47] <= mm_result_word(6'd47);
                            end
                            if (mm_calc_out_slot == 1'b0) begin
                                mm_out0_valid <= 1'b1;
                            end
                            else begin
                                mm_out1_valid <= 1'b1;
                            end
                            mm_calc_state <= MM_CALC_IDLE;
                        end
                        default: begin
                            mm_calc_state <= MM_CALC_IDLE;
                        end
                    endcase

                    case (mm_wr_state)
                        WR_IDLE: begin
                            if (mm_out0_valid || mm_out1_valid) begin
                                mm_wr_slot <= mm_out0_valid ? 1'b0 : 1'b1;
                                mm_wr_cnt <= 6'd0;
                                m_wdata_r <= mm_out_word(mm_out0_valid ? 1'b0 : 1'b1, 6'd0);
                                if (matmul_crc_only) begin
                                    mm_wr_state <= WR_W;
                                end
                                else begin
                                    m_awaddr_r <= dma_cur_dst;
                                    m_awlen_r <= 8'd47;
                                    m_awvalid_r <= 1'b1;
                                    mm_wr_state <= WR_AW;
                                end
                            end
                        end
                        WR_AW: begin
                            if (m_aw_fire) begin
                                m_awvalid_r <= 1'b0;
                                m_wdata_r <= mm_out_word(mm_wr_slot, 6'd0);
                                m_wlast_r <= 1'b0;
                                m_wvalid_r <= 1'b1;
                                mm_wr_state <= WR_W;
                            end
                        end
                        WR_W: begin
                            if (matmul_crc_only) begin
                                mm_crc_state <= crc32_next_2words(mm_crc_state,
                                                                  mm_out_word(mm_wr_slot, mm_wr_cnt),
                                                                  mm_out_word(mm_wr_slot, mm_wr_cnt + 6'd1));
                                if (mm_wr_cnt == 6'd46) begin
                                    mm_wr_state <= WR_B;
                                end
                                else begin
                                    mm_wr_cnt <= mm_wr_word_next2;
                                end
                            end
                            else if (m_w_fire) begin
                                mm_crc_state <= crc32_next_word(mm_crc_state, m_wdata_r);
                                dma_cur_dst <= dma_cur_dst + 32'd4;
                                if (mm_wr_cnt == 6'd47) begin
                                    m_wvalid_r <= 1'b0;
                                    m_wlast_r <= 1'b0;
                                    m_bready_r <= 1'b1;
                                    mm_wr_state <= WR_B;
                                end
                                else begin
                                    mm_wr_cnt <= mm_wr_word_next;
                                    m_wdata_r <= mm_out_word(mm_wr_slot, mm_wr_word_next);
                                    m_wlast_r <= (mm_wr_word_next == 6'd47);
                                end
                            end
                        end
                        WR_B: begin
                            if (matmul_crc_only || m_b_fire) begin
                                if (!matmul_crc_only) begin
                                    m_bready_r <= 1'b0;
                                end
                                if (!matmul_crc_only && (m_bresp != 2'b00)) begin
                                    m_rready_r <= 1'b0;
                                    m_arvalid_r <= 1'b0;
                                    m_awvalid_r <= 1'b0;
                                    m_wvalid_r <= 1'b0;
                                    m_wlast_r <= 1'b0;
                                    dma_busy <= 1'b0;
                                    dma_done <= 1'b1;
                                    dma_error <= 1'b1;
                                    dma_finish <= 1'b1;
                                    mm_rd_state <= RD_IDLE;
                                    mm_wr_state <= WR_IDLE;
                                    mm_calc_state <= MM_CALC_IDLE;
                                    dma_state <= M_IDLE;
                                end
                                else begin
                                    if (mm_wr_slot == 1'b0) begin
                                        mm_out0_valid <= 1'b0;
                                    end
                                    else begin
                                        mm_out1_valid <= 1'b0;
                                    end

                                    if (mm_groups_left <= 32'd1) begin
                                        mm_groups_left <= 32'd0;
                                        dma_remain <= 32'd0;
                                        matmul_crc <= ~mm_crc_state;
                                        dma_busy <= 1'b0;
                                        dma_done <= 1'b1;
                                        dma_error <= 1'b0;
                                        dma_finish <= 1'b1;
                                        mm_rd_state <= RD_IDLE;
                                        mm_wr_state <= WR_IDLE;
                                        mm_calc_state <= MM_CALC_IDLE;
                                        dma_state <= M_IDLE;
                                    end
                                    else begin
                                        mm_groups_left <= mm_groups_left - 32'd1;
                                        dma_remain <= mm_groups_left - 32'd1;
                                        mm_wr_state <= WR_IDLE;
                                    end
                                end
                            end
                        end
                        default: begin
                            mm_wr_state <= WR_IDLE;
                        end
                    endcase
                end

                M_STREAM: begin
                    if (stream_push) begin
                        dma_buf[stream_fifo_wr_ptr] <= m_rdata;
                        stream_fifo_wr_ptr <= stream_fifo_wr_ptr + 7'd1;
                    end
                    if (stream_pop) begin
                        stream_fifo_rd_ptr <= stream_fifo_rd_ptr + 7'd1;
                    end

                    case ({stream_push, stream_pop})
                        2'b10: stream_fifo_count <= stream_fifo_count + 8'd1;
                        2'b01: stream_fifo_count <= stream_fifo_count - 8'd1;
                        default: stream_fifo_count <= stream_fifo_count;
                    endcase

                    case (stream_rd_state)
                        RD_IDLE: begin
                            if ((stream_rd_remain != 32'd0) && (stream_fifo_space != 8'd0)) begin
                                stream_rd_beats <= stream_rd_words_calc;
                                m_araddr_r <= stream_rd_addr;
                                m_arlen_r <= src_burst_allow_cfg ? (stream_rd_words_calc - 8'd1) : 8'd0;
                                m_arvalid_r <= 1'b1;
                                stream_rd_state <= RD_AR;
                            end
                        end
                        RD_AR: begin
                            if (m_ar_fire) begin
                                m_arvalid_r <= 1'b0;
                                m_rready_r <= 1'b1;
                                stream_rd_state <= RD_R;
                            end
                        end
                        RD_R: begin
                            if (m_r_fire) begin
                                if (m_rresp != 2'b00) begin
                                    m_rready_r <= 1'b0;
                                    m_arvalid_r <= 1'b0;
                                    m_awvalid_r <= 1'b0;
                                    m_wvalid_r <= 1'b0;
                                    m_bready_r <= 1'b0;
                                    m_wlast_r <= 1'b0;
                                    dma_busy <= 1'b0;
                                    dma_done <= 1'b1;
                                    dma_error <= 1'b1;
                                    dma_finish <= 1'b1;
                                    stream_rd_state <= RD_IDLE;
                                    stream_wr_state <= WR_IDLE;
                                    dma_state <= M_IDLE;
                                end
                                else begin
                                    stream_rd_addr <= stream_rd_addr + 32'd4;
                                    dma_cur_src <= stream_rd_addr + 32'd4;
                                    stream_rd_remain <= stream_rd_remain - 32'd1;
                                    if (stream_rd_beats == 8'd1) begin
                                        m_rready_r <= 1'b0;
                                        if ((stream_rd_remain_next != 32'd0) && (stream_fifo_space_next != 8'd0)) begin
                                            stream_rd_beats <= stream_rd_words_calc_next;
                                            m_araddr_r <= stream_rd_addr + 32'd4;
                                            m_arlen_r <= src_burst_allow_cfg ? (stream_rd_words_calc_next - 8'd1) : 8'd0;
                                            m_arvalid_r <= 1'b1;
                                            stream_rd_state <= RD_AR;
                                        end
                                        else begin
                                            stream_rd_state <= RD_IDLE;
                                        end
                                    end
                                    else begin
                                        stream_rd_beats <= stream_rd_beats - 8'd1;
                                    end
                                end
                            end
                        end
                        default: begin
                            stream_rd_state <= RD_IDLE;
                        end
                    endcase

                    case (stream_wr_state)
                        WR_IDLE: begin
                            if ((stream_wr_remain != 32'd0) && (stream_fifo_count != 8'd0)) begin
                                stream_wr_beats <= stream_wr_words_calc;
                                m_awaddr_r <= stream_wr_addr;
                                m_awlen_r <= dst_burst_allow_cfg ? (stream_wr_words_calc - 8'd1) : 8'd0;
                                m_awvalid_r <= 1'b1;
                                stream_wr_state <= WR_AW;
                            end
                        end
                        WR_AW: begin
                            if (m_aw_fire) begin
                                m_awvalid_r <= 1'b0;
                                m_wdata_r <= dma_buf[stream_fifo_rd_ptr];
                                m_wlast_r <= dst_burst_allow_cfg ? (stream_wr_beats == 8'd1) : 1'b1;
                                m_wvalid_r <= 1'b1;
                                stream_wr_state <= WR_W;
                            end
                        end
                        WR_W: begin
                            if (m_w_fire) begin
                                stream_wr_addr <= stream_wr_addr + 32'd4;
                                dma_cur_dst <= stream_wr_addr + 32'd4;
                                stream_wr_remain <= stream_wr_remain - 32'd1;
                                if (stream_wr_beats == 8'd1) begin
                                    m_wvalid_r <= 1'b0;
                                    m_wlast_r <= 1'b0;
                                    m_bready_r <= 1'b1;
                                    stream_wr_state <= WR_B;
                                end
                                else begin
                                    stream_wr_beats <= stream_wr_beats - 8'd1;
                                    m_wdata_r <= dma_buf[stream_fifo_rd_ptr + 7'd1];
                                    m_wlast_r <= dst_burst_allow_cfg ? (stream_wr_beats == 8'd2) : 1'b1;
                                end
                            end
                        end
                        WR_B: begin
                            if (m_b_fire) begin
                                m_bready_r <= 1'b0;
                                if (m_bresp != 2'b00) begin
                                    m_rready_r <= 1'b0;
                                    m_arvalid_r <= 1'b0;
                                    m_awvalid_r <= 1'b0;
                                    m_wvalid_r <= 1'b0;
                                    m_wlast_r <= 1'b0;
                                    dma_busy <= 1'b0;
                                    dma_done <= 1'b1;
                                    dma_error <= 1'b1;
                                    dma_finish <= 1'b1;
                                    stream_rd_state <= RD_IDLE;
                                    stream_wr_state <= WR_IDLE;
                                    dma_state <= M_IDLE;
                                end
                                else if ((stream_wr_remain != 32'd0) && (stream_fifo_count != 8'd0)) begin
                                    stream_wr_beats <= stream_wr_words_calc;
                                    m_awaddr_r <= stream_wr_addr;
                                    m_awlen_r <= dst_burst_allow_cfg ? (stream_wr_words_calc - 8'd1) : 8'd0;
                                    m_awvalid_r <= 1'b1;
                                    stream_wr_state <= WR_AW;
                                end
                                else begin
                                    stream_wr_state <= WR_IDLE;
                                end
                            end
                        end
                        default: begin
                            stream_wr_state <= WR_IDLE;
                        end
                    endcase

                    dma_remain <= (stream_wr_remain << 2);

                    if ((stream_rd_remain == 32'd0) &&
                        (stream_wr_remain == 32'd0) &&
                        (stream_fifo_count == 8'd0) &&
                        (stream_rd_state == RD_IDLE) &&
                        (stream_wr_state == WR_IDLE) &&
                        !m_arvalid_r &&
                        !m_rready_r &&
                        !m_awvalid_r &&
                        !m_wvalid_r &&
                        !m_bready_r) begin
                        dma_busy <= 1'b0;
                        dma_done <= 1'b1;
                        dma_error <= 1'b0;
                        dma_finish <= 1'b1;
                        dma_state <= M_IDLE;
                    end
                end

                M_AR: begin
                    if (m_ar_fire) begin
                        m_arvalid_r <= 1'b0;
                        m_rready_r <= 1'b1;
                        dma_state <= M_R;
                    end
                end

                M_R: begin
                    if (m_r_fire) begin
                        if (m_rresp != 2'b00) begin
                            m_rready_r <= 1'b0;
                            dma_busy <= 1'b0;
                            dma_done <= 1'b1;
                            dma_error <= 1'b1;
                            dma_finish <= 1'b1;
                            m_arvalid_r <= 1'b0;
                            m_bready_r <= 1'b0;
                            m_awvalid_r <= 1'b0;
                            m_wvalid_r <= 1'b0;
                            m_wlast_r <= 1'b0;
                            dma_state <= M_IDLE;
                        end
                        else begin
                            dma_buf[dma_rd_cnt] <= m_rdata;
                            if (dma_rd_cnt + 8'd1 >= dma_burst_words) begin
                                m_rready_r <= 1'b0;
                                dma_rd_cnt <= 8'd0;
                                dma_wr_cnt <= 8'd0;
                                m_awaddr_r <= dma_cur_dst;
                                m_awlen_r <= dma_dst_burst_en ? ({1'b0, dma_burst_words} - 8'd1) : 8'd0;
                                m_awvalid_r <= 1'b1;
                                dma_state <= M_AW;
                            end
                            else begin
                                if (dma_src_burst_en) begin
                                    dma_rd_cnt <= dma_rd_cnt + 8'd1;
                                end
                                else begin
                                    dma_rd_cnt <= dma_rd_cnt + 8'd1;
                                    m_rready_r <= 1'b0;
                                    m_araddr_r <= dma_cur_src + ({24'd0, dma_rd_cnt + 8'd1} << 2);
                                    m_arlen_r <= 8'd0;
                                    m_arvalid_r <= 1'b1;
                                    dma_state <= M_AR;
                                end
                            end
                        end
                    end
                end

                M_AW: begin
                    if (m_aw_fire) begin
                        m_awvalid_r <= 1'b0;
                        m_wdata_r <= dma_buf[dma_wr_cnt];
                        m_wlast_r <= dma_dst_burst_en ? (dma_burst_words == 8'd1) : 1'b1;
                        m_wvalid_r <= 1'b1;
                        dma_state <= M_W;
                    end
                end

                M_W: begin
                    if (m_w_fire) begin
                        if (dma_dst_burst_en) begin
                            if (dma_wr_cnt + 8'd1 >= dma_burst_words) begin
                                m_wvalid_r <= 1'b0;
                                m_wlast_r <= 1'b0;
                                m_bready_r <= 1'b1;
                                dma_state <= M_B;
                            end
                            else begin
                                dma_wr_cnt <= dma_wr_cnt + 8'd1;
                                m_wdata_r <= dma_buf[dma_wr_cnt + 8'd1];
                                m_wlast_r <= ((dma_wr_cnt + 8'd2) >= dma_burst_words);
                            end
                        end
                        else begin
                            m_wvalid_r <= 1'b0;
                            m_wlast_r <= 1'b0;
                            m_bready_r <= 1'b1;
                            dma_state <= M_B;
                        end
                    end
                end

                M_B: begin
                    if (m_b_fire) begin
                        m_bready_r <= 1'b0;
                        if (m_bresp != 2'b00) begin
                            dma_busy <= 1'b0;
                            dma_done <= 1'b1;
                            dma_error <= 1'b1;
                            dma_finish <= 1'b1;
                            dma_state <= M_IDLE;
                        end
                        else if (!dma_dst_burst_en && (dma_wr_cnt + 8'd1 < dma_burst_words)) begin
                            dma_wr_cnt <= dma_wr_cnt + 8'd1;
                            m_awaddr_r <= dma_cur_dst + ({24'd0, dma_wr_cnt + 8'd1} << 2);
                            m_awlen_r <= 8'd0;
                            m_awvalid_r <= 1'b1;
                            dma_state <= M_AW;
                        end
                        else begin
                            if (dma_remain <= dma_burst_bytes) begin
                                dma_cur_src <= dma_next_src;
                                dma_cur_dst <= dma_next_dst;
                                dma_remain <= 32'd0;
                                dma_busy <= 1'b0;
                                dma_done <= 1'b1;
                                dma_error <= 1'b0;
                                dma_finish <= 1'b1;
                                dma_state <= M_IDLE;
                            end
                            else begin
                                dma_cur_src <= dma_next_src;
                                dma_cur_dst <= dma_next_dst;
                                dma_remain <= dma_remain_next;
                                dma_burst_words <= dma_words_from_next;
                                dma_src_burst_en <= src_burst_allow_next;
                                dma_dst_burst_en <= dst_burst_allow_next;
                                dma_rd_cnt <= 8'd0;
                                dma_wr_cnt <= 8'd0;
                                m_araddr_r <= dma_next_src;
                                m_arlen_r <= src_burst_allow_next ? ({1'b0, dma_words_from_next} - 8'd1) : 8'd0;
                                m_arvalid_r <= 1'b1;
                                m_rready_r <= 1'b0;
                                dma_state <= M_AR;
                            end
                        end
                    end
                end

                default: begin
                    dma_state <= M_IDLE;
                end
            endcase
        end
    end

    assign s_wready = s_wready_r;
    assign s_bvalid = s_bvalid_r;
    assign s_bid = buf_id;
    assign s_bresp = 2'b0;
    assign s_rvalid = s_rvalid_r;
    assign s_rdata = s_rdata_r;
    assign s_rid = buf_id;
    assign s_rresp = 2'b0;
    assign s_rlast = s_rlast_r;

    assign m_arid = 4'b0;
    assign m_araddr = m_araddr_r;
    assign m_arlen = m_arlen_r;
    assign m_arsize = 3'd2;
    assign m_arburst = 2'b01;
    assign m_arlock = 1'b0;
    assign m_arcache = 4'b0;
    assign m_arprot = 3'b0;
    assign m_arvalid = m_arvalid_r;
    assign m_rready = m_rready_r;

    assign m_awid = 4'b0;
    assign m_awaddr = m_awaddr_r;
    assign m_awlen = m_awlen_r;
    assign m_awsize = 3'd2;
    assign m_awburst = 2'b01;
    assign m_awlock = 1'b0;
    assign m_awcache = 4'b0;
    assign m_awprot = 3'b0;
    assign m_awvalid = m_awvalid_r;

    assign m_wdata = m_wdata_r;
    assign m_wstrb = 4'hf;
    assign m_wlast = m_wlast_r;
    assign m_wvalid = m_wvalid_r;
    assign m_bready = m_bready_r;

endmodule
