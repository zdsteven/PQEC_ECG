`include "config.h"

module data_bank_sram (
    input  [ 7:0]          addra   ,
    input                  clka    ,
    input  [31:0]          dina    ,
    output [31:0]          douta   ,
    input                  ena     ,
    input  [ 3:0]          wea      
);
`ifdef USE_CACHE
    localparam V_STYLE = "block";
    localparam P_STYLE =    (V_STYLE == "ultra")        ? "uram" :
                            (V_STYLE == "distributed")  ? "select_ram" :
                            "block_ram";

    reg [31:0] mem_reg [255:0];
    reg [31:0] output_buffer;

    always @(posedge clka) begin
        if (ena) begin
            if (wea) begin
                if (wea[0]) begin
                    mem_reg[addra][ 7: 0] <= dina[ 7: 0]; 
                end 

                if (wea[1]) begin
                    mem_reg[addra][15: 8] <= dina[15: 8];
                end

                if (wea[2]) begin
                    mem_reg[addra][23:16] <= dina[23:16];
                end

                if (wea[3]) begin
                    mem_reg[addra][31:24] <= dina[31:24];
                end
            end
            else begin
                output_buffer <= mem_reg[addra];
            end
        end
    end

    assign douta = output_buffer;
`else
    assign douta = 32'h0;
`endif

endmodule 

module tagv_sram ( 
    input  [ 7:0]          addra   ,
    input                  clka    ,
    input  [20:0]          dina    ,
    output [20:0]          douta   ,
    input                  ena     ,
    input                  wea 
);
`ifdef USE_CACHE
    localparam V_STYLE = "block";
    localparam P_STYLE =    (V_STYLE == "ultra")        ? "uram" :
                            (V_STYLE == "distributed")  ? "select_ram" :
                            "block_ram";

    reg [20:0] mem_reg [255:0];
    reg [20:0] output_buffer;

`ifdef USE_EVALUATION_UART_SRAM
    // The evaluation image is freshly configured for each run.  Give every
    // cache tag RAM a deterministic cold-invalid image so software need not
    // spend reset-release time issuing 1024 indexed CACOP operations.
// synopsys translate_off
`ifndef SYNTHESIS
    integer eval_init_index;
    initial begin
        output_buffer = 21'd0;
        for (eval_init_index = 0; eval_init_index < 256; eval_init_index = eval_init_index + 1)
            mem_reg[eval_init_index] = 21'd0;
    end
`endif
// synopsys translate_on
`endif

    always @(posedge clka) begin
        if (ena) begin
            if (wea) begin
                mem_reg[addra] <= dina;
            end
            else begin
                output_buffer <= mem_reg[addra];
            end
        end
    end

    assign douta = output_buffer;
`else
    assign douta = 21'h0;
`endif

endmodule
