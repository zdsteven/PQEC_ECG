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
wire auto_tx_ready;
wire tx_idle;
wire auto_tx_busy;
reg  auto_tx_valid;
reg  [7:0] auto_tx_data;
reg  [5:0] auto_index;
reg  [1:0] auto_state;
reg  [15:0] auto_delay_count;

localparam [1:0] AUTO_BOOT   = 2'd0;
localparam [1:0] AUTO_WAIT   = 2'd1;
localparam [1:0] AUTO_PREFIX = 2'd2;
localparam [1:0] AUTO_IDLE   = 2'd3;

localparam [15:0] AUTO_CRC_PREFIX_DELAY = 16'd37500; // 0.75 ms @ 50 MHz

// Keep software out of the TX FIFO until the autonomous prefix, including
// its final registered push, has completely handed over the transmitter.
assign auto_tx_busy = (auto_state != AUTO_IDLE) || auto_tx_valid;

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

assign  TXD_oe = isomode&&(rx_en||tx2rx_en) ? 1'b1:1'b0;
assign  RXD_oe =~isomode;

always @(posedge PCLK or negedge PRST_) begin
    if (!PRST_) begin
        auto_tx_valid   <= 1'b0;
        auto_tx_data    <= 8'h00;
        auto_index      <= 6'd0;
        auto_state      <= AUTO_BOOT;
        auto_delay_count<= 16'd0;
    end else begin
        auto_tx_valid <= 1'b0;
        case (auto_state)
            AUTO_BOOT: begin
                if (tx_idle) begin
                    auto_tx_valid <= 1'b1;
                    auto_tx_data  <= auto_boot_char(auto_index);
                    if (auto_index == 6'd12) begin
                        auto_index <= 6'd0;
                        auto_state <= AUTO_WAIT;
                        auto_delay_count <= AUTO_CRC_PREFIX_DELAY;
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
                        auto_index <= 6'd0;
                        auto_state <= AUTO_IDLE;
                    end else begin
                        auto_index <= auto_index + 6'd1;
                    end
                end
            end
            default: begin
                auto_state <= AUTO_IDLE;
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
    .auto_tx_busy (auto_tx_busy ),
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
