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

    localparam CTRL_ADDR      = 16'h0000;
    localparam STATUS_ADDR    = 16'h0004;
    localparam SRC_ADDR       = 16'h0008;
    localparam DST_ADDR       = 16'h000c;
    localparam LEN_ADDR       = 16'h0010;
    localparam CUR_SRC_ADDR   = 16'h0014;
    localparam CUR_DST_ADDR   = 16'h0018;
    localparam REMAIN_ADDR    = 16'h001c;
    localparam VERSION_ADDR   = 16'h0020;

    localparam DEFAULT_BURST_MAX_WORDS = 8'd64;
    localparam KYBER_BURST_MAX_WORDS   = 8'd128;

    localparam M_IDLE = 3'd0;
    localparam M_AR   = 3'd1;
    localparam M_R    = 3'd2;
    localparam M_AW   = 3'd3;
    localparam M_W    = 3'd4;
    localparam M_B    = 3'd5;
    localparam M_STREAM = 3'd6;

    localparam RD_IDLE = 2'd0;
    localparam RD_AR   = 2'd1;
    localparam RD_R    = 2'd2;
    localparam WR_IDLE = 2'd0;
    localparam WR_AW   = 2'd1;
    localparam WR_W    = 2'd2;
    localparam WR_B    = 2'd3;

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
    reg [2:0] dma_state;

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
    wire kyber_src_cfg = (dma_src_addr[31:20] == 12'h1f6);
    wire kyber_dst_cfg = (dma_dst_addr[31:20] == 12'h1f6);
    wire src_burst_allow_cfg = (dma_src_addr[28:24] != 5'h1f) | kyber_src_cfg;
    wire dst_burst_allow_cfg = (dma_dst_addr[28:24] != 5'h1f) | kyber_dst_cfg;
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

    wire [31:0] status_data = {29'd0, dma_error, dma_done, dma_busy};
    wire [31:0] rdata_d =   buf_addr[15:0] == CTRL_ADDR    ? 32'd0        :
                            buf_addr[15:0] == STATUS_ADDR  ? status_data   :
                            buf_addr[15:0] == SRC_ADDR     ? dma_src_addr  :
                            buf_addr[15:0] == DST_ADDR     ? dma_dst_addr  :
                            buf_addr[15:0] == LEN_ADDR     ? dma_len_cfg   :
                            buf_addr[15:0] == CUR_SRC_ADDR ? dma_cur_src   :
                            buf_addr[15:0] == CUR_DST_ADDR ? dma_cur_dst   :
                            buf_addr[15:0] == REMAIN_ADDR  ? dma_remain    :
                            buf_addr[15:0] == VERSION_ADDR ? 32'h444d_4131 :
                            32'd0;

    assign s_arready = ~axi_busy & (!axi_r_or_w | !s_awvalid);
    assign s_awready = ~axi_busy & ( axi_r_or_w | !s_arvalid);

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

                        if (cfg_invalid) begin
                            dma_busy <= 1'b0;
                            dma_done <= 1'b1;
                            dma_error <= 1'b1;
                            dma_finish <= 1'b1;
                        end
                        else if (stream_cfg) begin
                            dma_busy <= 1'b1;
                            dma_done <= 1'b0;
                            dma_error <= 1'b0;
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
