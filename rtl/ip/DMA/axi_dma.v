// Generic AXI memory-to-memory DMA with ping-pong buffering.
//
// Register map, matching sdk/software/bsp/include/dma.h:
//   0x00 CTRL      bit0 start, bit1 clear done/error
//   0x04 STATUS    bit0 busy, bit1 done, bit2 error
//   0x08 SRC       source physical/bus address
//   0x0c DST       destination physical/bus address
//   0x10 LEN       byte length, must be non-zero and word aligned
//   0x14 CUR_SRC   next source address to be requested
//   0x18 CUR_DST   next destination address to be completed
//   0x1c REMAIN    bytes not yet written to destination
//   0x20 VERSION   implementation version
//
// The engine copies aligned 32-bit words.  It uses two 16-word banks: the read
// channel may fill one bank while the write channel drains the other.  If the
// downstream memory system is single-port, its AXI interconnect/bridge will
// serialize the transactions; this module still remains AXI4 compliant.
module axi_dma (
    input             clk,
    input             resetn,

    // CPU-facing AXI slave register interface.
    input      [4:0]  s_axi_awid,
    input      [31:0] s_axi_awaddr,
    input      [7:0]  s_axi_awlen,
    input      [2:0]  s_axi_awsize,
    input      [1:0]  s_axi_awburst,
    input             s_axi_awlock,
    input      [3:0]  s_axi_awcache,
    input      [2:0]  s_axi_awprot,
    input             s_axi_awvalid,
    output            s_axi_awready,
    input      [31:0] s_axi_wdata,
    input      [3:0]  s_axi_wstrb,
    input             s_axi_wlast,
    input             s_axi_wvalid,
    output            s_axi_wready,
    output reg [4:0]  s_axi_bid,
    output     [1:0]  s_axi_bresp,
    output reg        s_axi_bvalid,
    input             s_axi_bready,
    input      [4:0]  s_axi_arid,
    input      [31:0] s_axi_araddr,
    input      [7:0]  s_axi_arlen,
    input      [2:0]  s_axi_arsize,
    input      [1:0]  s_axi_arburst,
    input             s_axi_arlock,
    input      [3:0]  s_axi_arcache,
    input      [2:0]  s_axi_arprot,
    input             s_axi_arvalid,
    output            s_axi_arready,
    output reg [4:0]  s_axi_rid,
    output reg [31:0] s_axi_rdata,
    output     [1:0]  s_axi_rresp,
    output            s_axi_rlast,
    output reg        s_axi_rvalid,
    input             s_axi_rready,

    // Memory-facing AXI master interface.
    output     [3:0]  m_axi_awid,
    output     [31:0] m_axi_awaddr,
    output     [7:0]  m_axi_awlen,
    output     [2:0]  m_axi_awsize,
    output     [1:0]  m_axi_awburst,
    output            m_axi_awlock,
    output     [3:0]  m_axi_awcache,
    output     [2:0]  m_axi_awprot,
    output            m_axi_awvalid,
    input             m_axi_awready,
    output     [31:0] m_axi_wdata,
    output     [3:0]  m_axi_wstrb,
    output            m_axi_wlast,
    output            m_axi_wvalid,
    input             m_axi_wready,
    input      [3:0]  m_axi_bid,
    input      [1:0]  m_axi_bresp,
    input             m_axi_bvalid,
    output            m_axi_bready,
    output     [3:0]  m_axi_arid,
    output     [31:0] m_axi_araddr,
    output     [7:0]  m_axi_arlen,
    output     [2:0]  m_axi_arsize,
    output     [1:0]  m_axi_arburst,
    output            m_axi_arlock,
    output     [3:0]  m_axi_arcache,
    output     [2:0]  m_axi_arprot,
    output            m_axi_arvalid,
    input             m_axi_arready,
    input      [3:0]  m_axi_rid,
    input      [31:0] m_axi_rdata,
    input      [1:0]  m_axi_rresp,
    input             m_axi_rlast,
    input             m_axi_rvalid,
    output            m_axi_rready,

    output            finish
);

localparam [11:0] ADDR_CTRL    = 12'h000;
localparam [11:0] ADDR_STATUS  = 12'h004;
localparam [11:0] ADDR_SRC     = 12'h008;
localparam [11:0] ADDR_DST     = 12'h00c;
localparam [11:0] ADDR_LEN     = 12'h010;
localparam [11:0] ADDR_CUR_SRC = 12'h014;
localparam [11:0] ADDR_CUR_DST = 12'h018;
localparam [11:0] ADDR_REMAIN  = 12'h01c;
localparam [11:0] ADDR_VERSION = 12'h020;

localparam [31:0] DMA_VERSION  = 32'h41584402; // "AXD", v2 ping-pong

localparam [1:0] RD_IDLE = 2'd0;
localparam [1:0] RD_AR   = 2'd1;
localparam [1:0] RD_DATA = 2'd2;

localparam [1:0] WR_IDLE = 2'd0;
localparam [1:0] WR_AW   = 2'd1;
localparam [1:0] WR_DATA = 2'd2;
localparam [1:0] WR_RESP = 2'd3;

reg [31:0] src_reg;
reg [31:0] dst_reg;
reg [31:0] len_reg;

reg [31:0] next_src_addr;
reg [31:0] next_dst_addr_for_read;
reg [31:0] cur_dst;
reg [31:0] read_remain_bytes;
reg [31:0] write_remain_bytes;

reg        busy;
reg        done;
reg        error;
reg        start_pulse;
reg        clear_pulse;

reg [31:0] awaddr_hold;
reg [4:0]  awid_hold;
reg [7:0]  awlen_count;
reg        aw_hold_valid;
reg [31:0] wdata_hold;
reg [3:0]  wstrb_hold;
reg        w_hold_valid;

reg [1:0]  rd_state;
reg [1:0]  wr_state;
reg        rd_bank;
reg        wr_bank;
reg [4:0]  rd_burst_words;
reg [4:0]  wr_burst_words;
reg [4:0]  rd_count;
reg [4:0]  wr_count;
reg [31:0] wr_addr;

reg        bank_full [0:1];
reg [4:0]  bank_words [0:1];
reg [31:0] bank_dst_addr [0:1];
reg [31:0] buffer0 [0:15];
reg [31:0] buffer1 [0:15];

wire [11:0] write_offset = awaddr_hold[11:0];
wire [11:0] read_offset  = s_axi_araddr[11:0];
wire aw_handshake = s_axi_awvalid && s_axi_awready;
wire w_handshake  = s_axi_wvalid && s_axi_wready;
wire write_fire   = aw_hold_valid && w_hold_valid && !s_axi_bvalid;
wire cfg_aligned   = (src_reg[1:0] == 2'b00) &&
                     (dst_reg[1:0] == 2'b00) &&
                     (len_reg[1:0] == 2'b00);
wire cfg_valid     = (len_reg != 32'd0) && cfg_aligned;
wire can_read_bank = !bank_full[rd_bank];
wire can_write_bank = bank_full[wr_bank];
wire no_more_reads = (read_remain_bytes == 32'd0) && (rd_state == RD_IDLE);
wire no_more_writes = (write_remain_bytes == 32'd0) && (wr_state == WR_IDLE);
wire all_banks_empty = !bank_full[0] && !bank_full[1];
wire [31:0] rd_burst_bytes = {25'd0, rd_burst_words, 2'b00};
wire [31:0] wr_burst_bytes = {25'd0, wr_burst_words, 2'b00};
wire [31:0] next_read_remain = read_remain_bytes - rd_burst_bytes;
wire [31:0] next_write_remain = write_remain_bytes - wr_burst_bytes;
wire [31:0] next_src_after_read = next_src_addr + rd_burst_bytes;
wire [31:0] next_dst_after_read = next_dst_addr_for_read + rd_burst_bytes;
wire [31:0] next_cur_dst_after_write = cur_dst + wr_burst_bytes;
wire unused_slave_inputs = s_axi_awlock | (|s_axi_awcache) | (|s_axi_awprot) |
                           (|s_axi_awsize) | (|s_axi_awburst) |
                           s_axi_wlast | s_axi_arlock | (|s_axi_arcache) |
                           (|s_axi_arprot) | (|s_axi_arsize) |
                           (|s_axi_arburst) | (|s_axi_arlen) |
                           (|m_axi_bid) | (|m_axi_rid);
wire [31:0] selected_wdata = wr_bank ? buffer1[wr_count[3:0]] :
                                       buffer0[wr_count[3:0]];

function [31:0] apply_wstrb;
    input [31:0] old_value;
    input [31:0] new_value;
    input [3:0]  strobe;
    begin
        apply_wstrb = old_value;
        if (strobe[0]) apply_wstrb[7:0]   = new_value[7:0];
        if (strobe[1]) apply_wstrb[15:8]  = new_value[15:8];
        if (strobe[2]) apply_wstrb[23:16] = new_value[23:16];
        if (strobe[3]) apply_wstrb[31:24] = new_value[31:24];
    end
endfunction

function [4:0] page_words_left;
    input [11:0] addr_offset;
    reg [12:0] bytes_left;
    reg [10:0] words_left;
    begin
        bytes_left = 13'h1000 - {1'b0, addr_offset};
        words_left = bytes_left[12:2];
        if (words_left > 11'd16)
            page_words_left = 5'd16;
        else
            page_words_left = words_left[4:0];
    end
endfunction

function [4:0] choose_burst_words;
    input [29:0] words_remaining;
    input [31:0] src_addr;
    input [31:0] dst_addr;
    reg [4:0] count;
    reg [4:0] src_limit;
    reg [4:0] dst_limit;
    begin
        count = (words_remaining >= 30'd16) ? 5'd16 : {1'b0, words_remaining[3:0]};
        src_limit = page_words_left(src_addr[11:0]);
        dst_limit = page_words_left(dst_addr[11:0]);
        if (count > src_limit)
            count = src_limit;
        if (count > dst_limit)
            count = dst_limit;
        choose_burst_words = count;
    end
endfunction

assign s_axi_awready = !aw_hold_valid && !s_axi_bvalid;
assign s_axi_wready  = aw_hold_valid && !w_hold_valid && !s_axi_bvalid;
assign s_axi_bresp   = 2'b00;
assign s_axi_arready = !s_axi_rvalid;
assign s_axi_rresp   = 2'b00;
assign s_axi_rlast   = 1'b1;

assign finish = done;

assign m_axi_arid    = 4'h3;
assign m_axi_araddr  = next_src_addr;
assign m_axi_arlen   = rd_burst_words - 5'd1;
assign m_axi_arsize  = 3'd2;
assign m_axi_arburst = 2'b01;
assign m_axi_arlock  = 1'b0;
assign m_axi_arcache = 4'b0000;
assign m_axi_arprot  = 3'b000;
assign m_axi_arvalid = busy && (rd_state == RD_AR);
assign m_axi_rready  = busy && (rd_state == RD_DATA);

assign m_axi_awid    = 4'h3;
assign m_axi_awaddr  = wr_addr;
assign m_axi_awlen   = wr_burst_words - 5'd1;
assign m_axi_awsize  = 3'd2;
assign m_axi_awburst = 2'b01;
assign m_axi_awlock  = 1'b0;
assign m_axi_awcache = 4'b0000;
assign m_axi_awprot  = 3'b000;
assign m_axi_awvalid = busy && (wr_state == WR_AW);
assign m_axi_wdata   = selected_wdata;
assign m_axi_wstrb   = 4'b1111;
assign m_axi_wlast   = (wr_count + 5'd1) == wr_burst_words;
assign m_axi_wvalid  = busy && (wr_state == WR_DATA);
assign m_axi_bready  = busy && (wr_state == WR_RESP);

always @(posedge clk) begin
    if (!resetn) begin
        src_reg           <= 32'd0;
        dst_reg           <= 32'd0;
        len_reg           <= 32'd0;
        awaddr_hold       <= 32'd0;
        awid_hold         <= 5'd0;
        awlen_count       <= 8'd0;
        aw_hold_valid     <= 1'b0;
        wdata_hold        <= 32'd0;
        wstrb_hold        <= 4'd0;
        w_hold_valid      <= 1'b0;
        s_axi_bid         <= 5'd0;
        s_axi_bvalid      <= 1'b0;
        s_axi_rid         <= 5'd0;
        s_axi_rdata       <= 32'd0;
        s_axi_rvalid      <= 1'b0;
        start_pulse       <= 1'b0;
        clear_pulse       <= 1'b0;
    end else begin
        start_pulse <= 1'b0;
        clear_pulse <= 1'b0;

        if (aw_handshake) begin
            awaddr_hold   <= s_axi_awaddr;
            awid_hold     <= s_axi_awid;
            awlen_count   <= s_axi_awlen;
            aw_hold_valid <= 1'b1;
        end

        if (w_handshake) begin
            wdata_hold   <= s_axi_wdata;
            wstrb_hold   <= s_axi_wstrb;
            w_hold_valid <= 1'b1;
        end

        if (s_axi_bvalid && s_axi_bready)
            s_axi_bvalid <= 1'b0;

        if (write_fire) begin
            s_axi_bid    <= awid_hold;
            w_hold_valid <= 1'b0;
            if (awlen_count == 8'd0) begin
                s_axi_bvalid  <= 1'b1;
                aw_hold_valid <= 1'b0;
            end else begin
                awlen_count <= awlen_count - 8'd1;
                awaddr_hold <= awaddr_hold + 32'd4;
            end

            case (write_offset)
                ADDR_CTRL: begin
                    if (wdata_hold[0])
                        start_pulse <= 1'b1;
                    if (wdata_hold[1])
                        clear_pulse <= 1'b1;
                end
                ADDR_SRC: begin
                    if (!busy)
                        src_reg <= apply_wstrb(src_reg, wdata_hold, wstrb_hold);
                end
                ADDR_DST: begin
                    if (!busy)
                        dst_reg <= apply_wstrb(dst_reg, wdata_hold, wstrb_hold);
                end
                ADDR_LEN: begin
                    if (!busy)
                        len_reg <= apply_wstrb(len_reg, wdata_hold, wstrb_hold);
                end
                default: begin
                    if (unused_slave_inputs)
                        start_pulse <= 1'b0;
                end
            endcase
        end

        if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rid    <= s_axi_arid;
            s_axi_rvalid <= 1'b1;
            case (read_offset)
                ADDR_CTRL:    s_axi_rdata <= 32'd0;
                ADDR_STATUS:  s_axi_rdata <= {29'd0, error, done, busy};
                ADDR_SRC:     s_axi_rdata <= src_reg;
                ADDR_DST:     s_axi_rdata <= dst_reg;
                ADDR_LEN:     s_axi_rdata <= len_reg;
                ADDR_CUR_SRC: s_axi_rdata <= next_src_addr;
                ADDR_CUR_DST: s_axi_rdata <= cur_dst;
                ADDR_REMAIN:  s_axi_rdata <= write_remain_bytes;
                ADDR_VERSION: s_axi_rdata <= DMA_VERSION;
                default:      s_axi_rdata <= 32'd0;
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
end

always @(posedge clk) begin
    if (!resetn) begin
        busy                   <= 1'b0;
        done                   <= 1'b0;
        error                  <= 1'b0;
        next_src_addr          <= 32'd0;
        next_dst_addr_for_read <= 32'd0;
        cur_dst                <= 32'd0;
        read_remain_bytes      <= 32'd0;
        write_remain_bytes     <= 32'd0;
        rd_state               <= RD_IDLE;
        wr_state               <= WR_IDLE;
        rd_bank                <= 1'b0;
        wr_bank                <= 1'b0;
        rd_burst_words         <= 5'd0;
        wr_burst_words         <= 5'd0;
        rd_count               <= 5'd0;
        wr_count               <= 5'd0;
        wr_addr                <= 32'd0;
        bank_full[0]           <= 1'b0;
        bank_full[1]           <= 1'b0;
        bank_words[0]          <= 5'd0;
        bank_words[1]          <= 5'd0;
        bank_dst_addr[0]       <= 32'd0;
        bank_dst_addr[1]       <= 32'd0;
    end else begin
        if (clear_pulse) begin
            done  <= 1'b0;
            error <= 1'b0;
        end

        if (start_pulse && !busy) begin
            done <= 1'b0;
            if (!cfg_valid) begin
                busy             <= 1'b0;
                error            <= 1'b1;
                done             <= 1'b1;
                rd_state         <= RD_IDLE;
                wr_state         <= WR_IDLE;
                bank_full[0]     <= 1'b0;
                bank_full[1]     <= 1'b0;
                write_remain_bytes <= len_reg;
            end else begin
                busy                   <= 1'b1;
                error                  <= 1'b0;
                next_src_addr          <= src_reg;
                next_dst_addr_for_read <= dst_reg;
                cur_dst                <= dst_reg;
                read_remain_bytes      <= len_reg;
                write_remain_bytes     <= len_reg;
                rd_bank                <= 1'b0;
                wr_bank                <= 1'b0;
                bank_full[0]           <= 1'b0;
                bank_full[1]           <= 1'b0;
                rd_burst_words         <= 5'd0;
                wr_burst_words         <= 5'd0;
                rd_count               <= 5'd0;
                wr_count               <= 5'd0;
                rd_state               <= RD_IDLE;
                wr_state               <= WR_IDLE;
            end
        end else if (busy) begin
            case (rd_state)
                RD_IDLE: begin
                    if ((read_remain_bytes != 32'd0) && can_read_bank) begin
                        rd_burst_words <= choose_burst_words(read_remain_bytes[31:2],
                                                             next_src_addr,
                                                             next_dst_addr_for_read);
                        rd_count <= 5'd0;
                        rd_state <= RD_AR;
                    end
                end

                RD_AR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        rd_count <= 5'd0;
                        rd_state <= RD_DATA;
                    end
                end

                RD_DATA: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (rd_bank)
                            buffer1[rd_count[3:0]] <= m_axi_rdata;
                        else
                            buffer0[rd_count[3:0]] <= m_axi_rdata;

                        if (m_axi_rresp != 2'b00)
                            error <= 1'b1;

                        if ((rd_count + 5'd1) == rd_burst_words) begin
                            if (!m_axi_rlast)
                                error <= 1'b1;
                            bank_full[rd_bank]     <= 1'b1;
                            bank_words[rd_bank]    <= rd_burst_words;
                            bank_dst_addr[rd_bank] <= next_dst_addr_for_read;
                            next_src_addr          <= next_src_after_read;
                            next_dst_addr_for_read <= next_dst_after_read;
                            read_remain_bytes      <= next_read_remain;
                            rd_bank                <= ~rd_bank;
                            rd_state               <= RD_IDLE;
                        end else begin
                            if (m_axi_rlast)
                                error <= 1'b1;
                            rd_count <= rd_count + 5'd1;
                        end
                    end
                end

                default: begin
                    rd_state <= RD_IDLE;
                    error    <= 1'b1;
                end
            endcase

            case (wr_state)
                WR_IDLE: begin
                    if (can_write_bank) begin
                        wr_burst_words <= bank_words[wr_bank];
                        wr_addr        <= bank_dst_addr[wr_bank];
                        wr_count       <= 5'd0;
                        wr_state       <= WR_AW;
                    end
                end

                WR_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        wr_count <= 5'd0;
                        wr_state <= WR_DATA;
                    end
                end

                WR_DATA: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        if ((wr_count + 5'd1) == wr_burst_words) begin
                            wr_state <= WR_RESP;
                        end else begin
                            wr_count <= wr_count + 5'd1;
                        end
                    end
                end

                WR_RESP: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        if (m_axi_bresp != 2'b00)
                            error <= 1'b1;
                        bank_full[wr_bank] <= 1'b0;
                        wr_bank            <= ~wr_bank;
                        cur_dst            <= next_cur_dst_after_write;
                        write_remain_bytes <= next_write_remain;
                        wr_state           <= WR_IDLE;
                    end
                end

                default: begin
                    wr_state <= WR_IDLE;
                    error    <= 1'b1;
                end
            endcase

            if (no_more_reads && no_more_writes && all_banks_empty) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end
end

endmodule
