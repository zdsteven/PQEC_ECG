/*------------------------------------------------------------------------------
--------------------------------------------------------------------------------
Copyright (c) 2016, Loongson Technology Corporation Limited.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this 
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, 
this list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.

3. Neither the name of Loongson Technology Corporation Limited nor the names of 
its contributors may be used to endorse or promote products derived from this 
software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED 
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
DISCLAIMED. IN NO EVENT SHALL LOONGSON TECHNOLOGY CORPORATION LIMITED BE LIABLE
TO ANY PARTY FOR DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE 
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--------------------------------------------------------------------------------
------------------------------------------------------------------------------*/

module axi_wrap_ram_sp_external (
    input         aclk,
    input         aresetn,
    input         fast_clk180,
    input         fast_sample_clk,
    //ar
    input  [4 :0] axi_arid   ,
    input  [31:0] axi_araddr ,
    input  [7 :0] axi_arlen  ,
    input  [2 :0] axi_arsize ,
    input  [1 :0] axi_arburst,
    input         axi_arlock ,
    input  [3 :0] axi_arcache,
    input  [2 :0] axi_arprot ,
    input         axi_arvalid,
    output        axi_arready,
    //r
    output [4 :0] axi_rid    ,
    output [31:0] axi_rdata  ,
    output [1 :0] axi_rresp  ,
    output        axi_rlast  ,
    output        axi_rvalid ,
    input         axi_rready ,
    //aw
    input  [4 :0] axi_awid   ,
    input  [31:0] axi_awaddr ,
    input  [7 :0] axi_awlen  ,
    input  [2 :0] axi_awsize ,
    input  [1 :0] axi_awburst,
    input         axi_awlock ,
    input  [3 :0] axi_awcache,
    input  [2 :0] axi_awprot ,
    input         axi_awvalid,
    output        axi_awready,
    //w
    input  [31:0] axi_wdata  ,
    input  [3 :0] axi_wstrb  ,
    input         axi_wlast  ,
    input         axi_wvalid ,
    output        axi_wready ,
    //b
    output [4 :0] axi_bid    ,
    output [1 :0] axi_bresp  ,
    output        axi_bvalid ,
    input         axi_bready ,

    // Evaluation-only direct ExtRAM read stream.  The address is a physical
    // ExtRAM word address; each accepted output pair contains two consecutive
    // words, with data0 preceding data1 in memory.
    input         fast_read_active,
    input  [19:0] fast_read_base_word,
    input  [16:0] fast_read_pair_count,
    output        fast_pair_valid,
    output [31:0] fast_pair_data0,
    output [31:0] fast_pair_data1,
    input         fast_pair_ready,

    //BaseRAM信号
    input  [31:0] base_ram_data_i,  //BaseRAM数据，低8位与CPLD串口控制器共享
    output [31:0] base_ram_data_o,
    output [31:0] base_ram_data_oe,
    output [19:0] base_ram_addr, //BaseRAM地址
    output [ 3:0] base_ram_be_n,  //BaseRAM字节使能，低有效。如果不使用字节使能，请保持为0
    output  base_ram_ce_n,       //BaseRAM片选，低有效
    output  base_ram_oe_n,       //BaseRAM读使能，低有效
    output  base_ram_we_n,       //BaseRAM写使能，低有效

    //ExtRAM信号
    input  [31:0] ext_ram_data_i,  //ExtRAM数据
    output [31:0] ext_ram_data_o,
    output [31:0] ext_ram_data_oe,
    output [19:0] ext_ram_addr, //ExtRAM地址
    output [ 3:0] ext_ram_be_n,  //ExtRAM字节使能，低有效。如果不使用字节使能，请保持为0
    output  ext_ram_ce_n,       //ExtRAM片选，低有效
    output  ext_ram_oe_n,       //ExtRAM读使能，低有效
    output  ext_ram_we_n       //ExtRAM写使能，低有效
);


//ram axi
//ar
wire [4 :0] ram_arid   ;
wire [31:0] ram_araddr ;
wire [7 :0] ram_arlen  ;
wire [2 :0] ram_arsize ;
wire [1 :0] ram_arburst;
wire        ram_arlock ;
wire [3 :0] ram_arcache;
wire [2 :0] ram_arprot ;
wire        ram_arvalid;
wire        ram_arready;
//r
wire [4 :0] ram_rid    ;
wire [31:0] ram_rdata  ;
wire [1 :0] ram_rresp  ;
wire        ram_rlast  ;
wire        ram_rvalid ;
wire        ram_rready ;
//aw
wire [4 :0] ram_awid   ;
wire [31:0] ram_awaddr ;
wire [7 :0] ram_awlen  ;
wire [2 :0] ram_awsize ;
wire [1 :0] ram_awburst;
wire        ram_awlock ;
wire [3 :0] ram_awcache;
wire [2 :0] ram_awprot ;
wire        ram_awvalid;
wire        ram_awready;
//w
wire [31:0] ram_wdata  ;
wire [3 :0] ram_wstrb  ;
wire        ram_wlast  ;
wire        ram_wvalid ;
wire        ram_wready ;
//b
wire [4 :0] ram_bid    ;
wire [1 :0] ram_bresp  ;
wire        ram_bvalid ;
wire        ram_bready ;

//sram signal
wire  [31:0]    soc_sram_addr;
wire            soc_sram_cs;
wire            soc_sram_we;
wire  [3:0]     soc_sram_be;
wire  [31:0]    soc_sram_wdata;
wire  [31:0]    soc_sram_rdata;

wire [19:0] fast_ext_addr;
wire [3:0]  fast_ext_be_n;
wire        fast_ext_ce_n;
wire        fast_ext_oe_n;
wire        fast_ext_we_n;
wire        fast_ext_bus_active;
wire [31:0] ext_ram_data_in;

//ar
assign ram_arid    = axi_arid   ;
assign ram_araddr  = axi_araddr ;
assign ram_arlen   = axi_arlen  ;
assign ram_arsize  = axi_arsize ;
assign ram_arburst = axi_arburst;
assign ram_arlock  = axi_arlock ;
assign ram_arcache = axi_arcache;
assign ram_arprot  = axi_arprot ;
assign ram_arvalid = axi_arvalid;
assign axi_arready = ram_arready;
//r
assign axi_rid    = axi_rvalid ? ram_rid   :  5'd0 ;
assign axi_rdata  = axi_rvalid ? ram_rdata : 32'd0 ;
assign axi_rresp  = axi_rvalid ? ram_rresp :  2'd0 ;
assign axi_rlast  = axi_rvalid ? ram_rlast :  1'd0 ;
assign axi_rvalid = ram_rvalid;
assign ram_rready = axi_rready;
//aw
assign ram_awid    = axi_awid   ;
assign ram_awaddr  = axi_awaddr ;
assign ram_awlen   = axi_awlen  ;
assign ram_awsize  = axi_awsize ;
assign ram_awburst = axi_awburst;
assign ram_awlock  = axi_awlock ;
assign ram_awcache = axi_awcache;
assign ram_awprot  = axi_awprot ;
assign ram_awvalid = axi_awvalid;
assign axi_awready = ram_awready;
//w
assign ram_wdata  = axi_wdata  ;
assign ram_wstrb  = axi_wstrb  ;
assign ram_wlast  = axi_wlast  ;
assign ram_wvalid = axi_wvalid ;
assign axi_wready = ram_wready ;
//b
assign axi_bid    = axi_bvalid ? ram_bid   : 5'd0 ;
assign axi_bresp  = axi_bvalid ? ram_bresp : 2'd0 ;
assign axi_bvalid = ram_bvalid ;
assign ram_bready = axi_bready ;


axi2sram_sp_external #(
    .AXI_ID_WIDTH   ( 5  ),
    .AXI_ADDR_WIDTH ( 32 ),
    .AXI_DATA_WIDTH ( 32 ))
 u_axi_sram_sp (
    .clk                     ( aclk         ),
    .resetn                  ( aresetn      ),

    .s_araddr                ( ram_araddr    ),
    .s_arburst               ( ram_arburst   ),
    .s_arcache               ( ram_arcache   ),
    .s_arid                  ( ram_arid      ),
    .s_arlen                 ( ram_arlen     ),
    .s_arlock                ( ram_arlock    ),
    .s_arprot                ( ram_arprot    ),
    .s_arsize                ( ram_arsize    ),
    .s_arvalid               ( ram_arvalid   ),
    .s_awaddr                ( ram_awaddr    ),
    .s_awburst               ( ram_awburst   ),
    .s_awcache               ( ram_awcache   ),
    .s_awid                  ( ram_awid      ),
    .s_awlen                 ( ram_awlen     ),
    .s_awlock                ( ram_awlock    ),
    .s_awprot                ( ram_awprot    ),
    .s_awsize                ( ram_awsize    ),
    .s_awvalid               ( ram_awvalid   ),
    .s_bready                ( ram_bready    ),
    .s_rready                ( ram_rready    ),
    .s_wdata                 ( ram_wdata     ),
    .s_wlast                 ( ram_wlast     ),
    .s_wstrb                 ( ram_wstrb     ),
    .s_wvalid                ( ram_wvalid    ),
    .s_arready               ( ram_arready   ),
    .s_awready               ( ram_awready   ),
    .s_bid                   ( ram_bid       ),
    .s_bresp                 ( ram_bresp     ),
    .s_bvalid                ( ram_bvalid    ),
    .s_rdata                 ( ram_rdata     ),
    .s_rid                   ( ram_rid       ),
    .s_rlast                 ( ram_rlast     ),
    .s_rresp                 ( ram_rresp     ),
    .s_rvalid                ( ram_rvalid    ),
    .s_wready                ( ram_wready    ),

    .req_o                   ( soc_sram_cs       ),
    .we_o                    ( soc_sram_we       ),
    .addr_o                  ( soc_sram_addr     ),
    .be_o                    ( soc_sram_be       ),
    .data_o                  ( soc_sram_wdata    ),
    .data_i                  ( soc_sram_rdata    )
);

wire choose_sram = soc_sram_addr[22];//1:ExtRAM 0:BaseRAM
wire [3:0] be_out = soc_sram_we ? soc_sram_be : 4'b1111;

assign base_ram_addr = soc_sram_addr[21:2];
assign base_ram_be_n = choose_sram ? 4'b1111 : ~be_out;
assign base_ram_ce_n = ~(soc_sram_cs & (~choose_sram));
assign base_ram_oe_n = soc_sram_we | choose_sram;
assign base_ram_we_n = ~(soc_sram_we & (~choose_sram));
assign base_ram_data_o = soc_sram_wdata;
assign base_ram_data_oe = {32{~((~choose_sram) & soc_sram_cs & soc_sram_we)}};

// Explicit input buffers let the IDDRs in the evaluation PHY pack into the
// input I/O logic.  Verilator has no Xilinx UNISIM library, so lint and the
// standalone PHY test use the equivalent inferred tri-state connection.
genvar ext_data_bit;
generate
for (ext_data_bit = 0; ext_data_bit < 32; ext_data_bit = ext_data_bit + 1) begin: gen_ext_data_iobuf
`ifdef USE_EVALUATION_UART_SRAM
`ifdef VERILATOR
    assign ext_ram_data_in[ext_data_bit] = ext_ram_data_i[ext_data_bit];
    assign ext_ram_data_o[ext_data_bit] = 1'b0;
    assign ext_ram_data_oe[ext_data_bit] = 1'b1;
`else
    assign ext_ram_data_in[ext_data_bit] = ext_ram_data_i[ext_data_bit];
    assign ext_ram_data_o[ext_data_bit] = 1'b0;
    assign ext_ram_data_oe[ext_data_bit] = 1'b1;
`endif
`else
    assign ext_ram_data_in[ext_data_bit] = ext_ram_data_i[ext_data_bit];
    assign ext_ram_data_o[ext_data_bit] = soc_sram_wdata[ext_data_bit];
    assign ext_ram_data_oe[ext_data_bit] = ~(choose_sram & soc_sram_cs & soc_sram_we);
`endif
end
endgenerate

assign soc_sram_rdata = choose_sram ? ext_ram_data_in : base_ram_data_i;

`ifdef USE_EVALUATION_UART_SRAM
// ODDR Q must drive the output buffer directly.  A fabric mux after the ODDR
// prevents OLOGIC packing, so the scored build gives the private reader sole
// ownership of ExtRAM pins.  The DMA AXI master is protocol-idle in this mode;
// BaseRAM remains on the unchanged legacy AXI path.  The non-evaluation branch
// below retains ordinary AXI ExtRAM operation.
assign ext_ram_addr = fast_ext_addr;
assign ext_ram_be_n = fast_ext_be_n;
assign ext_ram_ce_n = fast_ext_ce_n;
assign ext_ram_oe_n = fast_ext_oe_n;
assign ext_ram_we_n = fast_ext_we_n;

eval_ext_sram_ddr_phy u_eval_ext_sram_ddr_phy (
    .clk                  (aclk),
    .clk_180              (fast_clk180),
    .sample_clk           (fast_sample_clk),
    .resetn               (aresetn),
    .fast_read_active     (fast_read_active),
    .fast_read_base_word  (fast_read_base_word),
    .fast_read_pair_count (fast_read_pair_count),
    .fast_pair_valid      (fast_pair_valid),
    .fast_pair_data0      (fast_pair_data0),
    .fast_pair_data1      (fast_pair_data1),
    .fast_pair_ready      (fast_pair_ready),
    .sram_data_i          (ext_ram_data_in),
    .sram_addr_o          (fast_ext_addr),
    .sram_be_n_o          (fast_ext_be_n),
    .sram_ce_n_o          (fast_ext_ce_n),
    .sram_oe_n_o          (fast_ext_oe_n),
    .sram_we_n_o          (fast_ext_we_n),
    .sram_bus_active_o    (fast_ext_bus_active)
);
`else
assign ext_ram_addr = soc_sram_addr[21:2];
assign ext_ram_be_n = choose_sram ? ~be_out : 4'b1111;
assign ext_ram_ce_n = choose_sram ? ~soc_sram_cs : 1'b1;
assign ext_ram_oe_n = choose_sram ? soc_sram_we : 1'b1;
assign ext_ram_we_n = choose_sram ? ~soc_sram_we : 1'b1;
assign fast_pair_valid     = 1'b0;
assign fast_pair_data0     = 32'd0;
assign fast_pair_data1     = 32'd0;
assign fast_ext_addr       = 20'd0;
assign fast_ext_be_n       = 4'b1111;
assign fast_ext_ce_n       = 1'b1;
assign fast_ext_oe_n       = 1'b1;
assign fast_ext_we_n       = 1'b1;
assign fast_ext_bus_active = 1'b0;
`endif

endmodule

// Evaluation-only phase-split dual-edge asynchronous ExtRAM reader.
//
// A 50 MHz clock shifted 180 degrees drives the address ODDR.  A separate
// 50 MHz/150-degree clock samples the input before the next address transition,
// avoiding the zero-hold-margin boundary exposed by the 180-degree IDDR clock.
// The unshifted 50 MHz system clock retains all control/FIFO state.
module eval_ext_sram_ddr_phy (
    input         clk,
    input         clk_180,
    input         sample_clk,
    input         resetn,
    input         fast_read_active,
    input  [19:0] fast_read_base_word,
    input  [16:0] fast_read_pair_count,
    output        fast_pair_valid,
    output [31:0] fast_pair_data0,
    output [31:0] fast_pair_data1,
    input         fast_pair_ready,
    input  [31:0] sram_data_i,
    output [19:0] sram_addr_o,
    output [3:0]  sram_be_n_o,
    output        sram_ce_n_o,
    output        sram_oe_n_o,
    output        sram_we_n_o,
    output        sram_bus_active_o
);

localparam FIFO_ADDR_WIDTH = 7;
localparam FIFO_DEPTH = 128;

reg active_seen_q;
reg issuing_q;
reg [19:0] issue_addr_q;
reg [17:0] words_remaining_q;
reg capture_valid_d1_q;
reg capture_valid_d2_q;
reg [31:0] even_word_q;

reg [63:0] pair_fifo [0:FIFO_DEPTH-1];
reg [FIFO_ADDR_WIDTH-1:0] fifo_wr_ptr_q;
reg [FIFO_ADDR_WIDTH-1:0] fifo_rd_ptr_q;
reg [FIFO_ADDR_WIDTH:0] fifo_count_q;

wire fifo_pop = (fifo_count_q != 0) && fast_pair_ready;
// With the IDDR also clocked at 180 degrees, the earlier/later samples become
// visible on adjacent sys_clk observations.  Save Q1, then pair it with Q2 on
// the following cycle.
wire fifo_push = capture_valid_d2_q;
// At most two launched pairs have not yet reached the FIFO.  Stop launching
// with three free entries so already in-flight IDDR samples cannot overflow.
wire fifo_has_issue_space = (fifo_count_q <= (FIFO_DEPTH - 3));
wire issue_pair = issuing_q && (words_remaining_q >= 2) &&
                  fifo_has_issue_space;

wire [31:0] read_data_rise;
wire [31:0] read_data_fall;
wire [19:0] issue_addr_plus1 = issue_addr_q + 20'd1;
wire [63:0] fifo_head = pair_fifo[fifo_rd_ptr_q];

assign fast_pair_valid = (fifo_count_q != 0);
assign fast_pair_data0 = fifo_head[31:0];
assign fast_pair_data1 = fifo_head[63:32];

// Keep CE/OE asserted through both IDDR capture stages.  In idle/reset the
// wrapper falls back to the legacy AXI pin controls and leaves ExtRAM undriven.
assign sram_bus_active_o = issuing_q | capture_valid_d1_q |
                           capture_valid_d2_q;
assign sram_be_n_o = 4'b0000;
assign sram_ce_n_o = ~sram_bus_active_o;
assign sram_oe_n_o = ~sram_bus_active_o;
assign sram_we_n_o = 1'b1;

genvar ddr_bit;
generate
for (ddr_bit = 0; ddr_bit < 20; ddr_bit = ddr_bit + 1) begin: gen_addr_oddr
`ifdef VERILATOR
    reg addr_rise_q;
    reg addr_fall_q;
    // Lint-only behavioural equivalent.  XSim/synthesis use the ODDR below.
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            addr_rise_q <= 1'b0;
            addr_fall_q <= 1'b0;
        end else begin
            if (sram_bus_active_o) begin
                addr_rise_q <= issue_addr_q[ddr_bit];
                addr_fall_q <= issue_addr_plus1[ddr_bit];
            end
        end
    end
    assign sram_addr_o[ddr_bit] = clk_180 ? addr_rise_q : addr_fall_q;
`else
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("ASYNC")
    ) u_addr_oddr (
        .Q  (sram_addr_o[ddr_bit]),
        .C  (clk_180),
        // SAME_EDGE captures both addresses on clk_180's rising edge, then
        // emits the earlier/later words on its rising/falling halves.
        .CE (sram_bus_active_o),
        .D1 (issue_addr_q[ddr_bit]),
        .D2 (issue_addr_plus1[ddr_bit]),
        .R  (~resetn),
        .S  (1'b0)
    );
`endif
end

for (ddr_bit = 0; ddr_bit < 32; ddr_bit = ddr_bit + 1) begin: gen_data_iddr
`ifdef VERILATOR
    reg fall_sample_q;
    reg rise_out_q;
    reg fall_out_q;
    always @(negedge sample_clk or negedge resetn) begin
        if (!resetn)
            fall_sample_q <= 1'b0;
        else
            fall_sample_q <= sram_data_i[ddr_bit];
    end
    always @(posedge sample_clk or negedge resetn) begin
        if (!resetn) begin
            rise_out_q <= 1'b0;
            fall_out_q <= 1'b0;
        end else begin
            rise_out_q <= sram_data_i[ddr_bit];
            fall_out_q <= fall_sample_q;
        end
    end
    assign read_data_rise[ddr_bit] = rise_out_q;
    assign read_data_fall[ddr_bit] = fall_out_q;
`else
    IDDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT_Q1      (1'b0),
        .INIT_Q2      (1'b0),
        .SRTYPE       ("ASYNC")
    ) u_data_iddr (
        .Q1 (read_data_rise[ddr_bit]),
        .Q2 (read_data_fall[ddr_bit]),
        .C  (sample_clk),
        .CE (1'b1),
        .D  (sram_data_i[ddr_bit]),
        .R  (~resetn),
        .S  (1'b0)
    );
`endif
end
endgenerate

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        active_seen_q       <= 1'b0;
        issuing_q           <= 1'b0;
        issue_addr_q        <= 20'd0;
        words_remaining_q   <= 18'd0;
        capture_valid_d1_q  <= 1'b0;
        capture_valid_d2_q  <= 1'b0;
        even_word_q         <= 32'd0;
        fifo_wr_ptr_q       <= {FIFO_ADDR_WIDTH{1'b0}};
        fifo_rd_ptr_q       <= {FIFO_ADDR_WIDTH{1'b0}};
        fifo_count_q        <= {(FIFO_ADDR_WIDTH+1){1'b0}};
    end else if (!fast_read_active) begin
        active_seen_q       <= 1'b0;
        issuing_q           <= 1'b0;
        issue_addr_q        <= 20'd0;
        words_remaining_q   <= 18'd0;
        capture_valid_d1_q  <= 1'b0;
        capture_valid_d2_q  <= 1'b0;
        even_word_q         <= 32'd0;
        fifo_wr_ptr_q       <= {FIFO_ADDR_WIDTH{1'b0}};
        fifo_rd_ptr_q       <= {FIFO_ADDR_WIDTH{1'b0}};
        fifo_count_q        <= {(FIFO_ADDR_WIDTH+1){1'b0}};
    end else begin
        if (!active_seen_q) begin
            active_seen_q       <= 1'b1;
            issuing_q           <= (fast_read_pair_count != 0);
            issue_addr_q        <= fast_read_base_word;
            words_remaining_q   <= {fast_read_pair_count, 1'b0};
            capture_valid_d1_q  <= 1'b0;
            capture_valid_d2_q  <= 1'b0;
            even_word_q         <= 32'd0;
            fifo_wr_ptr_q       <= {FIFO_ADDR_WIDTH{1'b0}};
            fifo_rd_ptr_q       <= {FIFO_ADDR_WIDTH{1'b0}};
            fifo_count_q        <= {(FIFO_ADDR_WIDTH+1){1'b0}};
        end else begin
            capture_valid_d1_q <= issue_pair;
            capture_valid_d2_q <= capture_valid_d1_q;

            if (capture_valid_d1_q)
                even_word_q <= read_data_rise;

            if (issue_pair) begin
                issue_addr_q      <= issue_addr_q + 20'd2;
                words_remaining_q <= words_remaining_q - 18'd2;
                if (words_remaining_q == 18'd2)
                    issuing_q <= 1'b0;
            end

            case ({fifo_push, fifo_pop})
                2'b10: begin
                    fifo_wr_ptr_q <= fifo_wr_ptr_q + 1'b1;
                    fifo_count_q  <= fifo_count_q + 1'b1;
                end
                2'b01: begin
                    fifo_rd_ptr_q <= fifo_rd_ptr_q + 1'b1;
                    fifo_count_q  <= fifo_count_q - 1'b1;
                end
                2'b11: begin
                    fifo_wr_ptr_q <= fifo_wr_ptr_q + 1'b1;
                    fifo_rd_ptr_q <= fifo_rd_ptr_q + 1'b1;
                end
                default: begin
                end
            endcase
        end
    end
end

// Reset-free storage permits LUTRAM/BRAM inference.  FIFO count is the sole
// validity source, so uninitialised entries are never observed after reset.
always @(posedge clk) begin
    if (fifo_push)
        pair_fifo[fifo_wr_ptr_q] <= {read_data_fall, even_word_q};
end

endmodule
