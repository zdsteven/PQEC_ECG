module Kyber (
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
    output           s_rlast
);

    localparam CTRL_ADDR       = 16'h0000;
    //ctrl[0] = 1: start operation, 0: idle
    //ctrl[1] = 1: clear done status, 0: do not clear
    //ctrl[2] = 1: start NTT, 0: start INTT (only valid when ctrl[0] is 1)
    localparam STATUS_ADDR     = 16'h0004;
    //status[0] = 1: operation done, 0: busy
    //status[1] = 1: NTT, 0: INTT

    localparam DATA_BASE_ADDR  = 16'h0100;
    localparam DATA_LAST_ADDR  = DATA_BASE_ADDR + 128 * 4 - 4;


//-------------------------------{axi ctrl}begin----------------------------//
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
    reg         read_pipe_is_memory;
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
//--------------------------------{axi ctrl}end-----------------------------//

//---------------------------------{NTT}begin-------------------------------//
    wire write_addr_is_memory = (write_addr[15:0] >= DATA_BASE_ADDR) & (write_addr[15:0] <= DATA_LAST_ADDR);
    wire read_addr_is_memory = (read_addr[15:0] >= DATA_BASE_ADDR) & (read_addr[15:0] <= DATA_LAST_ADDR);
    wire ntt_intt_load_en = w_fire & write_addr_is_memory;
    wire [23:0] ntt_intt_load_data = {s_wdata[27:16], s_wdata[11:0]};
    wire ntt_intt_start = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[0] == 1'b1);
    wire [7:0] ntt_write_word_index = write_addr[9:2] - DATA_BASE_ADDR[9:2];
    wire [7:0] ntt_read_word_index = read_addr[9:2] - DATA_BASE_ADDR[9:2];
    wire [6:0] ntt_intt_data_address = write_active ? ntt_write_word_index[6:0] : ntt_read_word_index[6:0];
    wire ntt_intt_read_en = read_issue & read_addr_is_memory;
    wire [31:0] ntt_intt_read_data;
    wire ntt_intt_done;
    wire ntt_intt_clear_done = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[1] == 1'b1);
//---------------------------------{NTT}end---------------------------------//

//--------------------------------------------------------------------------------------------------------//
//--------------------------------------------------------------------------------------------------------//
//--------------------------------------------------------------------------------------------------------//

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

    wire [31:0] rdata_d = (read_addr[15:0] == STATUS_ADDR) ? status_reg : 32'b0;

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
            read_pipe_is_memory <= 1'b0;
            read_pipe_rdata <= 32'b0;
        end
        else begin
            if (pipe_can_advance) begin
                s_rdata_r  <= read_pipe_is_memory ? ntt_intt_read_data : read_pipe_rdata;
                s_rvalid_r <= 1'b1;
                s_rlast_r  <= read_pipe_last;
            end
            else if (r_fire) begin
                s_rvalid_r <= 1'b0;
            end

            if (read_issue) begin
                read_pipe_last <= (read_beats_left == 8'd1);
                read_pipe_is_memory <= read_addr_is_memory;
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
        else if (ntt_intt_start) begin
            status_reg[1:0] <= {s_wdata[2], 1'b0};
        end
        else if (ntt_intt_clear_done) begin
            status_reg[0] <= 1'b0;
        end
        else if (ntt_intt_done) begin
            status_reg[0] <= 1'b1;
        end
    end
//--------------------------------{axi ctrl}end-----------------------------//

//---------------------------------{NTT}begin-------------------------------//
    NTT_INTT u_NTT_INTT(
        .aclk         (aclk                 ),
        .aresetn      (aresetn              ),
        .load_en      (ntt_intt_load_en     ),
        .load_data    (ntt_intt_load_data   ),
        .start        (ntt_intt_start       ),
        .data_address (ntt_intt_data_address),
        .mode         (s_wdata[2]           ), 
        .read_en      (ntt_intt_read_en     ),
        .read_data    (ntt_intt_read_data   ),
        .done         (ntt_intt_done        )
    );
//---------------------------------{NTT}end---------------------------------//


    
endmodule
