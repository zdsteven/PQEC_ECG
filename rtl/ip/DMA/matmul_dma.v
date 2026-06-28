// Dedicated matrix-multiply DMA engine.
//
// Read phase:  32-word bursts fill two alternating input buffers.
// Compute:     two external Matmul cores consume groups while DMA fills buffers.
// Result hold: 5000 * 16 native 66-bit values are retained in block RAM.
// Write phase: once all input reads have completed, finished results are
//              serialized as low32/high32/top2 and written one group per
//              uninterrupted 48-word burst while the remaining groups compute.
module matmul_dma #(
    parameter MAX_GROUPS = 5000
) (
    input             clk,
    input             resetn,

    // CPU-facing AXI slave register interface (0x1f30_0000).
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

    // ExtRAM-facing AXI master interface.
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

    // Direct request/result link to the independently attached Matmul IP.
    output            matmul_active,
    output reg [1:0]  matmul_start,
    output     [1023:0] matmul_matrix_words,
    input      [1:0]  matmul_ready,
    input      [1:0]  matmul_done,
    output reg [3:0]  matmul_result_index,
    input      [65:0] matmul_result_data0,
    input      [65:0] matmul_result_data1,

    output            finish
);

localparam [11:0] ADDR_CTRL       = 12'h000;
localparam [11:0] ADDR_STATUS     = 12'h004;
localparam [11:0] ADDR_SRC_BASE   = 12'h008;
localparam [11:0] ADDR_DST_BASE   = 12'h00c;
localparam [11:0] ADDR_GROUP_NUM  = 12'h010;
localparam [11:0] ADDR_READ_COUNT = 12'h014;
localparam [11:0] ADDR_CALC_COUNT = 12'h018;
localparam [11:0] ADDR_WRITE_COUNT= 12'h01c;
localparam [11:0] ADDR_CRC32       = 12'h020;

localparam RD_IDLE = 1'b0;
localparam RD_DATA = 1'b1;

localparam [2:0] WB_IDLE     = 3'd0;
localparam [2:0] WB_PREFETCH = 3'd1;
localparam [2:0] WB_AW       = 3'd2;
localparam [2:0] WB_SEND     = 3'd3;
localparam [2:0] WB_RESP     = 3'd4;
localparam [2:0] WB_LOAD     = 3'd5;

localparam MAX_RESULT_ELEMENTS = MAX_GROUPS * 16;

reg [31:0] src_base;
reg [31:0] dst_base;
reg [31:0] group_num;

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
reg [12:0] read_group_count;
reg [12:0] launch_group_count;
reg [12:0] calc_group_count;
reg [12:0] write_group_count;

// Two 128-byte input banks.  These are registers by design: they need many
// parallel read ports when a bank is latched into the compute core.
reg [31:0] input_buffer [0:63];
reg [1:0]  bank_valid;
reg        read_bank;
reg        active_read_bank;
reg        compute_bank;
reg [4:0]  read_beat;
reg        read_state;

reg  [3:0]    store_element;
reg           compute_complete;
reg           store_active;
reg           store_core;
reg           next_core;
reg  [1:0]    core_result_pending;
reg  [12:0]   core0_group;
reg  [12:0]   core1_group;
reg  [1023:0] matmul_matrix_hold;
wire [1023:0] launch_matrix_words;

// 66 bits is the natural result width.  Keeping this width instead of the
// external 96-bit padded format saves roughly 2.4 Mbit of block RAM.
(* ram_style = "block" *) reg [65:0] result_memory [0:MAX_RESULT_ELEMENTS-1];
reg [65:0] result_read_data;

reg [2:0]  write_state;
reg [31:0] write_address;
reg [3:0]  write_element;
reg [1:0]  write_part;
reg [5:0]  write_burst_beat;
reg [65:0] write_current_data;
reg [65:0] write_next_data;
reg [31:0] crc_value;

wire [11:0] write_offset = awaddr_hold[11:0];
wire [11:0] read_offset  = s_axi_araddr[11:0];
wire aw_handshake = s_axi_awvalid && s_axi_awready;
wire w_handshake  = s_axi_wvalid && s_axi_wready;
wire write_fire   = aw_hold_valid && w_hold_valid && !s_axi_bvalid;
wire result_write_enable = busy && store_active;
wire [12:0] result_write_group = store_core ? core1_group : core0_group;
wire [65:0] result_write_data = store_core ? matmul_result_data1 : matmul_result_data0;
wire core0_sched_ready = matmul_ready[0] && !core_result_pending[0] &&
                         !matmul_start[0] && !(store_active && !store_core) && !matmul_done[0];
wire core1_sched_ready = matmul_ready[1] && !core_result_pending[1] &&
                         !matmul_start[1] && !(store_active && store_core) && !matmul_done[1];
wire any_core_sched_ready = core0_sched_ready || core1_sched_ready;
wire selected_launch_core = (next_core && core1_sched_ready) ? 1'b1 :
                            (!next_core && core0_sched_ready) ? 1'b0 :
                            core1_sched_ready;
wire result_read_first = busy && (write_state == WB_PREFETCH);
wire result_read_next = m_axi_wvalid && m_axi_wready &&
                        (write_part == 2'd0) && (write_element != 4'd15);
wire result_read_enable = result_read_first || result_read_next;
wire [16:0] result_read_address = result_read_first ?
                   ({write_group_count, 4'b0000}) :
                   ({write_group_count, 4'b0000} + write_element + 17'd1);

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

// Reflected IEEE CRC-32 update for one complete little-endian AXI word.
// Vivado reduces this constant-polynomial loop to a parallel XOR network, so
// CRC state advances on every W handshake without applying channel backpressure.
function [31:0] crc32_update32;
    input [31:0] crc_in;
    input [31:0] data_in;
    reg [31:0] value;
    integer crc_bit;
    begin
        value = crc_in;
        for (crc_bit = 0; crc_bit < 32; crc_bit = crc_bit + 1) begin
            if (value[0] ^ data_in[crc_bit])
                value = (value >> 1) ^ 32'hedb88320;
            else
                value = value >> 1;
        end
        crc32_update32 = value;
    end
endfunction

assign s_axi_awready = !aw_hold_valid && !s_axi_bvalid;
assign s_axi_wready  = aw_hold_valid && !w_hold_valid && !s_axi_bvalid;
assign s_axi_bresp   = 2'b00;
assign s_axi_arready = !s_axi_rvalid;
assign s_axi_rresp   = 2'b00;
assign s_axi_rlast   = 1'b1;

assign finish = done;
assign matmul_active = busy;
assign matmul_matrix_words = matmul_matrix_hold;

// Read master: one complete A/B group per 32-word burst.
assign m_axi_arid    = 4'h1;
assign m_axi_araddr  = src_base + {read_group_count, 7'b0};
assign m_axi_arlen   = 8'd31;
assign m_axi_arsize  = 3'd2;
assign m_axi_arburst = 2'b01;
assign m_axi_arlock  = 1'b0;
assign m_axi_arcache = 4'b0000;
assign m_axi_arprot  = 3'b000;
assign m_axi_arvalid = busy && !compute_complete && (read_state == RD_IDLE) &&
                       (read_group_count < group_num[12:0]) && !bank_valid[read_bank];
assign m_axi_rready  = busy && (read_state == RD_DATA);

// Write master: one complete result matrix per 48-word (192-byte) burst.  This
// master is permanently routed to the dedicated ExtRAM endpoint, whose bridge
// keeps the transaction active while incrementing its registered SRAM address.
assign m_axi_awid    = 4'h2;
assign m_axi_awaddr  = write_address;
assign m_axi_awlen   = 8'd47;
assign m_axi_awsize  = 3'd2;
assign m_axi_awburst = 2'b01;
assign m_axi_awlock  = 1'b0;
assign m_axi_awcache = 4'b0000;
assign m_axi_awprot  = 3'b000;
assign m_axi_awvalid = busy && (write_state == WB_AW);
assign m_axi_wstrb   = 4'b1111;
assign m_axi_wvalid  = busy && (write_state == WB_SEND);
assign m_axi_wlast   = (write_burst_beat == 6'd47);
assign m_axi_bready  = busy && (write_state == WB_RESP);
assign m_axi_wdata   = (write_part == 2'd0) ? write_current_data[31:0] :
                       (write_part == 2'd1) ? write_current_data[63:32] :
                                              {30'd0, write_current_data[65:64]};

genvar word_index;
generate
    for (word_index = 0; word_index < 32; word_index = word_index + 1) begin: CORE_WORD_MUX
        assign launch_matrix_words[word_index*32 +: 32] =
            compute_bank ? input_buffer[word_index + 32] : input_buffer[word_index];
    end
endgenerate

// One synchronous read port and one synchronous write port.  Keeping all RAM
// accesses in this template is important: it makes Vivado infer RAMB36 blocks
// instead of expanding the 5.28-Mbit result store into LUTRAM.
always @(posedge clk) begin
    if (result_write_enable)
        result_memory[{result_write_group, 4'b0000} + store_element] <= result_write_data;
    if (result_read_enable)
        result_read_data <= result_memory[result_read_address];
end

// AXI register slave.  Configuration remains stable while busy; writes made
// during a transfer are ignored by the engine until the next start command.
always @(posedge clk) begin
    if (!resetn) begin
        src_base           <= 32'h1c400000;
        dst_base           <= 32'h1c49c400;
        group_num          <= MAX_GROUPS;
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

            if (!busy && (write_offset == ADDR_SRC_BASE))
                src_base <= apply_wstrb(src_base, wdata_hold, wstrb_hold);
            else if (!busy && (write_offset == ADDR_DST_BASE))
                dst_base <= apply_wstrb(dst_base, wdata_hold, wstrb_hold);
            else if (!busy && (write_offset == ADDR_GROUP_NUM))
                group_num <= apply_wstrb(group_num, wdata_hold, wstrb_hold);
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
                ADDR_SRC_BASE:    s_axi_rdata <= src_base;
                ADDR_DST_BASE:    s_axi_rdata <= dst_base;
                ADDR_GROUP_NUM:   s_axi_rdata <= group_num;
                ADDR_READ_COUNT:  s_axi_rdata <= {19'd0, read_group_count};
                ADDR_CALC_COUNT:  s_axi_rdata <= {19'd0, calc_group_count};
                ADDR_WRITE_COUNT: s_axi_rdata <= {19'd0, write_group_count};
                ADDR_CRC32:       s_axi_rdata <= crc_value ^ 32'hffffffff;
                default:          s_axi_rdata <= 32'd0;
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
end

integer reset_index;
always @(posedge clk) begin
    if (!resetn) begin
        busy                <= 1'b0;
        done                <= 1'b0;
        error               <= 1'b0;
        read_group_count    <= 13'd0;
        launch_group_count  <= 13'd0;
        calc_group_count    <= 13'd0;
        write_group_count   <= 13'd0;
        bank_valid          <= 2'b00;
        read_bank           <= 1'b0;
        active_read_bank    <= 1'b0;
        compute_bank        <= 1'b0;
        read_beat           <= 5'd0;
        read_state          <= RD_IDLE;
        matmul_start        <= 2'b00;
        matmul_result_index <= 4'd0;
        store_element       <= 4'd0;
        compute_complete    <= 1'b0;
        store_active        <= 1'b0;
        store_core          <= 1'b0;
        next_core           <= 1'b0;
        core_result_pending <= 2'b00;
        core0_group         <= 13'd0;
        core1_group         <= 13'd0;
        matmul_matrix_hold  <= 1024'd0;
        write_state         <= WB_IDLE;
        write_address       <= 32'd0;
        write_element       <= 4'd0;
        write_part          <= 2'd0;
        write_burst_beat    <= 6'd0;
        write_current_data  <= 66'd0;
        write_next_data     <= 66'd0;
        crc_value            <= 32'hffffffff;
        for (reset_index = 0; reset_index < 64; reset_index = reset_index + 1)
            input_buffer[reset_index] <= 32'd0;
    end else begin
        matmul_start <= 2'b00;

        if (clear_status_pulse) begin
            done  <= 1'b0;
            error <= 1'b0;
        end

        if (start_pulse) begin
            done <= 1'b0;
            if ((group_num == 32'd0) || (group_num > MAX_GROUPS) ||
                (src_base[1:0] != 2'b00) || (dst_base[1:0] != 2'b00)) begin
                busy  <= 1'b0;
                done  <= 1'b1;
                error <= 1'b1;
            end else begin
                busy                <= 1'b1;
                error               <= 1'b0;
                read_group_count    <= 13'd0;
                launch_group_count  <= 13'd0;
                calc_group_count    <= 13'd0;
                write_group_count   <= 13'd0;
                bank_valid          <= 2'b00;
                read_bank           <= 1'b0;
                active_read_bank    <= 1'b0;
                compute_bank        <= 1'b0;
                read_beat           <= 5'd0;
                read_state          <= RD_IDLE;
                store_element       <= 4'd0;
                compute_complete    <= 1'b0;
                store_active        <= 1'b0;
                store_core          <= 1'b0;
                next_core           <= 1'b0;
                core_result_pending <= 2'b00;
                core0_group         <= 13'd0;
                core1_group         <= 13'd0;
                write_state         <= WB_IDLE;
                write_address       <= dst_base;
                write_element       <= 4'd0;
                write_part          <= 2'd0;
                write_burst_beat    <= 6'd0;
                crc_value            <= 32'hffffffff;
            end
        end else if (busy) begin
            // Input DMA state machine.
            if ((read_state == RD_IDLE) && m_axi_arvalid && m_axi_arready) begin
                active_read_bank <= read_bank;
                read_beat        <= 5'd0;
                read_state       <= RD_DATA;
            end else if ((read_state == RD_DATA) && m_axi_rvalid && m_axi_rready) begin
                if (active_read_bank)
                    input_buffer[read_beat + 32] <= m_axi_rdata;
                else
                    input_buffer[read_beat] <= m_axi_rdata;

                if (m_axi_rresp != 2'b00)
                    error <= 1'b1;

                if (m_axi_rlast || (read_beat == 5'd31)) begin
                    if (!m_axi_rlast || (read_beat != 5'd31))
                        error <= 1'b1;
                    bank_valid[active_read_bank] <= 1'b1;
                    read_group_count <= read_group_count + 13'd1;
                    read_bank        <= ~read_bank;
                    read_state       <= RD_IDLE;
                end else begin
                    read_beat <= read_beat + 5'd1;
                end
            end

            // Dispatch complete input banks to either compute core.  The
            // 1024-bit holding register lets a bank be released immediately;
            // each core latches the common bus with its own start pulse.
            if ((launch_group_count < group_num[12:0]) && bank_valid[compute_bank] &&
                any_core_sched_ready) begin
                matmul_matrix_hold <= launch_matrix_words;
                bank_valid[compute_bank] <= 1'b0;
                compute_bank <= ~compute_bank;
                launch_group_count <= launch_group_count + 13'd1;
                next_core <= ~selected_launch_core;
                if (selected_launch_core) begin
                    matmul_start[1] <= 1'b1;
                    core1_group <= launch_group_count;
                end else begin
                    matmul_start[0] <= 1'b1;
                    core0_group <= launch_group_count;
                end
            end

            // Done pulses are retained until the single BRAM write port has
            // copied all sixteen results from that core.
            core_result_pending <= core_result_pending | matmul_done;
            if (!store_active) begin
                if (core_result_pending[0] || matmul_done[0]) begin
                    store_active <= 1'b1;
                    store_core <= 1'b0;
                    store_element <= 4'd0;
                    matmul_result_index <= 4'd0;
                    core_result_pending[0] <= 1'b0;
                end else if (core_result_pending[1] || matmul_done[1]) begin
                    store_active <= 1'b1;
                    store_core <= 1'b1;
                    store_element <= 4'd0;
                    matmul_result_index <= 4'd0;
                    core_result_pending[1] <= 1'b0;
                end
            end else if (store_element == 4'd15) begin
                store_active <= 1'b0;
                calc_group_count <= calc_group_count + 13'd1;
                if ((calc_group_count + 13'd1) == group_num[12:0])
                    compute_complete <= 1'b1;
            end else begin
                store_element <= store_element + 4'd1;
                matmul_result_index <= matmul_result_index + 4'd1;
            end

            // Start writeback as soon as the final input read has retired and
            // at least one complete result group is resident in BRAM.  ExtRAM
            // is then write-only, while both Matmul cores may keep computing.
            // The next 66-bit element is fetched while word1 of the current
            // element is accepted, hiding BRAM latency from the W channel.
            case (write_state)
                WB_IDLE: begin
                    if ((read_group_count == group_num[12:0]) &&
                        (read_state == RD_IDLE) &&
                        (write_group_count < calc_group_count)) begin
                        write_element     <= 4'd0;
                        write_part        <= 2'd0;
                        write_burst_beat  <= 6'd0;
                        write_state       <= WB_PREFETCH;
                    end
                end
                WB_PREFETCH: begin
                    write_element      <= 4'd0;
                    write_part         <= 2'd0;
                    write_burst_beat   <= 6'd0;
                    write_state        <= WB_LOAD;
                end
                WB_LOAD: begin
                    write_current_data <= result_read_data;
                    write_state        <= WB_AW;
                end
                WB_AW: begin
                    if (m_axi_awvalid && m_axi_awready)
                        write_state <= WB_SEND;
                end
                WB_SEND: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        crc_value <= crc32_update32(crc_value, m_axi_wdata);
                        if (write_burst_beat == 6'd47) begin
                            write_burst_beat <= 6'd0;
                            write_state      <= WB_RESP;
                        end else begin
                            write_burst_beat <= write_burst_beat + 4'd1;
                        end

                        if (write_part == 2'd0) begin
                            write_part <= 2'd1;
                        end else if (write_part == 2'd1) begin
                            write_part <= 2'd2;
                            if (write_element != 4'd15)
                                write_next_data <= result_read_data;
                        end else begin
                            write_part <= 2'd0;
                            if (write_element != 4'd15) begin
                                write_element      <= write_element + 4'd1;
                                write_current_data <= write_next_data;
                            end
                        end
                    end
                end
                WB_RESP: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        if (m_axi_bresp != 2'b00)
                            error <= 1'b1;
                        write_address <= write_address + 32'd192;
                        write_group_count <= write_group_count + 13'd1;
                        if ((write_group_count + 13'd1) == group_num[12:0]) begin
                            write_state <= WB_IDLE;
                            busy        <= 1'b0;
                            done        <= 1'b1;
                        end else if ((write_group_count + 13'd1) < calc_group_count) begin
                            write_state <= WB_PREFETCH;
                        end else begin
                            write_state <= WB_IDLE;
                        end
                    end
                end
                default: write_state <= WB_IDLE;
            endcase
        end
    end
end

endmodule
