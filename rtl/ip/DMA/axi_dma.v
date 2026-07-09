// Generic AXI memory-to-memory DMA.
//
// This block is intentionally independent from the matrix-specific
// matmul_dma.v.  It exposes a small AXI register slave for software or another
// controller to configure a copy transaction, and an AXI master that performs
// aligned 32-bit INCR bursts.  The implementation is store-and-forward per
// burst: read one burst into an internal buffer, then write that burst to the
// destination.  This keeps the control path simple and AXI4 compliant while
// still giving other peripherals a reusable DMA building block.
module axi_dma #(
    parameter MAX_BURST_WORDS = 16
) (
    input             clk,
    input             resetn,

    // AXI slave register interface.
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

    // AXI master memory interface.
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

    output            irq
);

localparam [11:0] ADDR_CTRL       = 12'h000;
localparam [11:0] ADDR_STATUS     = 12'h004;
localparam [11:0] ADDR_SRC        = 12'h008;
localparam [11:0] ADDR_DST        = 12'h00c;
localparam [11:0] ADDR_LEN_BYTES  = 12'h010;
localparam [11:0] ADDR_BURST_WORDS= 12'h014;
localparam [11:0] ADDR_DONE_BYTES = 12'h018;
localparam [11:0] ADDR_IRQ_ENABLE = 12'h01c;

localparam [2:0] ST_IDLE = 3'd0;
localparam [2:0] ST_AR   = 3'd1;
localparam [2:0] ST_R    = 3'd2;
localparam [2:0] ST_AW   = 3'd3;
localparam [2:0] ST_W    = 3'd4;
localparam [2:0] ST_B    = 3'd5;
localparam [8:0] MAX_BURST_LIMIT =
    (MAX_BURST_WORDS > 256) ? 9'd256 : MAX_BURST_WORDS;

reg [31:0] src_base;
reg [31:0] dst_base;
reg [31:0] len_bytes;
reg [7:0]  cfg_burst_words;
reg        irq_enable;

reg [31:0] awaddr_hold;
reg [4:0]  awid_hold;
reg [7:0]  awlen_count;
reg        aw_hold_valid;
reg [31:0] wdata_hold;
reg [3:0]  wstrb_hold;
reg        w_hold_valid;
reg        start_pulse;
reg        clear_status_pulse;

reg        busy;
reg        done;
reg        error;
reg [2:0]  state;
reg [31:0] src_addr;
reg [31:0] dst_addr;
reg [31:0] words_remaining;
reg [31:0] done_bytes;
reg [7:0]  burst_last;
reg [7:0]  read_beat;
reg [7:0]  write_beat;

reg [31:0] burst_buffer [0:MAX_BURST_WORDS-1];

wire [11:0] write_offset = awaddr_hold[11:0];
wire [11:0] read_offset = s_axi_araddr[11:0];
wire aw_handshake = s_axi_awvalid && s_axi_awready;
wire w_handshake = s_axi_wvalid && s_axi_wready;
wire write_fire = aw_hold_valid && w_hold_valid && !s_axi_bvalid;
wire [31:0] src_page_bytes = 32'h00001000 - {20'd0, src_addr[11:0]};
wire [31:0] dst_page_bytes = 32'h00001000 - {20'd0, dst_addr[11:0]};
wire [8:0] cfg_burst_limit = (cfg_burst_words == 8'd0) ? 9'd1 :
                             ({1'b0, cfg_burst_words} > MAX_BURST_LIMIT) ?
                             MAX_BURST_LIMIT :
                             {1'b0, cfg_burst_words};
wire [8:0] words_limit = (words_remaining > {23'd0, cfg_burst_limit}) ?
                         cfg_burst_limit : words_remaining[8:0];
wire [10:0] src_page_words = src_page_bytes[12:2];
wire [10:0] dst_page_words = dst_page_bytes[12:2];
wire [10:0] page_limit_a = (src_page_words < dst_page_words) ?
                           src_page_words : dst_page_words;
wire [8:0] page_limited_words = (page_limit_a < {2'b00, words_limit}) ?
                                page_limit_a[8:0] : words_limit;
wire [8:0] next_burst_words = page_limited_words;
wire [31:0] cfg_burst_words_next =
    apply_wstrb({24'd0, cfg_burst_words}, wdata_hold, wstrb_hold);
wire [31:0] irq_enable_next =
    apply_wstrb({31'd0, irq_enable}, wdata_hold, wstrb_hold);
wire invalid_start = (len_bytes == 32'd0) || (len_bytes[1:0] != 2'b00) ||
                     (src_base[1:0] != 2'b00) || (dst_base[1:0] != 2'b00) ||
                     (MAX_BURST_WORDS < 1);
wire unused_slave_inputs = s_axi_awsize[0] | s_axi_awsize[1] | s_axi_awsize[2] |
                           s_axi_awburst[0] | s_axi_awburst[1] |
                           s_axi_awlock | (|s_axi_awcache) | (|s_axi_awprot) |
                           s_axi_wlast |
                           s_axi_arsize[0] | s_axi_arsize[1] | s_axi_arsize[2] |
                           s_axi_arburst[0] | s_axi_arburst[1] |
                           s_axi_arlock | (|s_axi_arcache) | (|s_axi_arprot) |
                           (|m_axi_bid) | (|m_axi_rid);

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

assign s_axi_awready = !aw_hold_valid && !s_axi_bvalid;
assign s_axi_wready  = aw_hold_valid && !w_hold_valid && !s_axi_bvalid;
assign s_axi_bresp   = 2'b00;
assign s_axi_arready = !s_axi_rvalid;
assign s_axi_rresp   = 2'b00;
assign s_axi_rlast   = 1'b1;

assign m_axi_arid    = 4'h3;
assign m_axi_araddr  = src_addr;
assign m_axi_arlen   = burst_last;
assign m_axi_arsize  = 3'd2;
assign m_axi_arburst = 2'b01;
assign m_axi_arlock  = 1'b0;
assign m_axi_arcache = 4'b0000;
assign m_axi_arprot  = 3'b000;
assign m_axi_arvalid = busy && (state == ST_AR);
assign m_axi_rready  = busy && (state == ST_R);

assign m_axi_awid    = 4'h3;
assign m_axi_awaddr  = dst_addr;
assign m_axi_awlen   = burst_last;
assign m_axi_awsize  = 3'd2;
assign m_axi_awburst = 2'b01;
assign m_axi_awlock  = 1'b0;
assign m_axi_awcache = 4'b0000;
assign m_axi_awprot  = 3'b000;
assign m_axi_awvalid = busy && (state == ST_AW);
assign m_axi_wdata   = burst_buffer[write_beat];
assign m_axi_wstrb   = 4'b1111;
assign m_axi_wlast   = (write_beat == burst_last);
assign m_axi_wvalid  = busy && (state == ST_W);
assign m_axi_bready  = busy && (state == ST_B);

assign irq = done && irq_enable;

always @(posedge clk) begin
    if (!resetn) begin
        src_base           <= 32'd0;
        dst_base           <= 32'd0;
        len_bytes          <= 32'd0;
        cfg_burst_words    <= MAX_BURST_LIMIT[7:0];
        irq_enable         <= 1'b0;
        awaddr_hold        <= 32'd0;
        awid_hold          <= 5'd0;
        awlen_count        <= 8'd0;
        aw_hold_valid      <= 1'b0;
        wdata_hold         <= 32'd0;
        wstrb_hold         <= 4'd0;
        w_hold_valid       <= 1'b0;
        s_axi_bid          <= 5'd0;
        s_axi_bvalid       <= 1'b0;
        s_axi_rid          <= 5'd0;
        s_axi_rdata        <= 32'd0;
        s_axi_rvalid       <= 1'b0;
        start_pulse        <= 1'b0;
        clear_status_pulse <= 1'b0;
    end else begin
        start_pulse        <= 1'b0;
        clear_status_pulse <= 1'b0;

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

            if (!busy && (write_offset == ADDR_SRC))
                src_base <= apply_wstrb(src_base, wdata_hold, wstrb_hold);
            else if (!busy && (write_offset == ADDR_DST))
                dst_base <= apply_wstrb(dst_base, wdata_hold, wstrb_hold);
            else if (!busy && (write_offset == ADDR_LEN_BYTES))
                len_bytes <= apply_wstrb(len_bytes, wdata_hold, wstrb_hold);
            else if (!busy && (write_offset == ADDR_BURST_WORDS))
                cfg_burst_words <= cfg_burst_words_next[7:0];
            else if (write_offset == ADDR_IRQ_ENABLE)
                irq_enable <= irq_enable_next[0];
            else if ((write_offset == ADDR_CTRL) && wdata_hold[0] && !busy)
                start_pulse <= 1'b1;
            else if ((write_offset == ADDR_STATUS) && (wdata_hold[2:1] != 2'b00))
                clear_status_pulse <= 1'b1;
        end

        if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rid    <= s_axi_arid;
            s_axi_rvalid <= 1'b1;
            case (read_offset)
                ADDR_CTRL:        s_axi_rdata <= 32'd0;
                ADDR_STATUS:      s_axi_rdata <= {29'd0, error, done, busy};
                ADDR_SRC:         s_axi_rdata <= src_base;
                ADDR_DST:         s_axi_rdata <= dst_base;
                ADDR_LEN_BYTES:   s_axi_rdata <= len_bytes;
                ADDR_BURST_WORDS: s_axi_rdata <= {24'd0, cfg_burst_words};
                ADDR_DONE_BYTES:  s_axi_rdata <= done_bytes;
                ADDR_IRQ_ENABLE:  s_axi_rdata <= {31'd0, irq_enable};
                default:          s_axi_rdata <= {31'd0, unused_slave_inputs};
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
end

always @(posedge clk) begin
    if (!resetn) begin
        busy            <= 1'b0;
        done            <= 1'b0;
        error           <= 1'b0;
        state           <= ST_IDLE;
        src_addr        <= 32'd0;
        dst_addr        <= 32'd0;
        words_remaining <= 32'd0;
        done_bytes      <= 32'd0;
        burst_last      <= 8'd0;
        read_beat       <= 8'd0;
        write_beat      <= 8'd0;
    end else begin
        if (clear_status_pulse) begin
            done  <= 1'b0;
            error <= 1'b0;
        end

        if (start_pulse) begin
            done            <= 1'b0;
            error           <= invalid_start;
            busy            <= !invalid_start;
            state           <= invalid_start ? ST_IDLE : ST_AR;
            src_addr        <= src_base;
            dst_addr        <= dst_base;
            words_remaining <= {2'b00, len_bytes[31:2]};
            done_bytes      <= 32'd0;
            read_beat       <= 8'd0;
            write_beat      <= 8'd0;
            burst_last      <= (next_burst_words == 9'd0) ?
                               8'd0 : next_burst_words[7:0] - 8'd1;
            if (invalid_start)
                done <= 1'b1;
        end else if (busy) begin
            case (state)
                ST_AR: begin
                    burst_last <= next_burst_words[7:0] - 8'd1;
                    if (m_axi_arvalid && m_axi_arready) begin
                        read_beat <= 8'd0;
                        state <= ST_R;
                    end
                end
                ST_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        burst_buffer[read_beat] <= m_axi_rdata;
                        if (m_axi_rresp != 2'b00)
                            error <= 1'b1;
                        if (read_beat == burst_last) begin
                            if (!m_axi_rlast)
                                error <= 1'b1;
                            state <= ST_AW;
                            write_beat <= 8'd0;
                        end else begin
                            if (m_axi_rlast)
                                error <= 1'b1;
                            read_beat <= read_beat + 8'd1;
                        end
                    end
                end
                ST_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        write_beat <= 8'd0;
                        state <= ST_W;
                    end
                end
                ST_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        if (write_beat == burst_last) begin
                            state <= ST_B;
                        end else begin
                            write_beat <= write_beat + 8'd1;
                        end
                    end
                end
                ST_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        if (m_axi_bresp != 2'b00)
                            error <= 1'b1;
                        src_addr <= src_addr + {22'd0, burst_last, 2'b00} + 32'd4;
                        dst_addr <= dst_addr + {22'd0, burst_last, 2'b00} + 32'd4;
                        done_bytes <= done_bytes + {22'd0, burst_last, 2'b00} + 32'd4;
                        words_remaining <= words_remaining - ({24'd0, burst_last} + 32'd1);
                        if (words_remaining == ({24'd0, burst_last} + 32'd1)) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            state <= ST_AR;
                        end
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
end

endmodule
