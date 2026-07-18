`include "config.h"
`ifdef USE_EVALUATION_UART_SRAM
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

`include "uart_defines.h"

module UART_TOP(
        PCLK,        PRST_,
        PSEL,        PENABLE,     PADDR,       PWRITE,
        PWDATA,      URT_PRDATA,
        auto_start_valid,
        auto_crc_valid, auto_crc32,

        INT, clk_carrier,

        TXD_i, TXD_o, TXD_oe,
        RXD_i, RXD_o, RXD_oe,

        RTS,         CTS,         DSR,
        DCD,         DTR,         RI
    );

input   PCLK,        PRST_;
input   PSEL,        PENABLE,     PWRITE;
input   [7:0]     PADDR;
input   [7:0]     PWDATA;
output  [7:0]     URT_PRDATA;
input             auto_start_valid;
input             auto_crc_valid;
input   [31:0]    auto_crc32;

output  INT;
input   clk_carrier;

input   TXD_i;
output  TXD_o;
output  TXD_oe;
input   RXD_i;
output  RXD_o;
output  RXD_oe;

output  RTS;
input   CTS,         DSR,         DCD;
output  DTR;
input   RI;

wire prst = !PRST_;
wire we   = PSEL & PENABLE & PWRITE;
wire re   = PSEL & PENABLE & !PWRITE;

wire rx_en;
wire tx2rx_en;
wire isomode;
wire auto_tx_ready;
wire tx_idle;
reg  auto_tx_valid;
reg  [7:0] auto_tx_data;
reg  [5:0] auto_index;
reg  [31:0] auto_crc_hold;
reg  [2:0] auto_state;
reg  auto_crc_pending;
reg  [15:0] auto_delay_count;

localparam [2:0] AUTO_ARM   = 3'd0;
localparam [2:0] AUTO_BOOT  = 3'd1;
localparam [2:0] AUTO_WAIT  = 3'd2;
localparam [2:0] AUTO_HEX   = 3'd3;
localparam [2:0] AUTO_DONE  = 3'd4;
localparam [2:0] AUTO_IDLE  = 3'd5;
localparam [2:0] AUTO_PREFIX= 3'd6;
localparam [2:0] AUTO_CRC_WAIT = 3'd7;

localparam [15:0] AUTO_CRC_PREFIX_DELAY = 16'd37500; // 0.75 ms @ 50 MHz

function [7:0] auto_boot_char;
    input [5:0] index;
    begin
        case (index)
            6'd0:  auto_boot_char = "M";
            6'd1:  auto_boot_char = "A";
            6'd2:  auto_boot_char = "T";
            6'd3:  auto_boot_char = "M";
            6'd4:  auto_boot_char = "U";
            6'd5:  auto_boot_char = "L";
            6'd6:  auto_boot_char = "_";
            6'd7:  auto_boot_char = "S";
            6'd8:  auto_boot_char = "T";
            6'd9:  auto_boot_char = "A";
            6'd10: auto_boot_char = "R";
            6'd11: auto_boot_char = "T";
            6'd12: auto_boot_char = "\n";
            default: auto_boot_char = 8'h00;
        endcase
    end
endfunction

function [7:0] auto_prefix_char;
    input [5:0] index;
    begin
        case (index)
            6'd0:  auto_prefix_char = "M";
            6'd1:  auto_prefix_char = "A";
            6'd2:  auto_prefix_char = "T";
            6'd3:  auto_prefix_char = "M";
            6'd4:  auto_prefix_char = "U";
            6'd5:  auto_prefix_char = "L";
            6'd6:  auto_prefix_char = "_";
            6'd7:  auto_prefix_char = "C";
            6'd8:  auto_prefix_char = "R";
            6'd9:  auto_prefix_char = "C";
            6'd10: auto_prefix_char = "3";
            6'd11: auto_prefix_char = "2";
            6'd12: auto_prefix_char = "=";
            default: auto_prefix_char = 8'h00;
        endcase
    end
endfunction

function [7:0] auto_done_char;
    input [5:0] index;
    begin
        case (index)
            6'd0:  auto_done_char = "\n";
            6'd1:  auto_done_char = "M";
            6'd2:  auto_done_char = "A";
            6'd3:  auto_done_char = "T";
            6'd4:  auto_done_char = "M";
            6'd5:  auto_done_char = "U";
            6'd6:  auto_done_char = "L";
            6'd7:  auto_done_char = "_";
            6'd8:  auto_done_char = "D";
            6'd9:  auto_done_char = "O";
            6'd10: auto_done_char = "N";
            6'd11: auto_done_char = "E";
            6'd12: auto_done_char = "\n";
            default: auto_done_char = 8'h00;
        endcase
    end
endfunction

function [7:0] auto_hex_char;
    input [3:0] nibble;
    begin
        case (nibble)
            4'h0: auto_hex_char = "0";
            4'h1: auto_hex_char = "1";
            4'h2: auto_hex_char = "2";
            4'h3: auto_hex_char = "3";
            4'h4: auto_hex_char = "4";
            4'h5: auto_hex_char = "5";
            4'h6: auto_hex_char = "6";
            4'h7: auto_hex_char = "7";
            4'h8: auto_hex_char = "8";
            4'h9: auto_hex_char = "9";
            4'ha: auto_hex_char = "A";
            4'hb: auto_hex_char = "B";
            4'hc: auto_hex_char = "C";
            4'hd: auto_hex_char = "D";
            4'he: auto_hex_char = "E";
            default: auto_hex_char = "F";
        endcase
    end
endfunction

assign  TXD_oe = isomode&&(rx_en||tx2rx_en) ? 1'b1:1'b0;
assign  RXD_oe =~isomode;

always @(posedge PCLK or negedge PRST_) begin
    if (!PRST_) begin
        auto_tx_valid   <= 1'b0;
        auto_tx_data    <= 8'h00;
        auto_index      <= 6'd0;
        auto_crc_hold   <= 32'd0;
        auto_state      <= AUTO_ARM;
        auto_crc_pending<= 1'b0;
        auto_delay_count<= 16'd0;
    end else begin
        auto_tx_valid <= 1'b0;
        if (auto_crc_valid) begin
            auto_crc_hold    <= auto_crc32;
            auto_crc_pending <= 1'b1;
        end
        case (auto_state)
            AUTO_ARM: begin
                if (auto_start_valid) begin
                    auto_index <= 6'd0;
                    auto_state <= AUTO_BOOT;
                end
            end
            AUTO_BOOT: begin
                if (tx_idle) begin
                    auto_tx_valid <= 1'b1;
                    auto_tx_data  <= auto_boot_char(auto_index);
                    if (auto_index == 6'd12) begin
                        auto_index <= 6'd0;
`ifdef EVAL_DEBUG_COUNTERS
                        // Diagnostic builds retain CPU ownership so counters
                        // can be printed before DONE.
                        auto_state <= AUTO_IDLE;
`elsif EVAL_DEBUG_CAPTURE
                        auto_state <= AUTO_IDLE;
`else
                        // At 10 ns/word the DMA CRC is ready before this
                        // prefix finishes.  Keep the complete scored stream
                        // in one UART state machine and remove CPU/FIFO races.
                        auto_state <= AUTO_PREFIX;
`endif
                    end else begin
                        auto_index <= auto_index + 6'd1;
                    end
                end
            end
            AUTO_WAIT: begin
                if (tx_idle) begin
                    if (auto_delay_count == 16'd0) begin
                        auto_index <= 6'd0;
                        auto_state <= AUTO_PREFIX;
                    end else begin
                        auto_delay_count <= auto_delay_count - 16'd1;
                    end
                end
            end
            AUTO_PREFIX: begin
                if (tx_idle) begin
                    auto_tx_valid <= 1'b1;
                    auto_tx_data  <= auto_prefix_char(auto_index);
                    if (auto_index == 6'd12) begin
                        if (auto_crc_pending) begin
                            auto_crc_pending <= 1'b0;
                            auto_index <= 6'd0;
                            auto_state <= AUTO_HEX;
                        end else begin
                            auto_index <= 6'd0;
                            auto_state <= AUTO_CRC_WAIT;
                            auto_delay_count <= 16'd0;
                        end
                    end else begin
                        auto_index <= auto_index + 6'd1;
                    end
                end
            end
            AUTO_HEX: begin
                if (tx_idle) begin
                    auto_tx_valid <= 1'b1;
                    auto_tx_data  <= auto_hex_char(
                        auto_crc_hold[31 - {auto_index[2:0], 2'b00} -: 4]
                    );
                    if (auto_index == 6'd7) begin
                        auto_index <= 6'd0;
                        auto_state <= AUTO_DONE;
                    end else begin
                        auto_index <= auto_index + 6'd1;
                    end
                end
            end
            AUTO_DONE: begin
                if (tx_idle) begin
                    auto_tx_valid <= 1'b1;
                    auto_tx_data  <= auto_done_char(auto_index);
                    if (auto_index == 6'd12) begin
                        auto_index <= 6'd0;
                        auto_state <= AUTO_IDLE;
                    end else begin
                        auto_index <= auto_index + 6'd1;
                    end
                end
            end
            AUTO_CRC_WAIT: begin
                if (auto_crc_pending) begin
                    auto_crc_pending <= 1'b0;
                    auto_index <= 6'd0;
                    auto_state <= AUTO_HEX;
                end
            end
            AUTO_IDLE: begin
                // Keep the CRC sideband from restarting autonomous output.
                auto_crc_pending <= 1'b0;
            end
            default: begin
                if (auto_crc_valid) begin
                    auto_crc_pending <= 1'b1;
                end
                if (tx_idle && auto_crc_pending) begin
                    auto_index <= 6'd0;
                    auto_state <= AUTO_PREFIX;
                end
            end
        endcase
    end
end

uart_regs	regs(
    .clk         (PCLK       ),
    .rst         (prst       ),
    .clk_carrier (clk_carrier),
    .addr        (PADDR[2:0] ),
    .dat_i       (PWDATA     ),
    .dat_o       (URT_PRDATA ),
    .we          (we         ),
    .re          (re         ),
    .auto_tx_valid(auto_tx_valid),
    .auto_tx_data (auto_tx_data ),
    .auto_tx_ready(auto_tx_ready),
    .tx_idle      (tx_idle      ),

    .modem_inputs({ CTS, DSR, RI, DCD }	),
    .rts_pad_o   (RTS      ),
    .dtr_pad_o   (DTR      ),
    .stx_pad_o   (TXD_o	   ),
    .TXD_i       (TXD_i    ),
    .srx_pad_i   (RXD_i    ),
    .RXD_o       (RXD_o    ),
    .int_o       ( INT     ),
    .tx2rx_en    (tx2rx_en ),
    .rx_en       (rx_en    ),
    .usart_mode  (isomode  )

);


endmodule
`else
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

`include "uart_defines.h"

module UART_TOP(
        PCLK,        PRST_,
        PSEL,        PENABLE,     PADDR,       PWRITE,
        PWDATA,      URT_PRDATA,

        INT, clk_carrier,

        TXD_i, TXD_o, TXD_oe,
        RXD_i, RXD_o, RXD_oe,

        RTS,         CTS,         DSR,
        DCD,         DTR,         RI
    );

input   PCLK,        PRST_;
input   PSEL,        PENABLE,     PWRITE;
input   [7:0]     PADDR;
input   [7:0]     PWDATA;
output  [7:0]     URT_PRDATA;

output  INT;
input   clk_carrier;

input   TXD_i;
output  TXD_o;
output  TXD_oe;
input   RXD_i;
output  RXD_o;
output  RXD_oe;

output  RTS;
input   CTS,         DSR,         DCD;
output  DTR;
input   RI;

wire prst = !PRST_;
wire we   = PSEL & PENABLE & PWRITE;
wire re   = PSEL & PENABLE & !PWRITE;

wire rx_en;
wire tx2rx_en;
wire isomode;

assign  TXD_oe = isomode&&(rx_en||tx2rx_en) ? 1'b1:1'b0;
assign  RXD_oe =~isomode;

uart_regs	regs(
    .clk         (PCLK       ),
    .rst         (prst       ),
    .clk_carrier (clk_carrier),
    .addr        (PADDR[2:0] ),
    .dat_i       (PWDATA     ),
    .dat_o       (URT_PRDATA ),
    .we          (we         ),
    .re          (re         ),

    .modem_inputs({ CTS, DSR, RI, DCD }	),
    .rts_pad_o   (RTS      ),
    .dtr_pad_o   (DTR      ),
    .stx_pad_o   (TXD_o	   ),
    .TXD_i       (TXD_i    ),
    .srx_pad_i   (RXD_i    ),
    .RXD_o       (RXD_o    ),
    .int_o       ( INT     ),
    .tx2rx_en    (tx2rx_en ),
    .rx_en       (rx_en    ),
    .usart_mode  (isomode  )

);


endmodule

`endif
