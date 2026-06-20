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
    input             s_axi_rready
);

localparam ADDR_CTRL      = 12'h000;
localparam ADDR_STATUS    = 12'h004;
localparam ADDR_SRC_BASE  = 12'h008;
localparam ADDR_DST_BASE  = 12'h00c;
localparam ADDR_GROUP_NUM = 12'h010;
localparam ADDR_A_BASE    = 12'h020;
localparam ADDR_B_BASE    = 12'h060;
localparam ADDR_C_BASE    = 12'h0a0;

reg [31:0] src_base;
reg [31:0] dst_base;
reg [31:0] group_num;
reg [31:0] a_data [0:15];
reg [31:0] b_data [0:15];
reg [65:0] c_data [0:15];

reg [31:0] awaddr_hold;
reg [4:0]  awid_hold;
reg        aw_hold_valid;
reg [31:0] wdata_hold;
reg [3:0]  wstrb_hold;
reg        w_hold_valid;

reg        busy;
reg        done;
reg        error;
reg [3:0]  calc_index;

wire       write_fire;
wire       start_fire;
wire [11:0] write_offset = awaddr_hold[11:0];
wire [11:0] read_offset  = s_axi_araddr[11:0];

assign s_axi_awready = !aw_hold_valid;
assign s_axi_wready  = !w_hold_valid;
assign s_axi_bresp   = 2'b00;
assign s_axi_arready = !s_axi_rvalid;
assign s_axi_rresp   = 2'b00;
assign s_axi_rlast   = 1'b1;

assign write_fire = aw_hold_valid && w_hold_valid && !s_axi_bvalid;
assign start_fire = write_fire && (write_offset == ADDR_CTRL) && wdata_hold[0] && !busy;

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

function [63:0] mul_u32_shift_add;
    input [31:0] lhs;
    input [31:0] rhs;
    integer bit_index;
    begin
        mul_u32_shift_add = 64'b0;
        for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1) begin
            if (rhs[bit_index]) begin
                mul_u32_shift_add = mul_u32_shift_add + ({32'b0, lhs} << bit_index);
            end
        end
    end
endfunction

function [65:0] calc_c_element;
    input [3:0] index;
    reg [1:0] row;
    reg [1:0] col;
    begin
        row = index[3:2];
        col = index[1:0];
        calc_c_element = {2'b0, mul_u32_shift_add(a_data[{row, 2'd0}], b_data[{2'd0, col}])}
                       + {2'b0, mul_u32_shift_add(a_data[{row, 2'd1}], b_data[{2'd1, col}])}
                       + {2'b0, mul_u32_shift_add(a_data[{row, 2'd2}], b_data[{2'd2, col}])}
                       + {2'b0, mul_u32_shift_add(a_data[{row, 2'd3}], b_data[{2'd3, col}])};
    end
endfunction

function [31:0] c_read_word;
    input [5:0] word_index;
    begin
        case (word_index)
            6'd0:  c_read_word = c_data[0][31:0];
            6'd1:  c_read_word = c_data[0][63:32];
            6'd2:  c_read_word = {30'b0, c_data[0][65:64]};
            6'd3:  c_read_word = c_data[1][31:0];
            6'd4:  c_read_word = c_data[1][63:32];
            6'd5:  c_read_word = {30'b0, c_data[1][65:64]};
            6'd6:  c_read_word = c_data[2][31:0];
            6'd7:  c_read_word = c_data[2][63:32];
            6'd8:  c_read_word = {30'b0, c_data[2][65:64]};
            6'd9:  c_read_word = c_data[3][31:0];
            6'd10: c_read_word = c_data[3][63:32];
            6'd11: c_read_word = {30'b0, c_data[3][65:64]};
            6'd12: c_read_word = c_data[4][31:0];
            6'd13: c_read_word = c_data[4][63:32];
            6'd14: c_read_word = {30'b0, c_data[4][65:64]};
            6'd15: c_read_word = c_data[5][31:0];
            6'd16: c_read_word = c_data[5][63:32];
            6'd17: c_read_word = {30'b0, c_data[5][65:64]};
            6'd18: c_read_word = c_data[6][31:0];
            6'd19: c_read_word = c_data[6][63:32];
            6'd20: c_read_word = {30'b0, c_data[6][65:64]};
            6'd21: c_read_word = c_data[7][31:0];
            6'd22: c_read_word = c_data[7][63:32];
            6'd23: c_read_word = {30'b0, c_data[7][65:64]};
            6'd24: c_read_word = c_data[8][31:0];
            6'd25: c_read_word = c_data[8][63:32];
            6'd26: c_read_word = {30'b0, c_data[8][65:64]};
            6'd27: c_read_word = c_data[9][31:0];
            6'd28: c_read_word = c_data[9][63:32];
            6'd29: c_read_word = {30'b0, c_data[9][65:64]};
            6'd30: c_read_word = c_data[10][31:0];
            6'd31: c_read_word = c_data[10][63:32];
            6'd32: c_read_word = {30'b0, c_data[10][65:64]};
            6'd33: c_read_word = c_data[11][31:0];
            6'd34: c_read_word = c_data[11][63:32];
            6'd35: c_read_word = {30'b0, c_data[11][65:64]};
            6'd36: c_read_word = c_data[12][31:0];
            6'd37: c_read_word = c_data[12][63:32];
            6'd38: c_read_word = {30'b0, c_data[12][65:64]};
            6'd39: c_read_word = c_data[13][31:0];
            6'd40: c_read_word = c_data[13][63:32];
            6'd41: c_read_word = {30'b0, c_data[13][65:64]};
            6'd42: c_read_word = c_data[14][31:0];
            6'd43: c_read_word = c_data[14][63:32];
            6'd44: c_read_word = {30'b0, c_data[14][65:64]};
            6'd45: c_read_word = c_data[15][31:0];
            6'd46: c_read_word = c_data[15][63:32];
            6'd47: c_read_word = {30'b0, c_data[15][65:64]};
            default: c_read_word = 32'b0;
        endcase
    end
endfunction

integer i;
always @(posedge clk) begin
    if (!resetn) begin
        src_base      <= 32'b0;
        dst_base      <= 32'b0;
        group_num     <= 32'd1;
        awaddr_hold   <= 32'b0;
        awid_hold     <= 5'b0;
        aw_hold_valid <= 1'b0;
        wdata_hold    <= 32'b0;
        wstrb_hold    <= 4'b0;
        w_hold_valid  <= 1'b0;
        s_axi_bid     <= 5'b0;
        s_axi_bvalid  <= 1'b0;
        s_axi_rid     <= 5'b0;
        s_axi_rdata   <= 32'b0;
        s_axi_rvalid  <= 1'b0;
        busy          <= 1'b0;
        done          <= 1'b0;
        error         <= 1'b0;
        calc_index    <= 4'b0;

        for (i = 0; i < 16; i = i + 1) begin
            a_data[i] <= 32'b0;
            b_data[i] <= 32'b0;
            c_data[i] <= 66'b0;
        end
    end else begin
        if (s_axi_awvalid && s_axi_awready) begin
            awaddr_hold   <= s_axi_awaddr;
            awid_hold     <= s_axi_awid;
            aw_hold_valid <= 1'b1;
        end

        if (s_axi_wvalid && s_axi_wready) begin
            wdata_hold   <= s_axi_wdata;
            wstrb_hold   <= s_axi_wstrb;
            w_hold_valid <= 1'b1;
        end

        if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
        end

        if (write_fire) begin
            s_axi_bid     <= awid_hold;
            s_axi_bvalid  <= 1'b1;
            aw_hold_valid <= 1'b0;
            w_hold_valid  <= 1'b0;

            if (write_offset == ADDR_SRC_BASE) begin
                src_base <= apply_wstrb(src_base, wdata_hold, wstrb_hold);
            end else if (write_offset == ADDR_DST_BASE) begin
                dst_base <= apply_wstrb(dst_base, wdata_hold, wstrb_hold);
            end else if (write_offset == ADDR_GROUP_NUM) begin
                group_num <= apply_wstrb(group_num, wdata_hold, wstrb_hold);
            end else if ((write_offset >= ADDR_A_BASE) && (write_offset < ADDR_B_BASE)) begin
                a_data[(write_offset - ADDR_A_BASE) >> 2] <=
                    apply_wstrb(a_data[(write_offset - ADDR_A_BASE) >> 2], wdata_hold, wstrb_hold);
            end else if ((write_offset >= ADDR_B_BASE) && (write_offset < ADDR_C_BASE)) begin
                b_data[(write_offset - ADDR_B_BASE) >> 2] <=
                    apply_wstrb(b_data[(write_offset - ADDR_B_BASE) >> 2], wdata_hold, wstrb_hold);
            end else if (write_offset == ADDR_STATUS) begin
                if (wdata_hold[1]) done <= 1'b0;
                if (wdata_hold[2]) error <= 1'b0;
            end else if ((write_offset != ADDR_CTRL) && (write_offset < ADDR_C_BASE)) begin
                error <= 1'b1;
            end
        end

        if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rid    <= s_axi_arid;
            s_axi_rvalid <= 1'b1;

            if (read_offset == ADDR_CTRL) begin
                s_axi_rdata <= 32'b0;
            end else if (read_offset == ADDR_STATUS) begin
                s_axi_rdata <= {29'b0, error, done, busy};
            end else if (read_offset == ADDR_SRC_BASE) begin
                s_axi_rdata <= src_base;
            end else if (read_offset == ADDR_DST_BASE) begin
                s_axi_rdata <= dst_base;
            end else if (read_offset == ADDR_GROUP_NUM) begin
                s_axi_rdata <= group_num;
            end else if ((read_offset >= ADDR_A_BASE) && (read_offset < ADDR_B_BASE)) begin
                s_axi_rdata <= a_data[(read_offset - ADDR_A_BASE) >> 2];
            end else if ((read_offset >= ADDR_B_BASE) && (read_offset < ADDR_C_BASE)) begin
                s_axi_rdata <= b_data[(read_offset - ADDR_B_BASE) >> 2];
            end else if ((read_offset >= ADDR_C_BASE) && (read_offset < (ADDR_C_BASE + 12'h0c0))) begin
                s_axi_rdata <= c_read_word((read_offset - ADDR_C_BASE) >> 2);
            end else begin
                s_axi_rdata <= 32'b0;
            end
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end

        if (start_fire) begin
            busy       <= 1'b1;
            done       <= 1'b0;
            error      <= 1'b0;
            calc_index <= 4'd0;
        end else if (busy) begin
            c_data[calc_index] <= calc_c_element(calc_index);
            if (calc_index == 4'd15) begin
                busy       <= 1'b0;
                done       <= 1'b1;
                calc_index <= 4'd0;
            end else begin
                calc_index <= calc_index + 4'd1;
            end
        end
    end
end

endmodule
