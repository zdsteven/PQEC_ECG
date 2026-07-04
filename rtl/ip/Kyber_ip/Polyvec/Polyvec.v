module Polyvec (
    input            aclk,
    input            aresetn,

    input            basemul_start,
    input            basemul_valid_out,
    input   [23:0]   basemul_result,

    input            polyvec_fqadd_from_sample_start,
    input            polyvec_fqadd_from_intt_start,
    input            polyvec_reset_start,
    input   [1:0]    polyvec_addr_high_in,
    input            polyvec_is_sub_in,
    input   [1:0]    polyvec_reset_mode,

    input            polyvec_read_from_ext,
    input   [8:0]    polyvec_read_addr_ext,
    input            polyvec_write_from_ext,
    input   [8:0]    polyvec_write_addr_ext,
    input   [23:0]   polyvec_write_data_ext,

    input   [31:0]   Hash_sample_data,
    input   [31:0]   ntt_intt_read_data,

    output reg       polyvec_from_sample_state,
    output reg [6:0] polyvec_sample_take_addr,
    output reg       polyvec_from_intt_state,
    output reg [6:0] polyvec_intt_take_addr,
    output  [31:0]   polyvec_read_data,
    output reg       polyvec_done,
    output reg       polyvec_reset_done
);
    localparam [12:0] Q = 13'd3329;

    reg polyvec_sample_valid;
    reg polyvec_intt_valid;
    reg [1:0] polyvec_addr_high;
    reg [6:0] polyvec_basemul_take_addr;
    reg [6:0] polyvec_sample_addr_d;
    reg [6:0] polyvec_intt_addr_d;

    reg polyvec_reset_state;
    reg [8:0] polyvec_reset_addr;
    reg [8:0] polyvec_reset_last_addr;

    reg polyvec_is_sub;
    reg polyvec_clear_after_read;
    reg [8:0] polyvec_clear_after_read_addr;

    (* ram_style = "block" *) reg [23:0] polyvec_result [0:511];

    wire polyvec_result_re;
    wire [8:0] polyvec_result_raddr;
    wire [8:0] polyvec_result_waddr;
    wire polyvec_result_we;
    wire [23:0] polyvec_result_din;
    reg [23:0] polyvec_result_rdata;

    reg polyvec_result_we_r;
    reg [8:0] polyvec_result_waddr_r;
    reg [23:0] polyvec_result_din_choose;
    wire polyvec_source_valid;
    wire [8:0] polyvec_source_addr;
    wire [11:0] polyvec_result_in_high;
    wire [11:0] polyvec_result_in_low;

    assign polyvec_read_data = {4'b0, polyvec_result_rdata[23:12],
                                4'b0, polyvec_result_rdata[11:0]};

    assign polyvec_source_valid = basemul_valid_out | polyvec_sample_valid | polyvec_intt_valid;
    assign polyvec_source_addr = basemul_valid_out ? {polyvec_addr_high, polyvec_basemul_take_addr} 
                                : polyvec_sample_valid ? {polyvec_addr_high, polyvec_sample_addr_d} 
                                : {polyvec_addr_high, polyvec_intt_addr_d};
    assign polyvec_result_in_high = polyvec_is_sub ? fqsub(polyvec_result_rdata[23:12], polyvec_result_din_choose[23:12]) 
                                    : fqadd(polyvec_result_rdata[23:12], polyvec_result_din_choose[23:12]);
    assign polyvec_result_in_low = polyvec_is_sub ? fqsub(polyvec_result_rdata[11:0], polyvec_result_din_choose[11:0]) 
                                    : fqadd(polyvec_result_rdata[11:0], polyvec_result_din_choose[11:0]);

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_addr_high <= 2'b0;
        end
        else if (basemul_start | polyvec_fqadd_from_sample_start | polyvec_fqadd_from_intt_start) begin
            polyvec_addr_high <= polyvec_addr_high_in;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_is_sub <= 1'b0;
        end
        else if (polyvec_fqadd_from_intt_start) begin
            polyvec_is_sub <= polyvec_is_sub_in;
        end
        else if (polyvec_done) begin
            polyvec_is_sub <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_basemul_take_addr <= 7'd0;
        end
        else if (basemul_start) begin
            polyvec_basemul_take_addr <= 7'd0;
        end
        else if (basemul_valid_out) begin
            polyvec_basemul_take_addr <= polyvec_basemul_take_addr + 1'b1;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_from_sample_state <= 1'b0;
            polyvec_sample_take_addr <= 7'd0;
        end
        else begin
            case (polyvec_from_sample_state)
                1'b0: begin
                    if (polyvec_fqadd_from_sample_start) begin
                        polyvec_from_sample_state <= 1'b1;
                        polyvec_sample_take_addr <= 7'd0;
                    end
                end
                1'b1: begin
                    polyvec_sample_take_addr <= polyvec_sample_take_addr + 1'b1;
                    if (polyvec_sample_take_addr == 7'd127) begin
                        polyvec_from_sample_state <= 1'b0;
                    end
                end
            endcase
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_sample_valid <= 1'b0;
            polyvec_sample_addr_d <= 7'd0;
        end
        else begin
            polyvec_sample_valid <= polyvec_from_sample_state;
            if (polyvec_from_sample_state) begin
                polyvec_sample_addr_d <= polyvec_sample_take_addr;
            end
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_from_intt_state <= 1'b0;
            polyvec_intt_take_addr <= 7'd0;
        end
        else begin
            case (polyvec_from_intt_state)
                1'b0: begin
                    if (polyvec_fqadd_from_intt_start) begin
                        polyvec_from_intt_state <= 1'b1;
                        polyvec_intt_take_addr <= 7'd0;
                    end
                end
                1'b1: begin
                    polyvec_intt_take_addr <= polyvec_intt_take_addr + 1'b1;
                    if (polyvec_intt_take_addr == 7'd127) begin
                        polyvec_from_intt_state <= 1'b0;
                    end
                end
            endcase
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_intt_valid <= 1'b0;
            polyvec_intt_addr_d <= 7'd0;
        end
        else begin
            polyvec_intt_valid <= polyvec_from_intt_state;
            if (polyvec_from_intt_state) begin
                polyvec_intt_addr_d <= polyvec_intt_take_addr;
            end
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_result_we_r <= 1'b0;
            polyvec_result_waddr_r <= 9'd0;
            polyvec_result_din_choose <= 24'd0;
        end
        else begin
            polyvec_result_we_r <= polyvec_source_valid;
            if (polyvec_source_valid) begin
                polyvec_result_waddr_r <= polyvec_source_addr;
                polyvec_result_din_choose <= basemul_valid_out ? basemul_result 
                                            : polyvec_sample_valid ? {Hash_sample_data[27:16], Hash_sample_data[11:0]} 
                                            : {ntt_intt_read_data[27:16],  ntt_intt_read_data[11:0]};
            end
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_done <= 1'b0;
        end
        else if (polyvec_result_we_r && (polyvec_result_waddr_r[6:0] == 7'd127)) begin
            polyvec_done <= 1'b1;
        end
        else begin
            polyvec_done <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_reset_last_addr <= 9'd255;
        end
        else if (polyvec_reset_start) begin
            case (polyvec_reset_mode)
                2'd0: polyvec_reset_last_addr <= 9'd255;
                2'd1: polyvec_reset_last_addr <= 9'd383;
                2'd2: polyvec_reset_last_addr <= 9'd511;
                default: polyvec_reset_last_addr <= 9'd511;
            endcase
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_reset_state <= 1'b0;
            polyvec_reset_done <= 1'b0;
            polyvec_reset_addr <= 9'd0;
        end
        else begin
            case (polyvec_reset_state)
                1'b0: begin
                    polyvec_reset_done <= 1'b0;
                    if (polyvec_reset_start) begin
                        polyvec_reset_state <= 1'b1;
                    end
                end
                1'b1: begin
                    if (polyvec_reset_addr == polyvec_reset_last_addr) begin
                        polyvec_reset_state <= 1'b0;
                        polyvec_reset_done <= 1'b1;
                        polyvec_reset_addr <= 9'd0;
                    end
                    else begin
                        polyvec_reset_addr <= polyvec_reset_addr + 1'b1;
                    end
                end
            endcase
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            polyvec_clear_after_read <= 1'b0;
            polyvec_clear_after_read_addr <= 9'd0;
        end
        else begin
            polyvec_clear_after_read <= polyvec_read_from_ext;
            polyvec_clear_after_read_addr <= polyvec_read_addr_ext;
        end
    end

    assign polyvec_result_re = polyvec_read_from_ext | polyvec_source_valid;
    assign polyvec_result_we = polyvec_write_from_ext | polyvec_clear_after_read 
                                | polyvec_reset_state | polyvec_result_we_r;
    assign polyvec_result_raddr = polyvec_source_valid ? polyvec_source_addr : polyvec_read_addr_ext;
    assign polyvec_result_waddr = polyvec_write_from_ext ? polyvec_write_addr_ext 
                                : polyvec_clear_after_read ? polyvec_clear_after_read_addr 
                                : polyvec_reset_state ? polyvec_reset_addr 
                                : polyvec_result_waddr_r;
    assign polyvec_result_din = polyvec_write_from_ext ? polyvec_write_data_ext 
                                : (polyvec_reset_state | polyvec_clear_after_read) ? 24'd0 
                                : {polyvec_result_in_high, polyvec_result_in_low};

    always @(posedge aclk) begin
        if (polyvec_result_re) begin
            polyvec_result_rdata <= polyvec_result[polyvec_result_raddr];
        end
        if (polyvec_result_we) begin
            polyvec_result[polyvec_result_waddr] <= polyvec_result_din;
        end
    end

    function [11:0] fqadd;
        input [11:0] x;
        input [11:0] y;
        reg [12:0] sum;
        begin
            sum = {1'b0, x} + {1'b0, y};
            fqadd = (sum >= Q) ? (sum - Q) : sum[11:0];
        end
    endfunction

    function [11:0] fqsub;
        input [11:0] x;
        input [11:0] y;
        reg [12:0] result;
        begin
            result = {1'b0, x} - {1'b0, y};
            fqsub = result[12] ? (result + Q) : result[11:0];
        end
    endfunction

endmodule
