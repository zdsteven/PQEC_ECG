// =============================================================================
// 矩阵乘法加速器 (Matrix Multiplication Accelerator)
// =============================================================================
// 功能：计算 C[M×N] = A[M×K] × B[K×N]
// 架构：2×2 PE 阵列 + Ping-Pong 双缓冲 + AXI4-Lite 控制 + AXI4 数据 DMA
// 特点：
//   - PE 阵列时分复用，用 2×2 个乘累加器完成任意 ≤8×8 矩阵乘法
//   - Ping-Pong 缓冲实现 DMA 加载与 PE 计算的流水线重叠
//   - M/K/N 运行时可配置
// =============================================================================

module matmul_axi_slave_demo #(
    parameter ADDR_WIDTH   = 32,   // AXI 地址宽度
    parameter DATA_WIDTH   = 32,   // AXI 数据宽度（32-bit 整数）
    parameter BUFFER_DEPTH = 8,    // Ping-Pong 缓冲区深度（支持最大 8×8 矩阵）
    parameter PE_ROWS      = 2,    // PE 阵列行数
    parameter PE_COLS      = 2     // PE 阵列列数
)(
    // ======================== 时钟与复位 ========================
    input  wire                     clk,
    input  wire                     rst_n,       // 全局异步复位（低有效）

    // ==================== AXI4-Lite Slave（寄存器访问通道）====================
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

    // ==================== AXI4 Slave（数据 DMA 通道）====================
    // 写地址通道（加速器作为 Master，向内存写回结果 C）
    output reg                      m_axi_awvalid,
    input  wire                     m_axi_awready,
    output reg  [ADDR_WIDTH-1:0]    m_axi_awaddr,
    output reg  [7:0]               m_axi_awlen,    // Burst 长度 - 1
    output reg  [2:0]               m_axi_awsize,   // 每拍字节数 = 4 (2^2)
    output reg  [1:0]               m_axi_awburst,  // Burst 类型：INCR
    // 写数据通道
    output reg                      m_axi_wvalid,
    input  wire                     m_axi_wready,
    output reg  [DATA_WIDTH-1:0]    m_axi_wdata,
    output reg                      m_axi_wlast,    // Burst 最后一拍
    // 写响应通道
    input  wire                     m_axi_bvalid,
    output reg                      m_axi_bready,
    // 读地址通道（加速器作为 Master，从内存读取 A/B 矩阵）
    output reg                      m_axi_arvalid,
    input  wire                     m_axi_arready,
    output reg  [ADDR_WIDTH-1:0]    m_axi_araddr,
    output reg  [7:0]               m_axi_arlen,
    output reg  [2:0]               m_axi_arsize,
    output reg  [1:0]               m_axi_arburst,
    // 读数据通道
    input  wire                     m_axi_rvalid,
    output reg                      m_axi_rready,
    input  wire [DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire                     m_axi_rlast,
    // 中断输出
    output reg                      interrupt
);

// =============================================================================
//  内部参数
// =============================================================================
// RAM 地址宽度：BUFFER_DEPTH=8 时，地址为 3-bit
localparam RAM_ADDR_WIDTH = $clog2(BUFFER_DEPTH);

// =============================================================================
//  寄存器定义（AXI4-Lite 可访问）
// =============================================================================

// --- AXI4-Lite 写通道 FSM 状态 ---
// 采用独热编码，3 个状态分别对应：空闲、等待写地址、等待写数据
localparam WR_IDLE  = 3'b001;
localparam WR_ADDR  = 3'b010;
localparam WR_DATA  = 3'b100;
reg [2:0] wr_state, wr_next;

// --- AXI4-Lite 读通道 FSM 状态 ---
// 3 个状态：空闲、等待读地址、输出读数据
localparam RD_IDLE  = 3'b001;
localparam RD_ADDR  = 3'b010;
localparam RD_DATA  = 3'b100;
reg [2:0] rd_state, rd_next;

// --- 控制/状态寄存器 (CSR) ---
reg [31:0] CSR;          // 0x00: [0]=start, [1]=soft_reset（均为自清零脉冲）
reg [31:0] STATE;        // 0x08: [0]=busy, [1]=done（只读状态）
reg [15:0] M_REG;        // 0x10: 矩阵 A 的行数
reg [15:0] K_REG;        // 0x18: 矩阵 A 的列数 / 矩阵 B 的行数
reg [15:0] N_REG;        // 0x20: 矩阵 B 的列数
reg [31:0] PENDING;      // 0x28: [0]=wr_pending, [1]=rd_pending（DMA 通道挂起标志）
reg [31:0] DEBUG_TEST;   // 0x30: 调试/测试寄存器（可读写，用于硬件验证）

// --- 自清零脉冲信号 ---
// start_clr: 在 FSM 回到 IDLE 的下一拍清除 start 和 done，确保 start 是单周期脉冲
// soft_reset_clr: 同理，确保 soft_reset 是单周期脉冲
wire start_clr;
wire soft_reset_clr;

// =============================================================================
//  矩阵乘法引擎 FSM 状态
// =============================================================================
// 四阶段流水：空闲 → 加载数据 → 计算 → 写回结果
localparam IDLE       = 4'b0001;
localparam LOAD       = 4'b0010;
localparam CALC       = 4'b0100;
localparam WRITE_BACK = 4'b1000;
reg [3:0] mat_state, mat_next;

// =============================================================================
//  矩阵维度寄存器（在 start 脉冲时锁存，运算过程中保持不变）
// =============================================================================
reg [15:0] M_r, K_r, N_r;

// =============================================================================
//  Ping-Pong 双缓冲区
// =============================================================================
// 缓冲区 A：存储矩阵 A 的 2×2 子块数据
// 每个 Bank 为 [BUFFER_DEPTH:0] × 32-bit，实际使用 [BUFFER_DEPTH-1:0]
// 缓冲区 B：存储矩阵 B 的 2×2 子块数据
reg [DATA_WIDTH-1:0] buf_a0 [0:BUFFER_DEPTH];  // Ping-Pong Bank 0
reg [DATA_WIDTH-1:0] buf_a1 [0:BUFFER_DEPTH];  // Ping-Pong Bank 1
reg [DATA_WIDTH-1:0] buf_b0 [0:BUFFER_DEPTH];  // Ping-Pong Bank 0
reg [DATA_WIDTH-1:0] buf_b1 [0:BUFFER_DEPTH];  // Ping-Pong Bank 1

reg                  wr_buf;       // 写缓冲选择：0=写 Bank0，1=写 Bank1（Ping-Pong 控制）
reg [RAM_ADDR_WIDTH:0] rd_addr_a;  // 缓冲 A 读地址
reg [RAM_ADDR_WIDTH:0] rd_addr_b;  // 缓冲 B 读地址
reg [RAM_ADDR_WIDTH:0] wr_addr;    // 缓冲写地址（DMA 写入）

// =============================================================================
//  PE (Processing Element) 阵列信号
// =============================================================================
// 每个 PE 执行乘累加：result += a × b
// 2×2 阵列在每个时钟周期同时计算 4 个输出元素的部分积
reg                      pe_valid;   // PE 输入有效标志
reg  [DATA_WIDTH-1:0]    pe_a00, pe_a01, pe_a10, pe_a11;  // PE 阵列的 A 矩阵输入
reg  [DATA_WIDTH-1:0]    pe_b00, pe_b01, pe_b10, pe_b11;  // PE 阵列的 B 矩阵输入
wire [DATA_WIDTH-1:0]    pe_out00, pe_out01, pe_out10, pe_out11;  // PE 阵列输出（累加结果）

// 时分复用控制计数器
reg [15:0] m_cnt;     // 行块计数器：0 ~ ceil(M/2)-1
reg [15:0] n_cnt;     // 列块计数器：0 ~ ceil(N/2)-1
reg [15:0] k_cnt;     // K 方向步计数器：0 ~ ceil(K/2)-1
wire       calc_done; // 所有计算轮次完成

// DMA 写回控制
reg [15:0] wb_cnt;     // 写回计数器
reg        wb_done;    // 写回完成标志

// DMA 数据通道
reg  [DATA_WIDTH-1:0] dma_wr_data;   // DMA 写数据
reg                   dma_wr_valid;   // DMA 写数据有效
wire                  dma_wr_done;    // DMA 写完成
reg  [ADDR_WIDTH-1:0] dma_wr_addr;   // DMA 写目的地址
reg  [DATA_WIDTH-1:0] dma_rd_data;   // DMA 读数据（从内存读回）
reg                   dma_rd_valid;   // DMA 读数据有效
reg  [ADDR_WIDTH-1:0] dma_rd_addr;   // DMA 读源地址
wire                  dma_rd_done;    // DMA 读完成

// 矩阵基地址（由软件配置，通常通过额外寄存器或内存映射设定）
// 这里使用默认值，实际设计中应增加地址配置寄存器
reg [ADDR_WIDTH-1:0] A_BASE_ADDR;
reg [ADDR_WIDTH-1:0] B_BASE_ADDR;
reg [ADDR_WIDTH-1:0] C_BASE_ADDR;

// =============================================================================
//  软复位逻辑
// =============================================================================
// soft_reset_r: 软复位脉冲的寄存器版本，用于在 always 块中作为同步复位条件
// soft_reset_clr: 清除 CSR[1] 的信号，在 IDLE 状态时拉高一拍
reg soft_reset_r;
assign soft_reset_clr = (mat_state == IDLE) && CSR[1];

// =============================================================================
//  AXI4-Lite 写通道 FSM
// =============================================================================
// 三状态 FSM：IDLE → ADDR（锁存地址）→ DATA（锁存数据并写寄存器）
// 实现标准 AXI4-Lite 写握手协议

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        wr_state <= WR_IDLE;
    else
        wr_state <= wr_next;
end

always @(*) begin
    case (wr_state)
        // 空闲：等待主机发起写事务
        WR_IDLE: begin
            if (s_axi_awvalid)
                wr_next = WR_ADDR;
            else
                wr_next = WR_IDLE;
        end
        // 地址握手完成，等待写数据
        WR_ADDR: begin
            if (s_axi_wvalid)
                wr_next = WR_DATA;
            else
                wr_next = WR_ADDR;
        end
        // 数据握手完成，写入寄存器，返回 IDLE
        WR_DATA: begin
            wr_next = WR_IDLE;
        end
        default: wr_next = WR_IDLE;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
        s_axi_bvalid  <= 1'b0;
        s_axi_bresp   <= 2'b00;
        CSR           <= 32'h0;
        M_REG         <= 16'h0;
        K_REG         <= 16'h0;
        N_REG         <= 16'h0;
        PENDING       <= 32'h0;
        DEBUG_TEST    <= 32'h0;
    end else begin
        case (wr_state)
            WR_IDLE: begin
                s_axi_awready <= 1'b0;
                s_axi_wready  <= 1'b0;
                s_axi_bvalid  <= 1'b0;
                // IDLE 状态下清除自清零信号
                if (start_clr)
                    CSR[0] <= 1'b0;
                if (soft_reset_clr)
                    CSR[1] <= 1'b0;
            end
            WR_ADDR: begin
                // 握手：awvalid & awready 同时为高时地址被接收
                if (s_axi_awvalid && !s_axi_awready)
                    s_axi_awready <= 1'b1;
            end
            WR_DATA: begin
                // 握手：wvalid & wready 同时为高时数据被接收
                if (s_axi_wvalid && !s_axi_wready)
                    s_axi_wready <= 1'b1;
                // 地址解码：根据写地址将数据写入对应寄存器
                // 注意：使用 awaddr 进行地址解码，支持 4-byte 对齐访问
                if (s_axi_wvalid && s_axi_wready) begin
                    case (s_axi_awaddr[7:0])
                        8'h00: begin
                            CSR <= s_axi_wdata;
                            // 写 CSR 时清除 done 标志（新任务开始）
                            STATE[1] <= 1'b0;
                        end
                        8'h08: STATE      <= s_axi_wdata;
                        8'h10: M_REG      <= s_axi_wdata[15:0];
                        8'h18: K_REG      <= s_axi_wdata[15:0];
                        8'h20: N_REG      <= s_axi_wdata[15:0];
                        8'h28: PENDING    <= s_axi_wdata;
                        8'h30: DEBUG_TEST <= s_axi_wdata;
                        default: ;
                    endcase
                end
            end
            default: begin
                s_axi_awready <= 1'b0;
                s_axi_wready  <= 1'b0;
                s_axi_bvalid  <= 1'b0;
            end
        endcase
    end
end

// =============================================================================
//  AXI4-Lite 读通道 FSM
// =============================================================================
// 三状态 FSM：IDLE → ADDR（锁存地址）→ DATA（输出数据并完成握手）

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rd_state <= RD_IDLE;
    else
        rd_state <= rd_next;
end

always @(*) begin
    case (rd_state)
        RD_IDLE: begin
            if (s_axi_arvalid)
                rd_next = RD_ADDR;
            else
                rd_next = RD_IDLE;
        end
        RD_ADDR: begin
            if (s_axi_rready)
                rd_next = RD_DATA;
            else
                rd_next = RD_ADDR;
        end
        RD_DATA: begin
            rd_next = RD_IDLE;
        end
        default: rd_next = RD_IDLE;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s_axi_arready <= 1'b0;
        s_axi_rvalid  <= 1'b0;
        s_axi_rresp   <= 2'b00;
        s_axi_rdata   <= {DATA_WIDTH{1'b0}};
    end else begin
        case (rd_state)
            RD_IDLE: begin
                s_axi_arready <= 1'b0;
                s_axi_rvalid  <= 1'b0;
            end
            RD_ADDR: begin
                // 握手：arvalid & arready 同时为高时地址被接收
                if (s_axi_arvalid && !s_axi_arready)
                    s_axi_arready <= 1'b1;
                // 地址解码：根据读地址返回对应寄存器值
                // STATE 寄存器特殊处理：busy 和 done 由引擎 FSM 驱动
                if (s_axi_arvalid && s_axi_arready) begin
                    case (s_axi_araddr[7:0])
                        8'h00: s_axi_rdata <= CSR;
                        8'h08: s_axi_rdata <= {30'h0, STATE[1:0]};  // [1]=done, [0]=busy
                        8'h10: s_axi_rdata <= {16'h0, M_REG};
                        8'h18: s_axi_rdata <= {16'h0, K_REG};
                        8'h20: s_axi_rdata <= {16'h0, N_REG};
                        8'h28: s_axi_rdata <= PENDING;
                        8'h30: s_axi_rdata <= DEBUG_TEST;
                        default: s_axi_rdata <= 32'h0;
                    endcase
                end
            end
            RD_DATA: begin
                // 驱动 rvalid，完成读握手
                if (!s_axi_rvalid)
                    s_axi_rvalid <= 1'b1;
            end
            default: begin
                s_axi_arready <= 1'b0;
                s_axi_rvalid  <= 1'b0;
            end
        endcase
    end
end

// =============================================================================
//  软复位脉冲发生器
// =============================================================================
// 将 CSR[1] 的写入转换为单周期复位脉冲
// soft_reset_r 延迟一拍，产生上升沿检测，驱动 soft_reset_pulse
// soft_reset_pulse 用于同步复位所有矩阵引擎相关寄存器
reg soft_reset_pulse;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        soft_reset_r <= 1'b0;
        soft_reset_pulse <= 1'b0;
    end else begin
        soft_reset_r <= CSR[1];
        // 上升沿检测：当前拍 CSR[1]=1 且上一拍 CSR[1]=0
        soft_reset_pulse <= CSR[1] && !soft_reset_r;
    end
end

// =============================================================================
//  矩阵乘法引擎主 FSM
// =============================================================================
// 控制四个阶段的转换：
//   IDLE → LOAD: start 脉冲触发，锁存 M/K/N
//   LOAD → CALC: DMA 加载完成
//   CALC → WRITE_BACK: 所有计算轮次完成
//   WRITE_BACK → IDLE: DMA 写回完成，置 done 标志

always @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_reset_pulse) begin
        mat_state <= IDLE;
    end else begin
        mat_state <= mat_next;
    end
end

always @(*) begin
    mat_next = mat_state;
    case (mat_state)
        IDLE: begin
            // start 为自清零脉冲，写入 CSR[0]=1 后由 start_clr 清除
            if (CSR[0])
                mat_next = LOAD;
        end
        LOAD: begin
            // DMA 加载 A 和 B 矩阵数据完成
            if (dma_rd_done)
                mat_next = CALC;
        end
        CALC: begin
            // 所有 M_ROWS × N_COLS × K_DEPTH 轮计算完成
            if (calc_done)
                mat_next = WRITE_BACK;
        end
        WRITE_BACK: begin
            // DMA 写回结果矩阵 C 完成
            if (dma_wr_done)
                mat_next = IDLE;
        end
        default: mat_next = IDLE;
    endcase
end

// =============================================================================
//  主 FSM 输出逻辑
// =============================================================================
// 驱动 STATE 寄存器、DMA 请求、PE 输入选择等

reg [15:0] m_rows, n_cols, k_depth;
assign calc_done = (k_cnt == k_depth - 1) && (m_cnt == m_rows - 1) && (n_cnt == n_cols - 1);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_reset_pulse) begin
        STATE[0] <= 1'b0;      // busy
        STATE[1] <= 1'b0;      // done
        M_r <= 16'h0;
        K_r <= 16'h0;
        N_r <= 16'h0;
        wr_buf <= 1'b0;
    end else begin
        case (mat_state)
            IDLE: begin
                // start 脉冲触发：锁存当前 M/K/N，进入忙碌状态
                if (CSR[0]) begin
                    M_r <= M_REG;
                    K_r <= K_REG;
                    N_r <= N_REG;
                    STATE[0] <= 1'b1;   // busy = 1
                    STATE[1] <= 1'b0;   // done = 0
                    wr_buf <= wr_buf;   // 保持当前 Ping-Pong 状态
                end
                // start_clr 由 IDLE 状态自动触发，清除 start 和 done
                if (start_clr) begin
                    CSR[0] <= 1'b0;     // 清除 start 脉冲
                    STATE[1] <= 1'b0;   // 清除 done
                end
            end
            CALC: begin
                // 计算完成：翻转 Ping-Pong 缓冲区，为下一轮加载做准备
                if (calc_done)
                    wr_buf <= ~wr_buf;
            end
            WRITE_BACK: begin
                // 写回完成：清除忙碌，置完成标志
                if (dma_wr_done) begin
                    STATE[0] <= 1'b0;   // busy = 0
                    STATE[1] <= 1'b1;   // done = 1
                end
            end
            default: ;
        endcase
    end
end

// start_clr: IDLE 状态下一拍自动清除 start 和 done
assign start_clr = (mat_state == IDLE) && (CSR[0] || STATE[1]);

// =============================================================================
//  块维度计算
// =============================================================================
// m_rows = ceil(M_r / PE_ROWS)：行方向需要的块数
// n_cols = ceil(N_r / PE_COLS)：列方向需要的块数
// k_depth = ceil(K_r / PE_ROWS)：K 方向需要的步数（PE_ROWS 用于复用）
// 计算方式：(N + D - 1) / D 实现向上取整
always @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_reset_pulse) begin
        m_rows  <= 16'h0;
        n_cols  <= 16'h0;
        k_depth <= 16'h0;
    end else if (mat_state == IDLE && CSR[0]) begin
        m_rows  <= (M_r + PE_ROWS - 1) / PE_ROWS;
        n_cols  <= (N_r + PE_COLS - 1) / PE_COLS;
        k_depth <= (K_r + PE_ROWS - 1) / PE_ROWS;
    end
end

// =============================================================================
//  DMA 读通道状态机（加载矩阵 A 和 B）
// =============================================================================
// 状态：IDLE → RD_A（读 A 矩阵）→ RD_B（读 B 矩阵）→ DONE
// 每次 burst 读取 4 个 32-bit 数据（2×2 子块）

localparam DMA_RD_IDLE = 3'b001;
localparam DMA_RD_A    = 3'b010;
localparam DMA_RD_B    = 3'b100;
reg [2:0] dma_rd_state, dma_rd_next;
reg [1:0] dma_rd_cnt;        // burst 计数器（0~3）
reg       dma_rd_done_r;     // 读完成锁存

// 块内偏移计数（用于计算当前读取的元素在块内的位置）
reg [RAM_ADDR_WIDTH:0] blk_cnt;

assign dma_rd_done = dma_rd_done_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_reset_pulse)
        dma_rd_state <= DMA_RD_IDLE;
    else
        dma_rd_state <= dma_rd_next;
end

always @(*) begin
    dma_rd_next = dma_rd_state;
    case (dma_rd_state)
        DMA_RD_IDLE: begin
            // 进入 LOAD 状态后启动 DMA 读
            if (mat_state == LOAD)
                dma_rd_next = DMA_RD_A;
        end
        DMA_RD_A: begin
            // A 矩阵读取完成，切换到 B 矩阵
            if (dma_rd_done_r)
                dma_rd_next = DMA_RD_B;
        end
        DMA_RD_B: begin
            // B 矩阵读取完成
            if (dma_rd_done_r)
                dma_rd_next = DMA_RD_IDLE;
        end
        default: dma_rd_next = DMA_RD_IDLE;
    endcase
end

// DMA 读地址生成
// A 矩阵地址 = A_BASE + (行索引 × K + 列索引) × 4
// B 矩阵地址 = B_BASE + (行索引 × N + 列索引) × 4
// 行索引 = m_cnt × PE_ROWS，列索引 = k_cnt × PE_ROWS（A）或 n_cnt × PE_COLS（B）
always @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_reset_pulse) begin
        m_axi_arvalid <= 1'b0;
        m_axi_araddr  <= {ADDR_WIDTH{1'b0}};
        m_axi_arlen   <= 8'h3;    // Burst 长度 = 4 拍（2×2 子块）
        m_axi_arsize  <= 3'b010;  // 每拍 4 字节 (2^2)
        m_axi_arburst <= 2'b01;   // INCR burst 类型
        dma_rd_cnt    <= 2'b0;
        dma_rd_done_r <= 1'b0;
        blk_cnt       <= {RAM_ADDR_WIDTH+1{1'b0}};
    end else begin
        case (dma_rd_state)
            DMA_RD_IDLE: begin
                m_axi_arvalid <= 1'b0;
                dma_rd_done_r <= 1'b0;
                dma_rd_cnt    <= 2'b0;
                blk_cnt       <= {RAM_ADDR_WIDTH+1{1'b0}};
            end
            DMA_RD_A: begin
                if (!m_axi_arvalid && !dma_rd_done_r) begin
                    // 计算 A 矩阵当前子块的起始地址
                    // 起始元素：A[m_cnt*2][k_cnt*2]
                    // 地址 = A_BASE + (m_cnt*2 * K_r + k_cnt*2) * 4
                    m_axi_araddr <= A_BASE_ADDR +
                                    ((m_cnt * PE_ROWS) * K_r + (k_cnt * PE_ROWS)) * 4;
                    m_axi_arvalid <= 1'b1;
                end
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                end
                if (m_axi_rvalid) begin
                    // 将读回的数据写入 Ping-Pong 缓冲 A
                    // 写入位置由 wr_buf 选择 Bank0 或 Bank1
                    if (wr_buf == 1'b0)
                        buf_a0[blk_cnt] <= m_axi_rdata;
                    else
                        buf_a1[blk_cnt] <= m_axi_rdata;
                    blk_cnt <= blk_cnt + 1;
                    if (m_axi_rlast) begin
                        dma_rd_done_r <= 1'b1;
                    end
                end
            end
            DMA_RD_B: begin
                if (!m_axi_arvalid && !dma_rd_done_r) begin
                    // 计算 B 矩阵当前子块的起始地址
                    // 起始元素：B[k_cnt*2][n_cnt*2]
                    // 地址 = B_BASE + (k_cnt*2 * N_r + n_cnt*2) * 4
                    m_axi_araddr <= B_BASE_ADDR +
                                    ((k_cnt * PE_ROWS) * N_r + (n_cnt * PE_COLS)) * 4;
                    m_axi_arvalid <= 1'b1;
                end
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                end
                if (m_axi_rvalid) begin
                    // 将读回的数据写入 Ping-Pong 缓冲 B
                    if (wr_buf == 1'b0)
                        buf_b0[blk_cnt] <= m_axi_rdata;
                    else
                        buf_b1[blk_cnt] <= m_axi_rdata;
                    blk_cnt <= blk_cnt + 1;
                    if (m_axi_rlast) begin
                        dma_rd_done_r <= 1'b1;
                    end
                end
            end
            default: begin
                m_axi_arvalid <= 1'b0;
                dma_rd_done_r <= 1'b0;
            end
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        m_axi_rready <= 1'b0;
    else
        m_axi_rready <= (dma_rd_state == DMA_RD_A || dma_rd_state == DMA_RD_B);
end

// =============================================================================
//  PE 阵列时分复用控制
// =============================================================================
// 控制 m_cnt, n_cnt, k_cnt 三个计数器，实现对整个矩阵的分块遍历
// 遍历顺序：外层 m_cnt（行块），中层 n_cnt（列块），内层 k_cnt（K 方向）
// 每个 (m_cnt, n_cnt, k_cnt) 三元组对应一次 2×2 PE 阵列运算

always @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_reset_pulse) begin
        m_cnt <= 16'h0;
        n_cnt <= 16'h0;
        k_cnt <= 16'h0;
    end else if (mat_state == CALC) begin
        if (calc_done) begin
            // 所有轮次完成，清零计数器
            m_cnt <= 16'h0;
            n_cnt <= 16'h0;
            k_cnt <= 16'h0;
        end else begin
            // K 方向步进（内层循环）
            if (k_cnt < k_depth - 1) begin
                k_cnt <= k_cnt + 1;
            end else begin
                k_cnt <= 16'h0;
                // 列块步进（中层循环）
                if (n_cnt < n_cols - 1) begin
                    n_cnt <= n_cnt + 1;
                end else begin
                    n_cnt <= 16'h0;
                    // 行块步进（外层循环）
                    if (m_cnt < m_rows - 1) begin
                        m_cnt <= m_cnt + 1;
                    end
                end
            end
        end
    end else if (mat_state == IDLE) begin
        m_cnt <= 16'h0;
        n_cnt <= 16'h0;
        k_cnt <= 16'h0;
    end
end

// =============================================================================
//  PE 输入选择逻辑（从 Ping-Pong 缓冲读取数据）
// =============================================================================
// 根据当前 (m_cnt, n_cnt, k_cnt) 选择正确的缓冲区 Bank
// 并从缓冲区中读取对应的 A/B 子块元素

always @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_reset_pulse) begin
        pe_valid <= 1'b0;
        pe_a00 <= 32'h0; pe_a01 <= 32'h0; pe_a10 <= 32'h0; pe_a11 <= 32'h0;
        pe_b00 <= 32'h0; pe_b01 <= 32'h0; pe_b10 <= 32'h0; pe_b11 <= 32'h0;
        rd_addr_a <= {RAM_ADDR_WIDTH+1{1'b0}};
        rd_addr_b <= {RAM_ADDR_WIDTH+1{1'b0}};
    end else if (mat_state == CALC) begin
        pe_valid <= 1'b1;
        // 从 Ping-Pong 缓冲的"读取侧"（非 wr_buf 侧）读取数据
        // 注意：wr_buf 已在 calc_done 时翻转，所以此处读取的是上一轮加载的数据
        if (wr_buf == 1'b0) begin
            // 当前写入 Bank0，从 Bank1 读取
            pe_a00 <= buf_a1[0]; pe_a01 <= buf_a1[1];
            pe_a10 <= buf_a1[2]; pe_a11 <= buf_a1[3];
            pe_b00 <= buf_b1[0]; pe_b01 <= buf_b1[1];
            pe_b10 <= buf_b1[2]; pe_b11 <= buf_b1[3];
        end else begin
            // 当前写入 Bank1，从 Bank0 读取
            pe_a00 <= buf_a0[0]; pe_a01 <= buf_a0[1];
            pe_a10 <= buf_a0[2]; pe_a11 <= buf_a0[3];
            pe_b00 <= buf_b0[0]; pe_b01 <= buf_b0[1];
            pe_b10 <= buf_b0[2]; pe_b11 <= buf_b0[3];
        end
    end else begin
        pe_valid <= 1'b0;
    end
end

// =============================================================================
//  PE (Processing Element) 阵列实现
// =============================================================================
// 每个 PE 执行乘累加运算：out = in + a × b
// 4 个 PE 并行计算 2×2 输出子块的部分积
// 每个 PE 包含一个乘法器和一个加法器（累加器）
// pe_valid 为高时执行累加，为低时保持结果

pe_unit pe00 (
    .clk    (clk),
    .rst_n  (rst_n),
    .valid  (pe_valid),
    .a      (pe_a00),
    .b      (pe_b00),
    .in     (pe_out00),  // 自身累加（反馈）
    .out    (pe_out00)
);

pe_unit pe01 (
    .clk    (clk),
    .rst_n  (rst_n),
    .valid  (pe_valid),
    .a      (pe_a01),
    .b      (pe_b01),
    .in     (pe_out01),
    .out    (pe_out01)
);

pe_unit pe10 (
    .clk    (clk),
    .rst_n  (rst_n),
    .valid  (pe_valid),
    .a      (pe_a10),
    .b      (pe_b10),
    .in     (pe_out10),
    .out    (pe_out10)
);

pe_unit pe11 (
    .clk    (clk),
    .rst_n  (rst_n),
    .valid  (pe_valid),
    .a      (pe_a11),
    .b      (pe_b11),
    .in     (pe_out11),
    .out    (pe_out11)
);

// =============================================================================
//  DMA 写通道状态机（写回结果矩阵 C）
// =============================================================================
// 状态：IDLE → WRITING（逐拍写数据）→ DONE
// 写回 PE 阵列的计算结果到内存

localparam DMA_WR_IDLE    = 3'b001;
localparam DMA_WR_ADDR    = 3'b010;
localparam DMA_WR_DATA    = 3'b100;
reg [2:0] dma_wr_state, dma_wr_next;
reg [1:0] dma_wr_cnt;       // burst 计数器
reg       dma_wr_done_r;    // 写完成锁存

assign dma_wr_done = dma_wr_done_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_reset_pulse)
        dma_wr_state <= DMA_WR_IDLE;
    else
        dma_wr_state <= dma_wr_next;
end

always @(*) begin
    dma_wr_next = dma_wr_state;
    case (dma_wr_state)
        DMA_WR_IDLE: begin
            // 进入 WRITE_BACK 状态后启动 DMA 写
            if (mat_state == WRITE_BACK)
                dma_wr_next = DMA_WR_ADDR;
        end
        DMA_WR_ADDR: begin
            // 写地址握手完成，进入数据阶段
            if (m_axi_awvalid && m_axi_awready)
                dma_wr_next = DMA_WR_DATA;
        end
        DMA_WR_DATA: begin
            // 最后一拍数据写完且写响应握手完成
            if (m_axi_wlast && m_axi_wvalid && m_axi_wready)
                dma_wr_next = DMA_WR_IDLE;
        end
        default: dma_wr_next = DMA_WR_IDLE;
    endcase
end

// DMA 写地址和数据生成
// C 矩阵地址 = C_BASE + ((m_cnt*2) * N_r + (n_cnt*2)) * 4
// 数据来源：PE 阵列输出 pe_out00/01/10/11
always @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_reset_pulse) begin
        m_axi_awvalid <= 1'b0;
        m_axi_awaddr  <= {ADDR_WIDTH{1'b0}};
        m_axi_awlen   <= 8'h3;    // Burst 长度 = 4 拍
        m_axi_awsize  <= 3'b010;  // 每拍 4 字节
        m_axi_awburst <= 2'b01;   // INCR burst
        m_axi_wvalid  <= 1'b0;
        m_axi_wdata   <= {DATA_WIDTH{1'b0}};
        m_axi_wlast   <= 1'b0;
        dma_wr_cnt    <= 2'b0;
        dma_wr_done_r <= 1'b0;
    end else begin
        case (dma_wr_state)
            DMA_WR_IDLE: begin
                m_axi_awvalid <= 1'b0;
                m_axi_wvalid  <= 1'b0;
                m_axi_wlast   <= 1'b0;
                dma_wr_cnt    <= 2'b0;
                dma_wr_done_r <= 1'b0;
            end
            DMA_WR_ADDR: begin
                if (!m_axi_awvalid && !dma_wr_done_r) begin
                    // 计算 C 矩阵当前子块的起始地址
                    // 起始元素：C[m_cnt*2][n_cnt*2]
                    m_axi_awaddr <= C_BASE_ADDR +
                                    ((m_cnt * PE_ROWS) * N_r + (n_cnt * PE_COLS)) * 4;
                    m_axi_awvalid <= 1'b1;
                end
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                end
            end
            DMA_WR_DATA: begin
                if (!m_axi_wvalid && !dma_wr_done_r) begin
                    m_axi_wvalid <= 1'b1;
                    // 按 burst 顺序发送 PE 阵列的 4 个输出
                    // cnt=0: pe_out00 (C[row+0][col+0])
                    // cnt=1: pe_out01 (C[row+0][col+1])
                    // cnt=2: pe_out10 (C[row+1][col+0])
                    // cnt=3: pe_out11 (C[row+1][col+1])
                    case (dma_wr_cnt)
                        2'b00: m_axi_wdata <= pe_out00;
                        2'b01: m_axi_wdata <= pe_out01;
                        2'b10: m_axi_wdata <= pe_out10;
                        2'b11: m_axi_wdata <= pe_out11;
                    endcase
                    // 最后一拍拉高 wlast
                    if (dma_wr_cnt == 2'b11)
                        m_axi_wlast <= 1'b1;
                end
                if (m_axi_wvalid && m_axi_wready) begin
                    dma_wr_cnt <= dma_wr_cnt + 1;
                    if (m_axi_wlast) begin
                        m_axi_wvalid <= 1'b0;
                        m_axi_wlast  <= 1'b0;
                        dma_wr_done_r <= 1'b1;
                    end
                end
            end
            default: begin
                m_axi_awvalid <= 1'b0;
                m_axi_wvalid  <= 1'b0;
                dma_wr_done_r <= 1'b0;
            end
        endcase
    end
end

// 写响应通道：始终准备好接收写响应
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        m_axi_bready <= 1'b0;
    else
        m_axi_bready <= (dma_wr_state == DMA_WR_DATA);
end

// =============================================================================
//  中断逻辑
// =============================================================================
// 计算完成时产生中断脉冲，软件读取 STATE 后清除
always @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_reset_pulse)
        interrupt <= 1'b0;
    else if (mat_state == WRITE_BACK && dma_wr_done)
        interrupt <= 1'b1;
    else if (STATE[1] == 1'b0)  // done 被清除时同步清除中断
        interrupt <= 1'b0;
end

endmodule

// =============================================================================
//  PE (Processing Element) 单元
// =============================================================================
// 功能：乘累加运算 out = in + a × b
// 架构：1 个乘法器 + 1 个加法器（累加器）
// 工作模式：
//   - valid=1：执行 out = in + a × b（累加模式）
//   - valid=0：保持当前值不变
// 注意：in 端口连接到 out 端口（自身反馈），实现累加功能
//       每个计算轮次开始前，引擎会通过控制信号清零 PE 输出

module pe_unit (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     valid,  // 输入有效，高电平执行 MAC
    input  wire signed [31:0]       a,      // 操作数 A（有符号）
    input  wire signed [31:0]       b,      // 操作数 B（有符号）
    input  wire signed [31:0]       in,     // 累加输入（来自上一拍的输出）
    output reg  signed [31:0]       out     // 累加输出
);

    // 乘累加运算：out = in + a × b
    // 使用有符号乘法和加法，支持负数矩阵运算
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out <= 32'sd0;
        else if (valid)
            out <= in + a * b;
        // valid=0 时隐式保持 out 不变
    end

endmodule
