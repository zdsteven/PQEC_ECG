// Dedicated matrix-multiply DMA engine.
//
// Read phase:  32-word bursts fill four rotating input buffers.
// Compute:     four external Matmul cores consume groups while DMA fills buffers.
// Result hold: 5000 * 16 native 66-bit values are retained in block RAM.
// Write phase: once all input reads have completed, finished results are
//              serialized as low32/high32/top2 and written back in long linear
//              bursts, continuing cleanly across AXI 4 KiB splits.
module matmul_dma #(
    parameter MAX_GROUPS = 5000,
    parameter RESULT_WRITEBACK = 1
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
    output reg [3:0]  matmul_start,
    output     [1023:0] matmul_matrix_words,
    input      [3:0]  matmul_ready,
    input      [3:0]  matmul_done,
    output reg [3:0]  matmul_result_index,
    input      [65:0] matmul_result_data0,
    input      [65:0] matmul_result_data1,
    input      [65:0] matmul_result_data2,
    input      [65:0] matmul_result_data3,

    output            finish,
    output reg        uart_start_pulse,
    output reg        uart_done_pulse,
    output reg [31:0] uart_crc32
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
reg [31:0] input_buffer [0:127];
reg [3:0]  bank_valid;
reg [1:0]  read_bank;
reg [1:0]  active_read_bank;
reg [1:0]  compute_bank;
reg [4:0]  read_beat;
reg        read_state;

reg  [3:0]    store_element;
reg           compute_complete;
reg           store_active;
reg  [1:0]    store_core;
reg  [1:0]    next_core;
reg  [3:0]    core_result_pending;
reg  [12:0]   core_group [0:3];
reg  [12:0]   core_result_group [0:3];
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
reg [7:0]  write_burst_beat;
reg [7:0]  write_burst_last;
reg [5:0]  write_group_word;
reg [65:0] write_current_data;
reg [65:0] write_next_data;
reg [31:0] crc_value;
reg        write_need_prefetch;
reg        write_burst_prefetched;
reg [65:0] crc_result_data;
reg        crc_result_valid;
reg        crc_finish_pending;

wire [11:0] write_offset = awaddr_hold[11:0];
wire [11:0] read_offset  = s_axi_araddr[11:0];
wire aw_handshake = s_axi_awvalid && s_axi_awready;
wire w_handshake  = s_axi_wvalid && s_axi_wready;
wire write_fire   = aw_hold_valid && w_hold_valid && !s_axi_bvalid;
wire result_write_enable = busy && store_active;
wire [12:0] result_write_group = core_result_group[store_core];
wire [65:0] result_write_data = (store_core == 2'd0) ? matmul_result_data0 :
                                (store_core == 2'd1) ? matmul_result_data1 :
                                (store_core == 2'd2) ? matmul_result_data2 :
                                                        matmul_result_data3;
// Each core snapshots all sixteen results on done, so serial result storage no
// longer prevents that core from accepting its next matrix.
wire [3:0] core_sched_ready = matmul_ready & ~matmul_start;
wire any_core_sched_ready = |core_sched_ready;
wire [3:0] core_sched_scan = {
    core_sched_ready[next_core + 2'd3],
    core_sched_ready[next_core + 2'd2],
    core_sched_ready[next_core + 2'd1],
    core_sched_ready[next_core]
};
wire [1:0] selected_launch_core =
    core_sched_scan[0] ? next_core :
    core_sched_scan[1] ? (next_core + 2'd1) :
    core_sched_scan[2] ? (next_core + 2'd2) :
                         (next_core + 2'd3);
wire read_bank_complete_now = (read_state == RD_DATA) && m_axi_rvalid && m_axi_rready &&
                              (m_axi_rlast || (read_beat == 5'd31)) &&
                              m_axi_rlast && (read_beat == 5'd31);
wire launch_filled_bank_now = read_bank_complete_now &&
                              (active_read_bank == compute_bank) &&
                              any_core_sched_ready;
wire bank_ready_for_launch = bank_valid[compute_bank] || launch_filled_bank_now;
wire result_read_first = busy && (write_state == WB_PREFETCH);
wire result_read_next_same_group = m_axi_wvalid && m_axi_wready &&
                                   (write_part == 2'd0) && (write_element != 4'd15);
wire result_read_next_cross_group = m_axi_wvalid && m_axi_wready &&
                                    (write_part == 2'd1) && (write_element == 4'd15) &&
                                    (write_burst_beat != write_burst_last);
wire result_read_next = result_read_next_same_group || result_read_next_cross_group;
wire result_read_enable = result_read_first || result_read_next;
wire [16:0] result_read_address = result_read_first ?
                   ({write_group_count, 4'b0000}) :
                   result_read_next_same_group ?
                   ({write_group_count, 4'b0000} + write_element + 17'd1) :
                   ({write_group_count + 13'd1, 4'b0000});

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

// AXI4 INCR bursts must not cross a 4 KiB boundary.  Return AWLEN for the
// largest legal fragment of the remaining linear result stream.
function [7:0] legal_burst_last;
    input [11:0] address_offset;
    input [7:0]  words_remaining;
    reg [12:0] bytes_remaining;
    reg [10:0] page_words;
    begin
        bytes_remaining = 13'h1000 - {1'b0, address_offset};
        page_words = bytes_remaining[12:2];
        if (page_words < words_remaining)
            legal_burst_last = page_words[7:0] - 8'd1;
        else
            legal_burst_last = words_remaining - 8'd1;
    end
endfunction

// CRC update for one 66-bit result in its specified three-word output order.
function [31:0] crc32_update_result;
    input [31:0] crc_in;
    input [65:0] result_in;
    reg [31:0] crc_mid0;
    reg [31:0] crc_mid1;
    begin
        crc_mid0 = crc32_update32(crc_in, result_in[31:0]);
        crc_mid1 = crc32_update32(crc_mid0, result_in[63:32]);
        crc32_update_result = crc32_update32(crc_mid1,
                                             {30'd0, result_in[65:64]});
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

// Write master: normally one 48-word burst per result matrix.  A matrix that
// straddles a 4 KiB boundary is split into the minimum two legal AXI4 bursts.
assign m_axi_awid    = 4'h2;
assign m_axi_awaddr  = write_address;
assign m_axi_awlen   = write_burst_last;
assign m_axi_awsize  = 3'd2;
assign m_axi_awburst = 2'b01;
assign m_axi_awlock  = 1'b0;
assign m_axi_awcache = 4'b0000;
assign m_axi_awprot  = 3'b000;
assign m_axi_awvalid = RESULT_WRITEBACK && busy && (write_state == WB_AW);
assign m_axi_wstrb   = 4'b1111;
assign m_axi_wvalid  = RESULT_WRITEBACK && busy && (write_state == WB_SEND);
assign m_axi_wlast   = (write_burst_beat == write_burst_last);
assign m_axi_bready  = RESULT_WRITEBACK && busy && (write_state == WB_RESP);
assign m_axi_wdata   = (write_part == 2'd0) ? write_current_data[31:0] :
                       (write_part == 2'd1) ? write_current_data[63:32] :
                                              {30'd0, write_current_data[65:64]};

genvar word_index;
generate
    for (word_index = 0; word_index < 32; word_index = word_index + 1) begin: CORE_WORD_MUX
        assign launch_matrix_words[word_index*32 +: 32] =
            (launch_filled_bank_now && (word_index == read_beat)) ?
            m_axi_rdata :
            input_buffer[{compute_bank, 5'b0} + word_index];
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

integer core_reset_index;
always @(posedge clk) begin
    if (!resetn) begin
        busy                <= 1'b0;
        done                <= 1'b0;
        error               <= 1'b0;
        read_group_count    <= 13'd0;
        launch_group_count  <= 13'd0;
        calc_group_count    <= 13'd0;
        write_group_count   <= 13'd0;
        bank_valid          <= 4'b0000;
        read_bank           <= 2'd0;
        active_read_bank    <= 2'd0;
        compute_bank        <= 2'd0;
        read_beat           <= 5'd0;
        read_state          <= RD_IDLE;
        matmul_start        <= 4'b0000;
        matmul_result_index <= 4'd0;
        store_element       <= 4'd0;
        compute_complete    <= 1'b0;
        store_active        <= 1'b0;
        store_core          <= 2'd0;
        next_core           <= 2'd0;
        core_result_pending <= 4'b0000;
        matmul_matrix_hold  <= 1024'd0;
        write_state         <= WB_IDLE;
        write_address       <= 32'd0;
        write_element       <= 4'd0;
        write_part          <= 2'd0;
        write_burst_beat    <= 8'd0;
        write_burst_last    <= 8'd47;
        write_group_word    <= 6'd0;
        write_current_data  <= 66'd0;
        write_next_data     <= 66'd0;
        crc_value            <= 32'hffffffff;
        write_need_prefetch <= 1'b1;
        write_burst_prefetched <= 1'b0;
        crc_result_data      <= 66'd0;
        crc_result_valid     <= 1'b0;
        crc_finish_pending   <= 1'b0;
        uart_start_pulse     <= 1'b0;
        uart_done_pulse      <= 1'b0;
        uart_crc32           <= 32'd0;
        // input_buffer is intentionally not reset.  bank_valid starts empty
        // and every bank is completely overwritten by 32 R beats before use;
        // clearing 4096 data bits created a very high-fanout reset path.
        for (core_reset_index = 0; core_reset_index < 4; core_reset_index = core_reset_index + 1) begin
            core_group[core_reset_index] = 13'd0;
            core_result_group[core_reset_index] = 13'd0;
        end
    end else begin
        matmul_start <= 4'b0000;
        uart_start_pulse <= 1'b0;
        uart_done_pulse  <= 1'b0;

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
                bank_valid          <= 4'b0000;
                read_bank           <= 2'd0;
                active_read_bank    <= 2'd0;
                compute_bank        <= 2'd0;
                read_beat           <= 5'd0;
                read_state          <= RD_IDLE;
                store_element       <= 4'd0;
                compute_complete    <= 1'b0;
                store_active        <= 1'b0;
                store_core          <= 2'd0;
                next_core           <= 2'd0;
                core_result_pending <= 4'b0000;
                write_state         <= WB_IDLE;
                write_address       <= dst_base;
                write_element       <= 4'd0;
                write_part          <= 2'd0;
                write_burst_beat    <= 8'd0;
                write_burst_last    <= 8'd47;
                write_group_word    <= 6'd0;
                crc_value            <= 32'hffffffff;
                write_need_prefetch <= 1'b1;
                write_burst_prefetched <= 1'b0;
                crc_result_data      <= 66'd0;
                crc_result_valid     <= 1'b0;
                crc_finish_pending   <= 1'b0;
                uart_start_pulse     <= 1'b1;
                for (core_reset_index = 0; core_reset_index < 4; core_reset_index = core_reset_index + 1) begin
                    core_group[core_reset_index] = 13'd0;
                    core_result_group[core_reset_index] = 13'd0;
                end
            end
        end else if (busy) begin
            // Input DMA state machine.
            if ((read_state == RD_IDLE) && m_axi_arvalid && m_axi_arready) begin
                active_read_bank <= read_bank;
                read_beat        <= 5'd0;
                read_state       <= RD_DATA;
            end else if ((read_state == RD_DATA) && m_axi_rvalid && m_axi_rready) begin
                input_buffer[{active_read_bank, 5'b0} + read_beat] <= m_axi_rdata;

                if (m_axi_rresp != 2'b00)
                    error <= 1'b1;

                if (m_axi_rlast || (read_beat == 5'd31)) begin
                    if (!m_axi_rlast || (read_beat != 5'd31))
                        error <= 1'b1;
                    if (!launch_filled_bank_now)
                        bank_valid[active_read_bank] <= 1'b1;
                    read_group_count <= read_group_count + 13'd1;
                    read_bank        <= read_bank + 2'd1;
                    read_state       <= RD_IDLE;
                end else begin
                    read_beat <= read_beat + 5'd1;
                end
            end

            // Dispatch complete input banks to either compute core.  The
            // 1024-bit holding register lets a bank be released immediately;
            // each core latches the common bus with its own start pulse.
            if ((launch_group_count < group_num[12:0]) && bank_ready_for_launch &&
                any_core_sched_ready) begin
                matmul_matrix_hold <= launch_matrix_words;
                if (bank_valid[compute_bank])
                    bank_valid[compute_bank] <= 1'b0;
                compute_bank <= compute_bank + 2'd1;
                launch_group_count <= launch_group_count + 13'd1;
                next_core <= selected_launch_core + 2'd1;
                matmul_start[selected_launch_core] <= 1'b1;
                core_group[selected_launch_core] <= launch_group_count;
            end

            for (core_reset_index = 0; core_reset_index < 4; core_reset_index = core_reset_index + 1) begin
                if (matmul_done[core_reset_index])
                    core_result_group[core_reset_index] <= core_group[core_reset_index];
            end

            // Done pulses are retained until the single BRAM write port has
            // copied all sixteen snapshotted results.  The originating core
            // may already be computing its next group.
            core_result_pending <= core_result_pending | matmul_done;
            if (!store_active) begin
                if ((core_result_pending[0] &&
                     (core_result_group[0] == calc_group_count)) ||
                    (matmul_done[0] && (core_group[0] == calc_group_count))) begin
                    store_active <= 1'b1;
                    store_core <= 2'd0;
                    store_element <= 4'd0;
                    matmul_result_index <= 4'd0;
                    core_result_pending[0] <= 1'b0;
                end else if ((core_result_pending[1] &&
                              (core_result_group[1] == calc_group_count)) ||
                             (matmul_done[1] && (core_group[1] == calc_group_count))) begin
                    store_active <= 1'b1;
                    store_core <= 2'd1;
                    store_element <= 4'd0;
                    matmul_result_index <= 4'd0;
                    core_result_pending[1] <= 1'b0;
                end else if ((core_result_pending[2] &&
                              (core_result_group[2] == calc_group_count)) ||
                             (matmul_done[2] && (core_group[2] == calc_group_count))) begin
                    store_active <= 1'b1;
                    store_core <= 2'd2;
                    store_element <= 4'd0;
                    matmul_result_index <= 4'd0;
                    core_result_pending[2] <= 1'b0;
                end else if ((core_result_pending[3] &&
                              (core_result_group[3] == calc_group_count)) ||
                             (matmul_done[3] && (core_group[3] == calc_group_count))) begin
                    store_active <= 1'b1;
                    store_core <= 2'd3;
                    store_element <= 4'd0;
                    matmul_result_index <= 4'd0;
                    core_result_pending[3] <= 1'b0;
                end
            end else if (store_element == 4'd15) begin
                store_active <= 1'b0;
                calc_group_count <= calc_group_count + 13'd1;
                if ((calc_group_count + 13'd1) == group_num[12:0]) begin
                    compute_complete <= 1'b1;
                    if (!RESULT_WRITEBACK)
                        crc_finish_pending <= 1'b1;
                end
            end else begin
                store_element <= store_element + 4'd1;
                matmul_result_index <= matmul_result_index + 4'd1;
            end

            // Start writeback as soon as the final input read has retired and
            // at least one complete result group is resident in BRAM.  ExtRAM
            // is then write-only, while both Matmul cores may keep computing.
            // The next 66-bit element is fetched while word1 of the current
            // element is accepted, hiding BRAM latency from the W channel.
            if (RESULT_WRITEBACK) case (write_state)
                WB_IDLE: begin
                    if ((read_group_count == group_num[12:0]) &&
                        (read_state == RD_IDLE) &&
                        (write_group_count < calc_group_count)) begin
                        write_burst_beat  <= 8'd0;
                        if (write_need_prefetch)
                            write_state <= WB_PREFETCH;
                        else
                            write_state <= WB_AW;
                    end
                end
                WB_PREFETCH: begin
                    write_element      <= 4'd0;
                    write_part         <= 2'd0;
                    write_burst_beat   <= 8'd0;
                    write_group_word   <= 6'd0;
                    if ((calc_group_count - write_group_count) >= 13'd5)
                        write_burst_last <= legal_burst_last(write_address[11:0], 8'd240);
                    else if ((calc_group_count - write_group_count) == 13'd4)
                        write_burst_last <= legal_burst_last(write_address[11:0], 8'd192);
                    else if ((calc_group_count - write_group_count) == 13'd3)
                        write_burst_last <= legal_burst_last(write_address[11:0], 8'd144);
                    else if ((calc_group_count - write_group_count) == 13'd2)
                        write_burst_last <= legal_burst_last(write_address[11:0], 8'd96);
                    else
                        write_burst_last <= legal_burst_last(write_address[11:0], 8'd48);
                    write_state        <= WB_LOAD;
                end
                WB_LOAD: begin
                    write_current_data <= result_read_data;
                    write_need_prefetch <= 1'b0;
                    write_state        <= WB_AW;
                end
                WB_AW: begin
                    if (m_axi_awvalid && m_axi_awready)
                        write_state <= WB_SEND;
                end
                WB_SEND: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        crc_value <= crc32_update32(crc_value, m_axi_wdata);
                        if (write_burst_beat == write_burst_last) begin
                            write_burst_beat <= 8'd0;
                            write_state      <= WB_RESP;
                        end else begin
                            write_burst_beat <= write_burst_beat + 8'd1;
                        end

                        if (write_group_word == 6'd47)
                            write_group_word <= 6'd0;
                        else
                            write_group_word <= write_group_word + 6'd1;

                        if (write_part == 2'd0) begin
                            write_part <= 2'd1;
                        end else if (write_part == 2'd1) begin
                            write_part <= 2'd2;
                            if (write_element != 4'd15)
                                write_next_data <= result_read_data;
                        end else begin
                            write_part <= 2'd0;
                            if (write_element == 4'd15) begin
                                write_group_count <= write_group_count + 13'd1;
                                if (write_burst_beat != write_burst_last) begin
                                    write_element      <= 4'd0;
                                    write_current_data <= result_read_data;
                                    write_need_prefetch<= 1'b0;
                                end else begin
                                    write_need_prefetch<= 1'b1;
                                end
                            end else begin
                                write_element      <= write_element + 4'd1;
                                write_current_data <= write_next_data;
                                write_need_prefetch<= 1'b0;
                            end
                        end
                    end
                end
                WB_RESP: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        if (m_axi_bresp != 2'b00)
                            error <= 1'b1;
                        write_address <= write_address +
                                         {24'd0, write_burst_last, 2'b00} + 32'd4;
                        if (write_group_count == group_num[12:0]) begin
                            write_state <= WB_IDLE;
                            busy        <= 1'b0;
                            done        <= 1'b1;
                            uart_crc32  <= crc32_update32(crc_value, m_axi_wdata) ^ 32'hffffffff;
                            uart_done_pulse <= 1'b1;
                        end else if (write_group_count < calc_group_count) begin
                            if (write_need_prefetch)
                                write_state <= WB_PREFETCH;
                            else
                                write_state <= WB_AW;
                        end else begin
                            write_state <= WB_IDLE;
                        end
                    end
                end
                default: write_state <= WB_IDLE;
            endcase

            // One pipeline register breaks the long result-index/mux-to-CRC
            // route while preserving one complete result element per cycle.
            if (!RESULT_WRITEBACK) begin
                crc_result_valid <= result_write_enable;
                if (result_write_enable)
                    crc_result_data <= result_write_data;
                if (crc_result_valid) begin
                    uart_crc32 <= crc32_update_result(crc_value, crc_result_data) ^ 32'hffffffff;
                    crc_value <= crc32_update_result(crc_value, crc_result_data);
                    if (crc_finish_pending) begin
                        crc_finish_pending <= 1'b0;
                        busy <= 1'b0;
                        done <= 1'b1;
                        uart_done_pulse <= 1'b1;
                    end
                end
            end
        end
    end
end

endmodule
