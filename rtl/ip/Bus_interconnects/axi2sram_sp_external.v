// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// ----------------------------
// AXI to SRAM Adapter
// ----------------------------
// Author: Florian Zaruba (zarubaf@iis.ee.ethz.ch)
//
// Description: Manages AXI transactions
//              Supports all burst accesses but only on aligned addresses and with full data width.
//              Assertions should guide you if there is something unsupported happening.
//
module axi2sram_sp_external #(
    parameter AXI_ID_WIDTH      = 5,
    parameter AXI_ADDR_WIDTH    = 32,
    parameter AXI_DATA_WIDTH    = 32
)(
    input                         clk,
    input                         resetn,

    input     [AXI_ADDR_WIDTH-1:0] s_araddr ,
    input     [1               :0] s_arburst,
    input     [3               :0] s_arcache,
    input     [AXI_ID_WIDTH-1  :0] s_arid   ,
    input     [7               :0] s_arlen  ,
    input                          s_arlock ,
    input     [2               :0] s_arprot ,
    output reg                        s_arready,
    input     [2               :0] s_arsize ,
    input                          s_arvalid,
    input     [AXI_ADDR_WIDTH-1:0] s_awaddr ,
    input     [1               :0] s_awburst,
    input     [3               :0] s_awcache,
    input     [AXI_ID_WIDTH-1  :0] s_awid   ,
    input     [7               :0] s_awlen  ,
    input                          s_awlock ,
    input     [2               :0] s_awprot ,
    output reg                        s_awready,
    input     [2               :0] s_awsize ,
    input                          s_awvalid,
    output reg   [AXI_ID_WIDTH-1  :0] s_bid    ,
    input                          s_bready ,
    output reg   [1               :0] s_bresp  ,
    output reg                        s_bvalid ,
    output reg   [AXI_DATA_WIDTH-1:0] s_rdata  ,
    output reg   [AXI_ID_WIDTH-1    :0] s_rid    ,
    output reg                        s_rlast  ,
    input                          s_rready ,
    output reg   [1               :0] s_rresp  ,
    output reg                        s_rvalid ,
    input     [AXI_DATA_WIDTH-1:0] s_wdata  ,
    input                          s_wlast  ,
    output reg                        s_wready ,
    input     [AXI_DATA_WIDTH/8-1:0] s_wstrb  ,
    input                          s_wvalid ,

    output  reg                       req_o,
    output  reg                       we_o,
    output  reg [AXI_ADDR_WIDTH-1:0]   addr_o,
    output  reg [AXI_DATA_WIDTH/8-1:0] be_o,
    output  reg [AXI_DATA_WIDTH-1:0]   data_o,
    input   [AXI_DATA_WIDTH-1:0]   data_i
);
    // AXI has the following rules governing the use of bursts:
    // - for wrapping bursts, the burst length must be 2, 4, 8, or 16
    // - a burst must not cross a 4KB address boundary
    // - early termination of bursts is not supported.

    localparam LOG_NR_BYTES = $clog2(AXI_DATA_WIDTH/8);

    reg [AXI_ID_WIDTH-1:0]   ax_req_d_id;
    reg [AXI_ADDR_WIDTH-1:0] ax_req_d_addr;
    reg [7:0]                ax_req_d_len;
    reg [2:0]                ax_req_d_size;
    reg [1:0]                ax_req_d_burst;

    reg [AXI_ID_WIDTH-1:0]   ax_req_q_id;
    reg [AXI_ADDR_WIDTH-1:0] ax_req_q_addr;
    reg [7:0]                ax_req_q_len;
    reg [2:0]                ax_req_q_size;
    reg [1:0]                ax_req_q_burst;

    reg [2:0]                state_d;
    reg [2:0]                state_q;

    localparam              IDLE        = 3'h0;
    localparam              READ        = 3'h1;
    localparam              WRITE       = 3'h2;
    localparam              SEND_B      = 3'h3;
    localparam              WAIT_WVALID = 3'h4;
    localparam              WRITE_NOP   = 3'h5;

    localparam              FIXED       = 2'b00;
    localparam              INCR        = 2'b01;
    localparam              WRAP        = 2'b10;
    
    reg [AXI_ADDR_WIDTH-1:0] req_addr_d, req_addr_q;
    reg [7:0]                cnt_d, cnt_q;

    function automatic [AXI_ADDR_WIDTH-1:0] get_wrap_boundary;
        input [AXI_ADDR_WIDTH-1:0] unaligned_address;
        input [7:0] len;
    begin
        get_wrap_boundary = 'h0;
        //  for wrapping transfers ax_len can only be of size 1, 3, 7 or 15
        if (len == 4'b1)
            get_wrap_boundary[AXI_ADDR_WIDTH-1:1+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-1:1+LOG_NR_BYTES];
        else if (len == 4'b11)
            get_wrap_boundary[AXI_ADDR_WIDTH-1:2+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-1:2+LOG_NR_BYTES];
        else if (len == 4'b111)
            get_wrap_boundary[AXI_ADDR_WIDTH-1:3+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-3:2+LOG_NR_BYTES];
        else if (len == 4'b1111)
            get_wrap_boundary[AXI_ADDR_WIDTH-1:4+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-3:4+LOG_NR_BYTES];
    end
    endfunction

    reg [AXI_ADDR_WIDTH-1:0] wrap_boundary_d, wrap_boundary_q;
    reg [AXI_ADDR_WIDTH-1:0] upper_wrap_boundary_d, upper_wrap_boundary_q;
    reg [AXI_ADDR_WIDTH-1:0] next_addr;
    reg                      rd_valid_d, rd_valid_q;
    reg [AXI_DATA_WIDTH-1:0] rd_data_d, rd_data_q;
    reg [AXI_ID_WIDTH-1:0]   rd_id_d, rd_id_q;
    reg                      rd_last_d, rd_last_q;
    reg                      rd_capture;
    reg [AXI_ID_WIDTH-1:0]   rd_capture_id;
    reg                      rd_capture_last;

    always @ (*) begin
        // Advance the registered current address directly.  The previous
        // base+(count<<2) expression placed the burst length and a 32-bit
        // carry chain on the asynchronous SRAM output path.
        next_addr = req_addr_q + {{(AXI_ADDR_WIDTH-3){1'b0}}, 3'd4};

        // Transaction attributes
        // default assignments
        state_d         = state_q;
        ax_req_d_id     = ax_req_q_id;
        ax_req_d_addr   = ax_req_q_addr;
        ax_req_d_len    = ax_req_q_len;
        ax_req_d_size   = ax_req_q_size;
        ax_req_d_burst  = ax_req_q_burst;
        req_addr_d      = req_addr_q;
        cnt_d           = cnt_q;
        wrap_boundary_d = wrap_boundary_q;
        upper_wrap_boundary_d = upper_wrap_boundary_q;
        rd_valid_d      = rd_valid_q;
        rd_data_d       = rd_data_q;
        rd_id_d         = rd_id_q;
        rd_last_d       = rd_last_q;
        rd_capture      = 1'b0;
        rd_capture_id   = rd_id_q;
        rd_capture_last = rd_last_q;
        // Memory default assignments
        data_o = s_wdata;
        be_o   = s_wstrb;
        we_o   = 1'b0;
        req_o  = 1'b0;
        addr_o = 'h0;
        // AXI assignments
        // request
        s_awready = 1'b0;
        s_arready = 1'b0;
        // read response channel
        s_rvalid  = rd_valid_q;
        s_rdata   = rd_data_q;
        s_rresp   = 'h0;
        s_rlast   = rd_last_q;
        s_rid     = rd_id_q;
        // slave write data channel
        s_wready  = 1'b0;
        // write response channel
        s_bvalid  = 1'b0;
        s_bresp   = 1'b0;
        s_bid     = 1'b0;

        case (state_q)

            IDLE: begin
                // Wait for a read or write
                // ------------
                // Read
                // ------------
                if (s_arvalid) begin
                    s_arready = 1'b1;
                    // sample ax
                    ax_req_d_id     = s_arid;
                    ax_req_d_addr   = s_araddr;
                    ax_req_d_len    = s_arlen;
                    ax_req_d_size   = s_arsize;
                    ax_req_d_burst  = s_arburst;
                    state_d        = READ;
                    //  we can request the first address, this saves us time
                    req_o          = 1'b1;
                    addr_o         = s_araddr;
                    rd_capture     = 1'b1;
                    rd_capture_id  = s_arid;
                    rd_capture_last= (s_arlen == 8'd0);
                    // save the address
                    case (s_arburst)
                        FIXED: req_addr_d = s_araddr;
                        INCR:  req_addr_d = s_araddr + {{(AXI_ADDR_WIDTH-3){1'b0}}, 3'd4};
                        WRAP:  begin
                            if ((s_araddr + {{(AXI_ADDR_WIDTH-3){1'b0}}, 3'd4}) >=
                                (get_wrap_boundary(s_araddr, s_arlen) + ((s_arlen + 1) << LOG_NR_BYTES)))
                                req_addr_d = get_wrap_boundary(s_araddr, s_arlen);
                            else
                                req_addr_d = s_araddr + {{(AXI_ADDR_WIDTH-3){1'b0}}, 3'd4};
                        end
                        default: req_addr_d = s_araddr + {{(AXI_ADDR_WIDTH-3){1'b0}}, 3'd4};
                    endcase
                    wrap_boundary_d = get_wrap_boundary(s_araddr, s_arlen);
                    upper_wrap_boundary_d = get_wrap_boundary(s_araddr, s_arlen) +
                                            ((s_arlen + 1) << LOG_NR_BYTES);
                    // save the ar_len
                    cnt_d          = 1;
                // ------------
                // Write
                // ------------
                end else if (s_awvalid) begin
                    s_awready = 1'b1;
                    s_wready  = 1'b1;
                    addr_o         = s_awaddr;
                    // sample ax
                    ax_req_d_id     = s_awid;
                    ax_req_d_addr   = s_awaddr;
                    ax_req_d_len    = s_awlen;
                    ax_req_d_size   = s_awsize;
                    ax_req_d_burst  = s_awburst;
                    req_addr_d      = s_awaddr;
                    wrap_boundary_d = get_wrap_boundary(s_awaddr, s_awlen);
                    upper_wrap_boundary_d = get_wrap_boundary(s_awaddr, s_awlen) +
                                            ((s_awlen + 1) << LOG_NR_BYTES);
                    // we've got our first w_valid so start the write process
                    if (s_wvalid) begin
                        req_o          = 1'b1;
                        we_o           = 1'b1;
                        state_d        = (s_wlast) ? SEND_B : WRITE_NOP;
                        cnt_d          = 1;
                    // we still have to wait for the first w_valid to arrive
                    end else
                        state_d = WAIT_WVALID;
                end
            end

            // ~> we are still missing a w_valid
            WAIT_WVALID: begin
                s_wready = 1'b1;
                addr_o = ax_req_q_addr;
                // we can now make our first request
                if (s_wvalid) begin
                    req_o          = 1'b1;
                    we_o           = 1'b1;
                    state_d        = (s_wlast) ? SEND_B : WRITE;
                    cnt_d          = 1;
                end
            end

            READ: begin
                if (!rd_valid_q || s_rready) begin
                    if (cnt_q <= ax_req_q_len) begin
                        req_o           = 1'b1;
                        addr_o          = req_addr_q;
                        rd_capture      = 1'b1;
                        rd_capture_id   = ax_req_q_id;
                        rd_capture_last = (cnt_q == ax_req_q_len);
                        case (ax_req_q_burst)
                            FIXED: req_addr_d = req_addr_q;
                            INCR:  req_addr_d = next_addr;
                            WRAP:  begin
                                if (next_addr >= upper_wrap_boundary_q)
                                    req_addr_d = wrap_boundary_q;
                                else
                                    req_addr_d = next_addr;
                            end
                            default: req_addr_d = next_addr;
                        endcase
                        cnt_d = cnt_q + 8'd1;
                    end else if (rd_valid_q && s_rready && rd_last_q) begin
                        state_d = IDLE;
                        rd_valid_d = 1'b0;
                        rd_last_d  = 1'b0;
                    end
                end
            end

            //ext SRAM need nop between continuous write operations
            WRITE_NOP: begin
                s_wready = 1'b0;
                state_d  = WRITE;
            end

            // ~> we already wrote the first word here
            WRITE: begin

                s_wready = 1'b1;
                state_d  = WRITE_NOP;

                // consume a word here
                if (s_wvalid) begin
                    req_o         = 1'b1;
                    we_o          = 1'b1;
                    // ----------------------------
                    // Next address generation
                    // ----------------------------
                    // handle the correct burst type
                    case (ax_req_q_burst)
                        FIXED: addr_o = req_addr_q;
                        INCR:  addr_o = next_addr;
                        WRAP:  begin
                            if (next_addr >= upper_wrap_boundary_q)
                                addr_o = wrap_boundary_q;
                            else
                                addr_o = next_addr;
                        end
                        default: addr_o = next_addr;
                    endcase
                    // save the request address for the next cycle
                    req_addr_d = addr_o;
                    // we can decrease the counter as the master has consumed the read data
                    cnt_d = cnt_q + 1;

                    if (s_wlast)
                        state_d = SEND_B;
                end
            end
            // ~> send a write acknowledge back
            SEND_B: begin
                s_bvalid = 1'b1;
                s_bid    = ax_req_q_id;
                if (s_bready)
                    state_d = IDLE;
            end

        endcase
    end

    // --------------
    // Registers
    // --------------
    always @(posedge clk or negedge resetn) begin
        if (~resetn) begin
            state_q         <= IDLE;
            ax_req_q_addr   <= 32'h0;
            ax_req_q_burst  <= 2'h0;
            ax_req_q_id     <= 'h0;
            ax_req_q_len    <= 8'h0;
            ax_req_q_size   <= 3'h0;
            req_addr_q      <= 'h0;
            cnt_q           <= 8'h0;
            wrap_boundary_q <= 'h0;
            upper_wrap_boundary_q <= 'h0;
            rd_valid_q      <= 1'b0;
            rd_data_q       <= 'h0;
            rd_id_q         <= 'h0;
            rd_last_q       <= 1'b0;
        end else begin
            state_q         <= state_d;
            ax_req_q_addr   <= ax_req_d_addr;
            ax_req_q_burst  <= ax_req_d_burst;
            ax_req_q_id     <= ax_req_d_id;
            ax_req_q_len    <= ax_req_d_len;
            ax_req_q_size   <= ax_req_d_size;
            req_addr_q      <= req_addr_d;
            cnt_q           <= cnt_d;
            wrap_boundary_q <= wrap_boundary_d;
            upper_wrap_boundary_q <= upper_wrap_boundary_d;
            rd_valid_q      <= rd_valid_d;
            rd_data_q       <= rd_data_d;
            rd_id_q         <= rd_id_d;
            rd_last_q       <= rd_last_d;
            if (rd_capture) begin
                rd_valid_q <= 1'b1;
                rd_data_q  <= data_i;
                rd_id_q    <= rd_capture_id;
                rd_last_q  <= rd_capture_last;
            end
        end
    end


    // always @(posedge clk or negedge resetn) begin
    //     if (~resetn) begin
    //         s_rdata         <= 'h0;     
    //     end else begin
    //         if(req_o == 1'b1 && we_o == 1'b0)
    //             s_rdata     <= data_i;
    //         else
    //             s_rdata     <= s_rdata;
    //     end
    // end

endmodule

