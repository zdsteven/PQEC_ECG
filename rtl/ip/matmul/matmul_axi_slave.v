// AXI register wrapper plus DMA-side request port for the matrix engine.
// Both the CPU compatibility path and the batch DMA path use the same
// matmul_batch_core instance, so all matrix arithmetic is owned by this IP.
module matmul_axi_slave (
    input             clk,
    input             resetn,

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
    input      [4:0]  s_axi_wid,
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

    input             dma_active,
    input      [3:0]  dma_start,
    input      [1023:0] dma_matrix_words,
    output     [3:0]  dma_ready,
    output     [3:0]  dma_done,
    input      [3:0]  dma_result_index,
    output     [65:0] dma_result_data0,
    output     [65:0] dma_result_data1,
    output     [65:0] dma_result_data2,
    output     [65:0] dma_result_data3
);

localparam [11:0] ADDR_CTRL      = 12'h000;
localparam [11:0] ADDR_STATUS    = 12'h004;
localparam [11:0] ADDR_SRC_BASE  = 12'h008;
localparam [11:0] ADDR_DST_BASE  = 12'h00c;
localparam [11:0] ADDR_GROUP_NUM = 12'h010;
localparam [11:0] ADDR_A_BASE    = 12'h020;
localparam [11:0] ADDR_B_BASE    = 12'h060;
localparam [11:0] ADDR_C_BASE    = 12'h0a0;

reg [31:0] src_base;
reg [31:0] dst_base;
reg [31:0] group_num;
reg [31:0] a_data [0:15];
reg [31:0] b_data [0:15];
reg [65:0] c_data [0:15];

reg [31:0] awaddr_hold;
reg [4:0]  awid_hold;
reg [7:0]  awlen_count;
reg        aw_hold_valid;
reg [31:0] wdata_hold;
reg [3:0]  wstrb_hold;
reg        w_hold_valid;
reg        clear_status_pulse;

reg        cpu_done;
reg        cpu_error;
reg        owner_dma;
reg        capture_active;
reg [3:0]  capture_index;

wire [1023:0] cpu_matrix_words;
wire [1023:0] selected_matrix_words;
wire          core0_busy;
wire          core0_done;
wire [3:0]    core0_result_index;
wire [65:0]   core0_result_data;
wire          core1_busy;
wire          core1_done;
wire [65:0]   core1_result_data;
wire          core2_busy;
wire          core2_done;
wire [65:0]   core2_result_data;
wire          core3_busy;
wire          core3_done;
wire [65:0]   core3_result_data;

wire [11:0] write_offset = awaddr_hold[11:0];
wire [11:0] read_offset  = s_axi_araddr[11:0];
wire aw_handshake = s_axi_awvalid && s_axi_awready;
wire w_handshake  = s_axi_wvalid && s_axi_wready;
wire write_fire   = aw_hold_valid && w_hold_valid && !s_axi_bvalid;
wire start_write  = write_fire && (write_offset == ADDR_CTRL) && wdata_hold[0];
wire busy_status  = core0_busy || core0_done || core1_busy || core1_done ||
                    core2_busy || core2_done || core3_busy || core3_done ||
                    capture_active;
wire dma_accept0  = dma_start[0] && dma_ready[0];
wire dma_accept1  = dma_start[1] && dma_ready[1];
wire dma_accept2  = dma_start[2] && dma_ready[2];
wire dma_accept3  = dma_start[3] && dma_ready[3];
wire cpu_accept   = start_write && !dma_active && !busy_status;
wire core0_start  = dma_accept0 || cpu_accept;

assign dma_ready[0]       = dma_active && !core0_busy && !core0_done && !capture_active;
assign dma_ready[1]       = dma_active && !core1_busy && !core1_done;
assign dma_ready[2]       = dma_active && !core2_busy && !core2_done;
assign dma_ready[3]       = dma_active && !core3_busy && !core3_done;
assign dma_done[0]        = core0_done && owner_dma;
assign dma_done[1]        = core1_done;
assign dma_done[2]        = core2_done;
assign dma_done[3]        = core3_done;
assign dma_result_data0   = core0_result_data;
assign dma_result_data1   = core1_result_data;
assign dma_result_data2   = core2_result_data;
assign dma_result_data3   = core3_result_data;
assign core0_result_index = owner_dma ? dma_result_index : capture_index;
assign selected_matrix_words = dma_accept0 ? dma_matrix_words : cpu_matrix_words;

function [31:0] apply_wstrb;
    input [31:0] old_value;
    input [31:0] new_value;
    input [3:0] strobe;
    begin
        apply_wstrb = old_value;
        if (strobe[0]) apply_wstrb[7:0]   = new_value[7:0];
        if (strobe[1]) apply_wstrb[15:8]  = new_value[15:8];
        if (strobe[2]) apply_wstrb[23:16] = new_value[23:16];
        if (strobe[3]) apply_wstrb[31:24] = new_value[31:24];
    end
endfunction

function [31:0] c_read_word;
    input [5:0] word_number;
    reg [3:0] element_number;
    reg [1:0] part_number;
    begin
        element_number = word_number / 3;
        part_number = word_number % 3;
        case (part_number)
            2'd0: c_read_word = c_data[element_number][31:0];
            2'd1: c_read_word = c_data[element_number][63:32];
            default: c_read_word = {30'd0, c_data[element_number][65:64]};
        endcase
    end
endfunction

assign s_axi_awready = !aw_hold_valid && !s_axi_bvalid;
assign s_axi_wready  = aw_hold_valid && !w_hold_valid && !s_axi_bvalid;
assign s_axi_bresp   = 2'b00;
assign s_axi_arready = !s_axi_rvalid;
assign s_axi_rresp   = 2'b00;
assign s_axi_rlast   = 1'b1;

genvar matrix_word;
generate
    for (matrix_word = 0; matrix_word < 16; matrix_word = matrix_word + 1) begin: CPU_MATRIX_PACK
        assign cpu_matrix_words[matrix_word*32 +: 32] = a_data[matrix_word];
        assign cpu_matrix_words[(matrix_word+16)*32 +: 32] = b_data[matrix_word];
    end
endgenerate

matmul_batch_core u_matmul_batch_core0 (
    .clk          (clk),
    .resetn       (resetn),
    .start        (core0_start),
    .matrix_words (selected_matrix_words),
    .busy         (core0_busy),
    .done         (core0_done),
    .result_index (core0_result_index),
    .result_data  (core0_result_data)
);

matmul_batch_core u_matmul_batch_core1 (
    .clk          (clk),
    .resetn       (resetn),
    .start        (dma_accept1),
    .matrix_words (dma_matrix_words),
    .busy         (core1_busy),
    .done         (core1_done),
    .result_index (dma_result_index),
    .result_data  (core1_result_data)
);

matmul_batch_core u_matmul_batch_core2 (
    .clk          (clk),
    .resetn       (resetn),
    .start        (dma_accept2),
    .matrix_words (dma_matrix_words),
    .busy         (core2_busy),
    .done         (core2_done),
    .result_index (dma_result_index),
    .result_data  (core2_result_data)
);

matmul_batch_core u_matmul_batch_core3 (
    .clk          (clk),
    .resetn       (resetn),
    .start        (dma_accept3),
    .matrix_words (dma_matrix_words),
    .busy         (core3_busy),
    .done         (core3_done),
    .result_index (dma_result_index),
    .result_data  (core3_result_data)
);

integer i;
always @(posedge clk) begin
    if (!resetn) begin
        src_base           <= 32'd0;
        dst_base           <= 32'd0;
        group_num          <= 32'd1;
        awaddr_hold        <= 32'd0;
        awid_hold          <= 5'd0;
        awlen_count        <= 8'd0;
        aw_hold_valid      <= 1'b0;
        wdata_hold         <= 32'd0;
        wstrb_hold         <= 4'd0;
        w_hold_valid       <= 1'b0;
        clear_status_pulse <= 1'b0;
        s_axi_bid          <= 5'd0;
        s_axi_bvalid       <= 1'b0;
        s_axi_rid          <= 5'd0;
        s_axi_rdata        <= 32'd0;
        s_axi_rvalid       <= 1'b0;
        for (i = 0; i < 16; i = i + 1) begin
            a_data[i] <= 32'd0;
            b_data[i] <= 32'd0;
        end
    end else begin
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

            if (write_offset == ADDR_SRC_BASE)
                src_base <= apply_wstrb(src_base, wdata_hold, wstrb_hold);
            else if (write_offset == ADDR_DST_BASE)
                dst_base <= apply_wstrb(dst_base, wdata_hold, wstrb_hold);
            else if (write_offset == ADDR_GROUP_NUM)
                group_num <= apply_wstrb(group_num, wdata_hold, wstrb_hold);
            else if ((write_offset >= ADDR_A_BASE) && (write_offset < ADDR_B_BASE))
                a_data[(write_offset - ADDR_A_BASE) >> 2] <=
                    apply_wstrb(a_data[(write_offset - ADDR_A_BASE) >> 2], wdata_hold, wstrb_hold);
            else if ((write_offset >= ADDR_B_BASE) && (write_offset < ADDR_C_BASE))
                b_data[(write_offset - ADDR_B_BASE) >> 2] <=
                    apply_wstrb(b_data[(write_offset - ADDR_B_BASE) >> 2], wdata_hold, wstrb_hold);
            else if ((write_offset == ADDR_STATUS) && (wdata_hold[2:1] != 2'b00))
                clear_status_pulse <= 1'b1;
        end

        if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rid    <= s_axi_arid;
            s_axi_rvalid <= 1'b1;
            if (read_offset == ADDR_STATUS)
                s_axi_rdata <= {29'd0, cpu_error, cpu_done, busy_status};
            else if (read_offset == ADDR_SRC_BASE)
                s_axi_rdata <= src_base;
            else if (read_offset == ADDR_DST_BASE)
                s_axi_rdata <= dst_base;
            else if (read_offset == ADDR_GROUP_NUM)
                s_axi_rdata <= group_num;
            else if ((read_offset >= ADDR_A_BASE) && (read_offset < ADDR_B_BASE))
                s_axi_rdata <= a_data[(read_offset - ADDR_A_BASE) >> 2];
            else if ((read_offset >= ADDR_B_BASE) && (read_offset < ADDR_C_BASE))
                s_axi_rdata <= b_data[(read_offset - ADDR_B_BASE) >> 2];
            else if ((read_offset >= ADDR_C_BASE) && (read_offset < ADDR_C_BASE + 12'h0c0))
                s_axi_rdata <= c_read_word((read_offset - ADDR_C_BASE) >> 2);
            else
                s_axi_rdata <= 32'd0;
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
end

integer result_reset_index;
always @(posedge clk) begin
    if (!resetn) begin
        cpu_done       <= 1'b0;
        cpu_error      <= 1'b0;
        owner_dma      <= 1'b0;
        capture_active <= 1'b0;
        capture_index  <= 4'd0;
        for (result_reset_index = 0; result_reset_index < 16; result_reset_index = result_reset_index + 1)
            c_data[result_reset_index] <= 66'd0;
    end else begin
        if (clear_status_pulse) begin
            cpu_done  <= 1'b0;
            cpu_error <= 1'b0;
        end

        if (dma_accept0) begin
            owner_dma <= 1'b1;
        end else if (cpu_accept) begin
            owner_dma <= 1'b0;
            cpu_done  <= 1'b0;
            cpu_error <= 1'b0;
        end

        if (core0_done && !owner_dma) begin
            capture_active <= 1'b1;
            capture_index  <= 4'd0;
        end else if (capture_active) begin
            c_data[capture_index] <= core0_result_data;
            if (capture_index == 4'd15) begin
                capture_active <= 1'b0;
                cpu_done       <= 1'b1;
            end else begin
                capture_index <= capture_index + 4'd1;
            end
        end
    end
end

endmodule
