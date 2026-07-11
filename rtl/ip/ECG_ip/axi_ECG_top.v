module axi_ECG_top(
    input            aclk,
    input            aresetn,
    input            s_awvalid,
    output           s_awready,
    input   [31:0]   s_awaddr,
    input   [4:0]    s_awid,
    input   [7:0]    s_awlen,
    input   [2:0]    s_awsize,
    input   [1:0]    s_awburst,
    input   [0:0]    s_awlock,
    input   [3:0]    s_awcache,
    input   [2:0]    s_awprot,
    input            s_wvalid,
    output           s_wready,
    input   [31:0]   s_wdata,
    input   [3:0]    s_wstrb,
    input            s_wlast,
    output           s_bvalid,
    input            s_bready,
    output  [4:0]    s_bid,
    output  [1:0]    s_bresp,
    input            s_arvalid,
    output           s_arready,
    input   [31:0]   s_araddr,
    input   [4:0]    s_arid,
    input   [7:0]    s_arlen,
    input   [2:0]    s_arsize,
    input   [1:0]    s_arburst,
    input   [0:0]    s_arlock,
    input   [3:0]    s_arcache,
    input   [2:0]    s_arprot,
    output           s_rvalid,
    input            s_rready,
    output  [31:0]   s_rdata,
    output  [4:0]    s_rid,
    output  [1:0]    s_rresp,
    output           s_rlast,
    output reg       ecg_finish
);

localparam CTRL_ADDR       = 16'h0000;
//ctrl[0] = 1'b1: start inference
localparam STATUS_ADDR     = 16'h0004;
//status[0] = 1'b1: inference busy
localparam RESULT_ADDR_0   = 16'h0008;
//result[2:0] = inference_result, result[15:8] = result_0, result[23:16] = result_1, result[31:24] = result_2
localparam RESULT_ADDR_1   = 16'h000C;
//result[7:0] = result_3, result[15:8] = result_4
localparam LOAD_ECG_ADDR   = 16'h0100;


//-------------------------------{axi ctrl}begin---------------------------//
    reg         busy, write, R_or_W;
    reg         s_wready_r;
    reg [4 :0]  buf_id;
    reg [31:0]  buf_addr;
    reg [7 :0]  buf_len;
    reg [2 :0]  buf_size;
    reg [1 :0]  buf_burst;
    reg         buf_lock;
    reg [3 :0]  buf_cache;
    reg [2 :0]  buf_prot;

    reg [31:0]  s_rdata_r;
    reg         s_rvalid_r, s_rlast_r;
    reg         s_bvalid_r;

    reg         write_active;
    reg [31:0]  write_addr;
    reg [31:0]  read_addr;
    reg [7:0]   write_beats_left;
    reg [7:0]   read_beats_left;
    reg         read_pipe_valid;
    reg         read_pipe_last;
    reg [31:0]  read_pipe_rdata;

    wire ar_enter = s_arvalid & s_arready;
    wire r_fire   = s_rvalid_r & s_rready;
    wire r_retire = r_fire & s_rlast_r;
    wire aw_enter = s_awvalid & s_awready;
    wire w_fire   = s_wvalid & s_wready_r;
    wire b_retire = s_bvalid_r & s_bready;
    wire write_last = w_fire & (write_beats_left == 8'd1);
    wire pipe_can_advance = read_pipe_valid & (!s_rvalid_r || r_fire);
    wire read_issue = (read_beats_left != 8'd0) & (!read_pipe_valid || pipe_can_advance);

    assign s_arready = ~busy & (!R_or_W | !s_awvalid);
    assign s_awready = ~busy & ( R_or_W | !s_arvalid);

    assign s_wready = s_wready_r;
    assign s_rvalid = s_rvalid_r;
    assign s_rdata  = s_rdata_r;
    assign s_rid    = buf_id;
    assign s_rresp  = 2'b0;
    assign s_rlast  = s_rlast_r;
    assign s_bvalid = s_bvalid_r;
    assign s_bid    = buf_id;
    assign s_bresp  = 2'b0;

    reg [31:0] status_reg;
    reg [31:0] result_reg_0;
    reg [31:0] result_reg_1;
//--------------------------------{axi ctrl}end----------------------------//

//--------------------------------{ECG}begin--------------------------------//
wire  load_ecg_en;
wire  [31:0] load_ecg_data;
wire  [5:0]  load_ecg_address;
wire  start_inference;
wire  [7:0]  result_0;
wire  [7:0]  result_1;
wire  [7:0]  result_2;
wire  [7:0]  result_3;
wire  [7:0]  result_4;
wire  [2:0]  infer_result;
wire  infer_done;
//--------------------------------{ECG}end----------------------------------//


//-------------------------------{axi ctrl}begin----------------------------//
    always @(posedge aclk) begin
        if (~aresetn) begin
            busy <= 1'b0;
        end
        else if (ar_enter | aw_enter) begin
            busy <= 1'b1;
        end
        else if (r_retire | b_retire) begin
            busy <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            R_or_W    <= 1'b0;
            buf_id    <= 5'b0;
            buf_addr  <= 32'b0;
            buf_len   <= 8'b0;
            buf_size  <= 3'b0;
            buf_burst <= 2'b0;
            buf_lock  <= 1'b0;
            buf_cache <= 4'b0;
            buf_prot  <= 3'b0;
        end
        else if (ar_enter | aw_enter) begin
            R_or_W    <= ar_enter;
            buf_id    <= ar_enter ? s_arid    : s_awid;
            buf_addr  <= ar_enter ? s_araddr  : s_awaddr;
            buf_len   <= ar_enter ? s_arlen   : s_awlen;
            buf_size  <= ar_enter ? s_arsize  : s_awsize;
            buf_burst <= ar_enter ? s_arburst : s_awburst;
            buf_lock  <= ar_enter ? s_arlock  : s_awlock;
            buf_cache <= ar_enter ? s_arcache : s_awcache;
            buf_prot  <= ar_enter ? s_arprot  : s_awprot;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            write <= 1'b0;
        end
        else if (aw_enter) begin
            write <= 1'b1;
        end
        else if (ar_enter) begin
            write <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            s_wready_r <= 1'b0;
        end
        else if (aw_enter) begin
            s_wready_r <= 1'b1;
        end
        else if (write_last) begin
            s_wready_r <= 1'b0;
        end
    end

    wire [31:0] rdata_d = (read_addr[15:0] == STATUS_ADDR) ? status_reg 
                        : (read_addr[15:0] == RESULT_ADDR_0) ? result_reg_0
                        : (read_addr[15:0] == RESULT_ADDR_1) ? result_reg_1
                        : 32'b0;

    always @(posedge aclk) begin
        if (~aresetn) begin
            s_bvalid_r <= 1'b0;
        end
        else if (write_last) begin
            s_bvalid_r <= 1'b1;
        end
        else if (b_retire) begin
            s_bvalid_r <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            write_active <= 1'b0;
            write_addr <= 32'b0;
            read_addr <= 32'b0;
            write_beats_left <= 8'd0;
            read_beats_left <= 8'd0;
        end
        else begin
            if (aw_enter) begin
                write_active <= 1'b1;
                write_addr <= s_awaddr;
                write_beats_left <= s_awlen + 8'd1;
            end
            else if (write_last) begin
                write_active <= 1'b0;
            end

            if (w_fire) begin
                write_addr <= write_addr + 32'd4;
                if (write_beats_left != 8'd0) begin
                    write_beats_left <= write_beats_left - 8'd1;
                end
            end

            if (ar_enter) begin
                read_addr <= s_araddr;
                read_beats_left <= s_arlen + 8'd1;
            end

            if (read_issue) begin
                read_addr <= read_addr + 32'd4;
                read_beats_left <= read_beats_left - 8'd1;
            end
        end
    end

    always @(posedge aclk) begin
        if (~aresetn) begin
            s_rdata_r  <= 32'b0;
            s_rvalid_r <= 1'b0;
            s_rlast_r  <= 1'b0;
            read_pipe_valid <= 1'b0;
            read_pipe_last <= 1'b0;
            read_pipe_rdata <= 32'b0;
        end
        else begin
            if (pipe_can_advance) begin
                s_rdata_r <= read_pipe_rdata;
                s_rvalid_r <= 1'b1;
                s_rlast_r  <= read_pipe_last;
            end
            else if (r_fire) begin
                s_rvalid_r <= 1'b0;
            end

            if (read_issue) begin
                read_pipe_last <= (read_beats_left == 8'd1);
                read_pipe_rdata <= rdata_d;
            end

            if (read_issue) begin
                read_pipe_valid <= 1'b1;
            end
            else if (pipe_can_advance) begin
                read_pipe_valid <= 1'b0;
            end

        end
    end

    always @(posedge aclk) begin
        if(~aresetn) begin
            status_reg <= 32'b0;
        end
        else begin
            if (infer_done) begin
                status_reg[0] <= 1'b0;
            end
            else if (start_inference) begin
                status_reg[0] <= 1'b1;
            end
        end
    end

    always @(posedge aclk) begin
        if(~aresetn) begin
            result_reg_0 <= 32'b0;
            result_reg_1 <= 32'b0;
        end
        else if(infer_done) begin
            result_reg_0 <= {result_2, result_1, result_0, 5'b0, infer_result};
            result_reg_1 <= {24'b0, result_4, result_3};
        end
    end

    always @(posedge aclk) begin
        if(~aresetn) begin
            ecg_finish <= 1'b0;
        end
        else if(infer_done) begin
            ecg_finish <= 1'b1;
        end
        else begin
            ecg_finish <= 1'b0;
        end
    end
//--------------------------------{axi ctrl}end-----------------------------//

//--------------------------------{ECG}begin--------------------------------//
    assign load_ecg_en = w_fire & write_addr[8];
    assign load_ecg_data = s_wdata;
    assign load_ecg_address = write_addr[7:2];
    assign start_inference = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[0] == 1'b1);

    ECG u_ECG (
        .aclk                    ( aclk               ),
        .aresetn                 ( aresetn            ),
        .load_ecg_en             ( load_ecg_en        ),
        .load_ecg_data           ( load_ecg_data      ),
        .load_ecg_address        ( load_ecg_address   ),
        .start_inference         ( start_inference    ),
        .result_0                ( result_0           ),
        .result_1                ( result_1           ),
        .result_2                ( result_2           ),
        .result_3                ( result_3           ),
        .result_4                ( result_4           ),
        .infer_result            ( infer_result       ),
        .infer_done              ( infer_done         )
    );

//--------------------------------{ECG}end----------------------------------//

endmodule
