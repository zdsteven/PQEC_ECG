// =============================================================================
// AXI 2:1 Arbiter
// =============================================================================
// 功能：将两个 AXI4 Master 复用到一个 AXI4 Slave 端口
// 用途：在 SoC 中，crossbar 的 RAM 输出 (axiOut_0) 与 matmul 的 Master 端口
//       共享同一个 RAM wrapper 的 AXI Slave 端口
// 仲裁策略：Port A (crossbar) 优先，Port B (matmul) 等待
// 事务追踪：通过 tag FIFO 记录每个未完成事务的来源端口，确保响应正确路由
// =============================================================================

module axi_arbiter_2to1 #(
    parameter ID_WIDTH   = 5,
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter MAX_TRANS  = 8    // 最大未完成事务数（FIFO 深度）
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ======================== Port A (crossbar → RAM) ========================
    // AR channel
    input  wire                     a_arvalid,
    output wire                     a_arready,
    input  wire [ADDR_WIDTH-1:0]    a_araddr,
    input  wire [ID_WIDTH-1:0]      a_arid,
    input  wire [7:0]               a_arlen,
    input  wire [2:0]               a_arsize,
    input  wire [1:0]               a_arburst,
    // R channel
    output wire                     a_rvalid,
    input  wire                     a_rready,
    output wire [DATA_WIDTH-1:0]    a_rdata,
    output wire [ID_WIDTH-1:0]      a_rid,
    output wire [1:0]               a_rresp,
    output wire                     a_rlast,
    // AW channel
    input  wire                     a_awvalid,
    output wire                     a_awready,
    input  wire [ADDR_WIDTH-1:0]    a_awaddr,
    input  wire [ID_WIDTH-1:0]      a_awid,
    input  wire [7:0]               a_awlen,
    input  wire [2:0]               a_awsize,
    input  wire [1:0]               a_awburst,
    // W channel
    input  wire                     a_wvalid,
    output wire                     a_wready,
    input  wire [DATA_WIDTH-1:0]    a_wdata,
    input  wire [DATA_WIDTH/8-1:0]  a_wstrb,
    input  wire                     a_wlast,
    // B channel
    output wire                     a_bvalid,
    input  wire                     a_bready,
    output wire [ID_WIDTH-1:0]      a_bid,
    output wire [1:0]               a_bresp,

    // ======================== Port B (matmul master) ========================
    // AR channel
    input  wire                     b_arvalid,
    output wire                     b_arready,
    input  wire [ADDR_WIDTH-1:0]    b_araddr,
    input  wire [7:0]               b_arlen,
    input  wire [2:0]               b_arsize,
    input  wire [1:0]               b_arburst,
    // R channel
    output wire                     b_rvalid,
    input  wire                     b_rready,
    output wire [DATA_WIDTH-1:0]    b_rdata,
    output wire [1:0]               b_rresp,
    output wire                     b_rlast,
    // AW channel
    input  wire                     b_awvalid,
    output wire                     b_awready,
    input  wire [ADDR_WIDTH-1:0]    b_awaddr,
    input  wire [7:0]               b_awlen,
    input  wire [2:0]               b_awsize,
    input  wire [1:0]               b_awburst,
    // W channel
    input  wire                     b_wvalid,
    output wire                     b_wready,
    input  wire [DATA_WIDTH-1:0]    b_wdata,
    input  wire [DATA_WIDTH/8-1:0]  b_wstrb,
    input  wire                     b_wlast,
    // B channel
    output wire                     b_bvalid,
    input  wire                     b_bready,
    output wire [1:0]               b_bresp,

    // ====================== Slave (→ RAM wrapper) ======================
    // AR channel
    output wire                     s_arvalid,
    input  wire                     s_arready,
    output wire [ADDR_WIDTH-1:0]    s_araddr,
    output wire [ID_WIDTH-1:0]      s_arid,
    output wire [7:0]               s_arlen,
    output wire [2:0]               s_arsize,
    output wire [1:0]               s_arburst,
    // R channel
    input  wire                     s_rvalid,
    output wire                     s_rready,
    input  wire [DATA_WIDTH-1:0]    s_rdata,
    input  wire [ID_WIDTH-1:0]      s_rid,
    input  wire [1:0]               s_rresp,
    input  wire                     s_rlast,
    // AW channel
    output wire                     s_awvalid,
    input  wire                     s_awready,
    output wire [ADDR_WIDTH-1:0]    s_awaddr,
    output wire [ID_WIDTH-1:0]      s_awid,
    output wire [7:0]               s_awlen,
    output wire [2:0]               s_awsize,
    output wire [1:0]               s_awburst,
    // W channel
    output wire                     s_wvalid,
    input  wire                     s_wready,
    output wire [DATA_WIDTH-1:0]    s_wdata,
    output wire [DATA_WIDTH/8-1:0]  s_wstrb,
    output wire                     s_wlast,
    // B channel
    input  wire                     s_bvalid,
    output wire                     s_bready,
    input  wire [ID_WIDTH-1:0]      s_bid,
    input  wire [1:0]               s_bresp
);

    // =====================================================================
    // Read Channel Arbiter
    // =====================================================================
    // Port A 优先仲裁
    wire ar_grant_a = a_arvalid;
    wire ar_grant_b = b_arvalid & ~a_arvalid;

    // AR 通道 MUX → Slave
    assign s_arvalid = a_arvalid | b_arvalid;
    assign s_araddr  = ar_grant_a ? a_araddr  : b_araddr;
    assign s_arid    = ar_grant_a ? a_arid    : {1'b1, {(ID_WIDTH-1){1'b0}}};  // Port B 使用固定 ID
    assign s_arlen   = ar_grant_a ? a_arlen   : b_arlen;
    assign s_arsize  = ar_grant_a ? a_arsize  : b_arsize;
    assign s_arburst = ar_grant_a ? a_arburst : b_arburst;

    // AR ready 路由回被授权的端口
    assign a_arready = ar_grant_a & s_arready;
    assign b_arready = ar_grant_b & s_arready;

    // -----------------------------------------------------------------
    // Read Transaction Tag FIFO
    // -----------------------------------------------------------------
    // 记录每个未完成读事务的来源：0 = Port A, 1 = Port B
    localparam FIFO_DEPTH = MAX_TRANS;
    localparam PTR_WIDTH  = $clog2(FIFO_DEPTH);

    reg [PTR_WIDTH-1:0] rd_wr_ptr, rd_rd_ptr;
    reg [PTR_WIDTH:0]   rd_count;
    reg                 rd_fifo [0:FIFO_DEPTH-1];

    wire rd_push = s_arvalid & s_arready;
    wire rd_pop  = s_rvalid  & s_rready & s_rlast;

    wire rd_fifo_empty = (rd_count == 0);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_wr_ptr <= 0;
            rd_rd_ptr <= 0;
            rd_count  <= 0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1)
                rd_fifo[i] <= 1'b0;
        end else begin
            // Push
            if (rd_push) begin
                rd_fifo[rd_wr_ptr] <= ar_grant_b;
                rd_wr_ptr <= (rd_wr_ptr == FIFO_DEPTH-1) ? 0 : rd_wr_ptr + 1;
            end
            // Pop
            if (rd_pop) begin
                rd_rd_ptr <= (rd_rd_ptr == FIFO_DEPTH-1) ? 0 : rd_rd_ptr + 1;
            end
            // Count
            case ({rd_push, rd_pop})
                2'b10:   rd_count <= rd_count + 1;
                2'b01:   rd_count <= rd_count - 1;
                default: rd_count <= rd_count;
            endcase
        end
    end

    wire rd_tag = rd_fifo_empty ? 1'b0 : rd_fifo[rd_rd_ptr];

    // R 通道 MUX: Slave → 对应的 Port
    assign a_rvalid = s_rvalid & ~rd_tag;
    assign b_rvalid = s_rvalid &  rd_tag;
    assign a_rdata  = s_rdata;
    assign a_rid    = s_rid;
    assign a_rresp  = s_rresp;
    assign a_rlast  = s_rlast;
    assign b_rdata  = s_rdata;
    assign b_rresp  = s_rresp;
    assign b_rlast  = s_rlast;
    assign s_rready = rd_tag ? b_rready : a_rready;

    // =====================================================================
    // Write Channel Arbiter
    // =====================================================================
    // Port A 优先仲裁
    wire aw_grant_a = a_awvalid;
    wire aw_grant_b = b_awvalid & ~a_awvalid;

    // AW 通道 MUX → Slave
    assign s_awvalid = a_awvalid | b_awvalid;
    assign s_awaddr  = aw_grant_a ? a_awaddr  : b_awaddr;
    assign s_awid    = aw_grant_a ? a_awid    : {1'b1, {(ID_WIDTH-1){1'b0}}};
    assign s_awlen   = aw_grant_a ? a_awlen   : b_awlen;
    assign s_awsize  = aw_grant_a ? a_awsize  : b_awsize;
    assign s_awburst = aw_grant_a ? a_awburst : b_awburst;

    // AW ready 路由
    assign a_awready = aw_grant_a & s_awready;
    assign b_awready = aw_grant_b & s_awready;

    // W 通道 MUX: 跟随 AW 授权（写数据必须跟随写地址）
    // 使用 latched grant，因为 AW 和 W 的握手可能不在同一周期
    reg w_grant_b_r;
    wire aw_accepted = s_awvalid & s_awready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            w_grant_b_r <= 1'b0;
        else if (aw_accepted)
            w_grant_b_r <= aw_grant_b;
    end

    // W 通道 MUX: 当有写数据传输时使用 latched grant
    // 优先级：如果 W 正在传输，使用 latched grant；否则使用当前 grant
    wire w_active = s_wvalid & s_wready;
    wire w_sel_b  = w_active ? w_grant_b_r : aw_grant_b;

    assign s_wvalid = a_wvalid | b_wvalid;
    assign s_wdata  = w_sel_b ? b_wdata  : a_wdata;
    assign s_wstrb  = w_sel_b ? b_wstrb  : a_wstrb;
    assign s_wlast  = w_sel_b ? b_wlast  : a_wlast;

    assign a_wready = s_wready & ~w_sel_b;
    assign b_wready = s_wready &  w_sel_b;

    // -----------------------------------------------------------------
    // Write Transaction Tag FIFO
    // -----------------------------------------------------------------
    reg [PTR_WIDTH-1:0] wr_wr_ptr, wr_rd_ptr;
    reg [PTR_WIDTH:0]   wr_count;
    reg                 wr_fifo [0:FIFO_DEPTH-1];

    wire wr_push = s_awvalid & s_awready;
    wire wr_pop  = s_bvalid  & s_bready;

    wire wr_fifo_empty = (wr_count == 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_wr_ptr <= 0;
            wr_rd_ptr <= 0;
            wr_count  <= 0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1)
                wr_fifo[i] <= 1'b0;
        end else begin
            if (wr_push) begin
                wr_fifo[wr_wr_ptr] <= aw_grant_b;
                wr_wr_ptr <= (wr_wr_ptr == FIFO_DEPTH-1) ? 0 : wr_wr_ptr + 1;
            end
            if (wr_pop) begin
                wr_rd_ptr <= (wr_rd_ptr == FIFO_DEPTH-1) ? 0 : wr_rd_ptr + 1;
            end
            case ({wr_push, wr_pop})
                2'b10:   wr_count <= wr_count + 1;
                2'b01:   wr_count <= wr_count - 1;
                default: wr_count <= wr_count;
            endcase
        end
    end

    wire wr_tag = wr_fifo_empty ? 1'b0 : wr_fifo[wr_rd_ptr];

    // B 通道 MUX: Slave → 对应的 Port
    assign a_bvalid = s_bvalid & ~wr_tag;
    assign b_bvalid = s_bvalid &  wr_tag;
    assign a_bid    = s_bid;
    assign a_bresp  = s_bresp;
    assign b_bresp  = s_bresp;
    assign s_bready = wr_tag ? b_bready : a_bready;

endmodule
