// =============================================================================
// 矩阵乘法加速器 (Matrix Multiplication Accelerator)
// =============================================================================
// 功能：计算 C[4×4] = A[4×4] × B[4×4]，无符号 32-bit 乘法，66-bit 累加
// 架构：AXI-Lite 寄存器接口 + 流水线 MAC 计算引擎
// 接口：CPU 通过寄存器写入 A/B 矩阵，启动计算，轮询状态，读取 C 结果
// =============================================================================

module matmul_axi_slave #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(
    // 时钟与复位
    input  wire                     clk,
    input  wire                     rst_n,

    // AXI4-Lite Slave（寄存器访问通道）
    // 写地址通道
    input  wire                     s_axi_awvalid,
    output reg                      s_axi_awready,
    input  wire [ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  wire [2:0]               s_axi_awprot,
    // 写数据通道
    input  wire                     s_axi_wvalid,
    output reg                      s_axi_wready,
    input  wire [DATA_WIDTH-1:0]    s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0]  s_axi_wstrb,
    // 写响应通道
    output reg                      s_axi_bvalid,
    input  wire                     s_axi_bready,
    output reg  [1:0]               s_axi_bresp,
    // 读地址通道
    input  wire                     s_axi_arvalid,
    output reg                      s_axi_arready,
    input  wire [ADDR_WIDTH-1:0]    s_axi_araddr,
    input  wire [2:0]               s_axi_arprot,
    // 读数据通道
    output reg                      s_axi_rvalid,
    input  wire                     s_axi_rready,
    output reg  [DATA_WIDTH-1:0]    s_axi_rdata,
    output reg  [1:0]               s_axi_rresp,

    // 未使用的 AXI master 端口（保持接口兼容）
    output wire                     m_axi_awvalid,
    input  wire                     m_axi_awready,
    output wire [ADDR_WIDTH-1:0]    m_axi_awaddr,
    output wire [7:0]               m_axi_awlen,
    output wire [2:0]               m_axi_awsize,
    output wire [1:0]               m_axi_awburst,
    output wire                     m_axi_wvalid,
    input  wire                     m_axi_wready,
    output wire [DATA_WIDTH-1:0]    m_axi_wdata,
    output wire                     m_axi_wlast,
    input  wire                     m_axi_bvalid,
    output wire                     m_axi_bready,
    output wire                     m_axi_arvalid,
    input  wire                     m_axi_arready,
    output wire [ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire [7:0]               m_axi_arlen,
    output wire [2:0]               m_axi_arsize,
    output wire [1:0]               m_axi_arburst,
    input  wire                     m_axi_rvalid,
    output wire                     m_axi_rready,
    input  wire [DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire                     m_axi_rlast,

    // 中断输出
    output reg                      interrupt
);

// =============================================================================
//  AXI Master 端口未使用，直接置为无效
// =============================================================================
assign m_axi_awvalid = 1'b0;
assign m_axi_awaddr  = {ADDR_WIDTH{1'b0}};
assign m_axi_awlen   = 8'h0;
assign m_axi_awsize  = 3'b0;
assign m_axi_awburst = 2'b0;
assign m_axi_wvalid  = 1'b0;
assign m_axi_wdata   = {DATA_WIDTH{1'b0}};
assign m_axi_wlast   = 1'b0;
assign m_axi_bready  = 1'b0;
assign m_axi_arvalid = 1'b0;
assign m_axi_araddr  = {ADDR_WIDTH{1'b0}};
assign m_axi_arlen   = 8'h0;
assign m_axi_arsize  = 3'b0;
assign m_axi_arburst = 2'b0;
assign m_axi_rready  = 1'b0;

// =============================================================================
//  寄存器定义
// =============================================================================
// CTRL (0x00): bit0 = start（自清零脉冲）
// STATUS (0x04): bit0 = busy, bit1 = done
// A_DATA[0..15] (0x20 ~ 0x5C): 矩阵 A 输入窗口（16 个 32-bit 元素）
// B_DATA[0..15] (0x60 ~ 0x9C): 矩阵 B 输入窗口（16 个 32-bit 元素）
// C_DATA[0..47] (0xA0 ~ 0x15C): 矩阵 C 输出窗口（16 个 66-bit 元素，每个 3 word）

localparam ADDR_CTRL      = 8'h00;
localparam ADDR_STATUS    = 8'h04;
localparam ADDR_A_BASE    = 8'h20;
localparam ADDR_B_BASE    = 8'h60;
localparam ADDR_C_BASE    = 8'hA0;

reg        ctrl_start;     // 启动脉冲
reg        status_busy;    // 忙标志
reg        status_done;    // 完成标志

reg [31:0] A [0:15];       // 矩阵 A 寄存器组
reg [31:0] B [0:15];       // 矩阵 B 寄存器组
reg [65:0] C [0:15];       // 矩阵 C 结果寄存器组（66-bit）

// =============================================================================
//  AXI4-Lite 写通道 FSM
// =============================================================================
localparam WR_IDLE = 2'b00;
localparam WR_ADDR = 2'b01;
localparam WR_DATA = 2'b10;
reg [1:0] wr_state;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_state      <= WR_IDLE;
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
        s_axi_bvalid  <= 1'b0;
        s_axi_bresp   <= 2'b00;
    end else begin
        case (wr_state)
            WR_IDLE: begin
                s_axi_bvalid <= 1'b0;
                if (s_axi_awvalid) begin
                    s_axi_awready <= 1'b1;
                    wr_state <= WR_ADDR;
                end
            end
            WR_ADDR: begin
                s_axi_awready <= 1'b0;
                if (s_axi_wvalid) begin
                    s_axi_wready <= 1'b1;
                    wr_state <= WR_DATA;
                end
            end
            WR_DATA: begin
                s_axi_wready <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
                wr_state <= WR_IDLE;
            end
            default: wr_state <= WR_IDLE;
        endcase
    end
end

// 写寄存器逻辑
integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (i = 0; i < 16; i = i + 1) begin
            A[i] <= 32'h0;
            B[i] <= 32'h0;
        end
    end else if (wr_state == WR_DATA && s_axi_wvalid && s_axi_wready) begin
        if (s_axi_awaddr[7:0] == ADDR_CTRL) begin
            // 写 CTRL 寄存器，bit0 触发 start
        end
        // A 寄存器组：偏移 0x20 ~ 0x5C
        else if (s_axi_awaddr[7:0] >= ADDR_A_BASE &&
                 s_axi_awaddr[7:0] <  ADDR_A_BASE + 64) begin
            A[(s_axi_awaddr[7:0] - ADDR_A_BASE) >> 2] <= s_axi_wdata;
        end
        // B 寄存器组：偏移 0x60 ~ 0x9C
        else if (s_axi_awaddr[7:0] >= ADDR_B_BASE &&
                 s_axi_awaddr[7:0] <  ADDR_B_BASE + 64) begin
            B[(s_axi_awaddr[7:0] - ADDR_B_BASE) >> 2] <= s_axi_wdata;
        end
    end
end

// start 脉冲生成（写 CTRL 时产生单周期脉冲）
wire start_pulse = (wr_state == WR_DATA && s_axi_wvalid && s_axi_wready &&
                    s_axi_awaddr[7:0] == ADDR_CTRL && s_axi_wdata[0]);

// =============================================================================
//  AXI4-Lite 读通道 FSM
// =============================================================================
localparam RD_IDLE = 2'b00;
localparam RD_ADDR = 2'b01;
localparam RD_DATA = 2'b10;
reg [1:0] rd_state;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_state      <= RD_IDLE;
        s_axi_arready <= 1'b0;
        s_axi_rvalid  <= 1'b0;
        s_axi_rdata   <= {DATA_WIDTH{1'b0}};
        s_axi_rresp   <= 2'b00;
    end else begin
        case (rd_state)
            RD_IDLE: begin
                s_axi_rvalid <= 1'b0;
                if (s_axi_arvalid) begin
                    s_axi_arready <= 1'b1;
                    rd_state <= RD_ADDR;
                end
            end
            RD_ADDR: begin
                s_axi_arready <= 1'b0;
                // 地址解码并输出数据
                case (s_axi_araddr[7:0])
                    ADDR_CTRL:   s_axi_rdata <= {31'h0, ctrl_start};
                    ADDR_STATUS: s_axi_rdata <= {30'h0, status_done, status_busy};
                    default: begin
                        // A 寄存器组
                        if (s_axi_araddr[7:0] >= ADDR_A_BASE &&
                            s_axi_araddr[7:0] <  ADDR_A_BASE + 64)
                            s_axi_rdata <= A[(s_axi_araddr[7:0] - ADDR_A_BASE) >> 2];
                        // B 寄存器组
                        else if (s_axi_araddr[7:0] >= ADDR_B_BASE &&
                                 s_axi_araddr[7:0] <  ADDR_B_BASE + 64)
                            s_axi_rdata <= B[(s_axi_araddr[7:0] - ADDR_B_BASE) >> 2];
                        // C 寄存器组：每个元素占 3 个 word（12 字节）
                        // byte_off = addr[7:0] - 0xA0, word_off = byte_off[7:2]
                        // elem_idx = word_off / 3, word_sel = word_off % 3
                        else if (s_axi_araddr[7:0] >= ADDR_C_BASE &&
                                 s_axi_araddr[7:0] <  ADDR_C_BASE + 192) begin
                            // 用 case 直接映射 48 个 word 到 C[0..15] 的对应字段
                            case (s_axi_araddr[7:2] - (ADDR_C_BASE >> 2))
                                // Element 0
                                6'd0:  s_axi_rdata <= C[0][31:0];
                                6'd1:  s_axi_rdata <= C[0][63:32];
                                6'd2:  s_axi_rdata <= {30'h0, C[0][65:64]};
                                // Element 1
                                6'd3:  s_axi_rdata <= C[1][31:0];
                                6'd4:  s_axi_rdata <= C[1][63:32];
                                6'd5:  s_axi_rdata <= {30'h0, C[1][65:64]};
                                // Element 2
                                6'd6:  s_axi_rdata <= C[2][31:0];
                                6'd7:  s_axi_rdata <= C[2][63:32];
                                6'd8:  s_axi_rdata <= {30'h0, C[2][65:64]};
                                // Element 3
                                6'd9:  s_axi_rdata <= C[3][31:0];
                                6'd10: s_axi_rdata <= C[3][63:32];
                                6'd11: s_axi_rdata <= {30'h0, C[3][65:64]};
                                // Element 4
                                6'd12: s_axi_rdata <= C[4][31:0];
                                6'd13: s_axi_rdata <= C[4][63:32];
                                6'd14: s_axi_rdata <= {30'h0, C[4][65:64]};
                                // Element 5
                                6'd15: s_axi_rdata <= C[5][31:0];
                                6'd16: s_axi_rdata <= C[5][63:32];
                                6'd17: s_axi_rdata <= {30'h0, C[5][65:64]};
                                // Element 6
                                6'd18: s_axi_rdata <= C[6][31:0];
                                6'd19: s_axi_rdata <= C[6][63:32];
                                6'd20: s_axi_rdata <= {30'h0, C[6][65:64]};
                                // Element 7
                                6'd21: s_axi_rdata <= C[7][31:0];
                                6'd22: s_axi_rdata <= C[7][63:32];
                                6'd23: s_axi_rdata <= {30'h0, C[7][65:64]};
                                // Element 8
                                6'd24: s_axi_rdata <= C[8][31:0];
                                6'd25: s_axi_rdata <= C[8][63:32];
                                6'd26: s_axi_rdata <= {30'h0, C[8][65:64]};
                                // Element 9
                                6'd27: s_axi_rdata <= C[9][31:0];
                                6'd28: s_axi_rdata <= C[9][63:32];
                                6'd29: s_axi_rdata <= {30'h0, C[9][65:64]};
                                // Element 10
                                6'd30: s_axi_rdata <= C[10][31:0];
                                6'd31: s_axi_rdata <= C[10][63:32];
                                6'd32: s_axi_rdata <= {30'h0, C[10][65:64]};
                                // Element 11
                                6'd33: s_axi_rdata <= C[11][31:0];
                                6'd34: s_axi_rdata <= C[11][63:32];
                                6'd35: s_axi_rdata <= {30'h0, C[11][65:64]};
                                // Element 12
                                6'd36: s_axi_rdata <= C[12][31:0];
                                6'd37: s_axi_rdata <= C[12][63:32];
                                6'd38: s_axi_rdata <= {30'h0, C[12][65:64]};
                                // Element 13
                                6'd39: s_axi_rdata <= C[13][31:0];
                                6'd40: s_axi_rdata <= C[13][63:32];
                                6'd41: s_axi_rdata <= {30'h0, C[13][65:64]};
                                // Element 14
                                6'd42: s_axi_rdata <= C[14][31:0];
                                6'd43: s_axi_rdata <= C[14][63:32];
                                6'd44: s_axi_rdata <= {30'h0, C[14][65:64]};
                                // Element 15
                                6'd45: s_axi_rdata <= C[15][31:0];
                                6'd46: s_axi_rdata <= C[15][63:32];
                                6'd47: s_axi_rdata <= {30'h0, C[15][65:64]};
                                default: s_axi_rdata <= 32'h0;
                            endcase
                        end
                        else
                            s_axi_rdata <= 32'h0;
                    end
                endcase
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;
                rd_state <= RD_DATA;
            end
            RD_DATA: begin
                if (s_axi_rready) begin
                    s_axi_rvalid <= 1'b0;
                    rd_state <= RD_IDLE;
                end
            end
            default: rd_state <= RD_IDLE;
        endcase
    end
end

// =============================================================================
//  矩阵乘法计算引擎
// =============================================================================
// 计算 C[i][j] = Σ(k=0..3) A[i][k] * B[k][j]
// 使用 4 级流水线 MAC，每级计算 4 个元素的部分积
// 总计：4 级 × 4 步 = 16 个时钟周期完成全部计算

localparam IDLE   = 3'b001;
localparam CALC   = 3'b010;
localparam DONE_S = 3'b100;
reg [2:0] calc_state;

reg [2:0] k_cnt;         // K 维度计数器 (0..3)
reg [1:0] i_cnt;         // 行计数器 (0..3)
reg [1:0] j_cnt;         // 列计数器 (0..3)
reg [65:0] accum [0:15]; // 累加器阵列（66-bit）

// 计算索引：将 (i, j) 映射到线性索引
wire [3:0] c_idx = {i_cnt, j_cnt};

// 无符号乘法：66-bit 累加
wire [63:0] product = A[{i_cnt, k_cnt}] * B[{k_cnt, j_cnt}];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        calc_state <= IDLE;
        k_cnt      <= 3'd0;
        i_cnt      <= 2'd0;
        j_cnt      <= 2'd0;
        status_busy <= 1'b0;
        status_done <= 1'b0;
        interrupt   <= 1'b0;
        ctrl_start  <= 1'b0;
        for (i = 0; i < 16; i = i + 1)
            accum[i] <= 66'h0;
        for (i = 0; i < 16; i = i + 1)
            C[i] <= 66'h0;
    end else begin
        case (calc_state)
            IDLE: begin
                interrupt <= 1'b0;
                if (start_pulse) begin
                    ctrl_start  <= 1'b1;
                    status_busy <= 1'b1;
                    status_done <= 1'b0;
                    k_cnt <= 3'd0;
                    i_cnt <= 2'd0;
                    j_cnt <= 2'd0;
                    for (i = 0; i < 16; i = i + 1)
                        accum[i] <= 66'h0;
                    calc_state <= CALC;
                end else begin
                    ctrl_start <= 1'b0;
                end
            end
            CALC: begin
                // 累加：accum[idx] += A[i][k] * B[k][j]
                accum[c_idx] <= accum[c_idx] + product;

                // 推进计数器：j 最快，i 次之，k 最慢
                if (j_cnt == 2'd3) begin
                    j_cnt <= 2'd0;
                    if (i_cnt == 2'd3) begin
                        i_cnt <= 2'd0;
                        if (k_cnt == 2'd3) begin
                            // 所有计算完成，写回结果
                            for (i = 0; i < 16; i = i + 1)
                                C[i] <= accum[i];
                            calc_state <= DONE_S;
                        end else
                            k_cnt <= k_cnt + 1;
                    end else
                        i_cnt <= i_cnt + 1;
                end else
                    j_cnt <= j_cnt + 1;
            end
            DONE_S: begin
                ctrl_start  <= 1'b0;
                status_busy <= 1'b0;
                status_done <= 1'b1;
                interrupt   <= 1'b1;
                calc_state  <= IDLE;
            end
            default: calc_state <= IDLE;
        endcase
    end
end

endmodule
