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
    //ctrl[3] = 1: reset Hash data
    //ctrl[4] = 1: iterate Hash
    //ctrl[6:5] Hash mode: 00:normal 01:rej 10:cbd(eta = 2) 11:cbd(eta = 3)
    localparam STATUS_ADDR     = 16'h0004;
    //status[0] = 1: operation done, 0: busy
    //status[1] = 1: NTT, 0: INTT

    localparam NTT_INTT_DATA_BASE_ADDR  = 16'h0100;
    localparam NTT_INTT_DATA_LAST_ADDR  = NTT_INTT_DATA_BASE_ADDR + 128 * 4 - 4;//16'h02FC
    localparam HASH_DATA_BASE_ADDR = 16'h0300;
    localparam HASH_DATA_LAST_ADDR = HASH_DATA_BASE_ADDR + 128 * 4 - 4;//16'h04FC


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
    reg         read_pipe_is_ntt_intt;
    reg         read_pipe_is_hash;
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
    wire clear_done = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[1] == 1'b1);
//--------------------------------{axi ctrl}end-----------------------------//

    wire [6:0] write_word_index = {~write_addr[8], write_addr[7:2]};
    wire [6:0] read_word_index = {~read_addr[8], read_addr[7:2]};

//---------------------------------{NTT}begin-------------------------------//
    //wire write_addr_is_ntt_intt = (write_addr[15:0] >= NTT_INTT_DATA_BASE_ADDR) & (write_addr[15:0] <= NTT_INTT_DATA_LAST_ADDR);
    //wire read_addr_is_ntt_intt = (read_addr[15:0] >= NTT_INTT_DATA_BASE_ADDR) & (read_addr[15:0] <= NTT_INTT_DATA_LAST_ADDR);
    wire write_addr_is_ntt_intt = write_addr[9] ^ write_addr[8];
    wire read_addr_is_ntt_intt = read_addr[9] ^ read_addr[8];
    wire ntt_intt_load_en = w_fire & write_addr_is_ntt_intt;
    wire [23:0] ntt_intt_load_data = {s_wdata[27:16], s_wdata[11:0]};
    wire ntt_intt_start = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[0] == 1'b1);
    //wire [7:0] ntt_write_word_index = write_addr[9:2] - NTT_INTT_DATA_BASE_ADDR[9:2];
    //wire [7:0] ntt_read_word_index = read_addr[9:2] - NTT_INTT_DATA_BASE_ADDR[9:2];
    wire [6:0] ntt_intt_data_address = write_active ? write_word_index : read_word_index;
    wire ntt_intt_read_en = read_issue & read_addr_is_ntt_intt;
    wire [31:0] ntt_intt_read_data;
    wire ntt_intt_done;
//---------------------------------{NTT}end---------------------------------//

//---------------------------------{Hash}begin------------------------------//
    //wire write_addr_is_hash = (write_addr[15:0] >= HASH_DATA_BASE_ADDR) & (write_addr[15:0] <= HASH_DATA_LAST_ADDR);
    //wire read_addr_is_hash = (read_addr[15:0] >= HASH_DATA_BASE_ADDR) & (read_addr[15:0] <= HASH_DATA_LAST_ADDR);
    wire write_addr_is_hash = write_addr[10] | (write_addr[9] & write_addr[8]);
    wire read_addr_is_hash = read_addr[10] | (read_addr[9] & read_addr[8]);
    //wire [8:0] hash_write_word_index = write_addr[10:2] - HASH_DATA_BASE_ADDR[10:2];
    //wire [8:0] hash_read_word_index = read_addr[10:2] - HASH_DATA_BASE_ADDR[10:2];
    wire Hash_reset_data = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[3] == 1'b1);
    wire Hash_absorb = w_fire & write_addr_is_hash;
    wire [5:0] Hash_absorb_address = write_word_index[5:0];
    wire [31:0] Hash_absorb_data = s_wdata;
    wire Hash_iterate = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[4] == 1'b1);
    reg [1:0] Hash_mode;
    wire Hash_mode_is_sample = Hash_mode[0] | Hash_mode[1];
    wire Hash_squeeze = read_issue & read_addr_is_hash & ~Hash_mode_is_sample;
    wire [5:0] Hash_squeeze_address = read_word_index[5:0];
    wire [31:0] Hash_squeeze_data;
    wire Hash_sample = read_issue & read_addr_is_hash & Hash_mode_is_sample;
    wire [6:0] Hash_sample_out_address = read_word_index;
    wire [31:0] Hash_sample_data;
    wire Hash_done;
//---------------------------------{Hash}end--------------------------------//

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
            read_pipe_is_ntt_intt <= 1'b0;
            read_pipe_is_hash <= 1'b0;
            read_pipe_rdata <= 32'b0;
        end
        else begin
            if (pipe_can_advance) begin
                if (read_pipe_is_ntt_intt) begin
                    s_rdata_r <= ntt_intt_read_data;
                end
                else if (read_pipe_is_hash) begin
                    s_rdata_r <= Hash_mode_is_sample ? Hash_sample_data : Hash_squeeze_data;
                end
                else begin
                    s_rdata_r <= read_pipe_rdata;
                end
                s_rvalid_r <= 1'b1;
                s_rlast_r  <= read_pipe_last;
            end
            else if (r_fire) begin
                s_rvalid_r <= 1'b0;
            end

            if (read_issue) begin
                read_pipe_last <= (read_beats_left == 8'd1);
                read_pipe_is_ntt_intt <= read_addr_is_ntt_intt;
                read_pipe_is_hash <= read_addr_is_hash;
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
        else if (Hash_iterate) begin
            status_reg[0] <= 1'b0;
        end
        else if (clear_done) begin
            status_reg[0] <= 1'b0;
        end
        else if (ntt_intt_done | Hash_done) begin
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

//---------------------------------{Hash}begin------------------------------//
    always @(posedge aclk) begin
        if (~aresetn) begin
            Hash_mode <= 2'b0;
        end
        else if (Hash_iterate) begin
            Hash_mode <= s_wdata[6:5];
        end
    end

    Hash u_Hash(
        .aclk               (aclk                    ),
        .aresetn            (aresetn                 ),
        .reset_data         (Hash_reset_data         ),
        .absorb             (Hash_absorb             ),
        .absorb_address     (Hash_absorb_address     ),
        .absorb_data        (Hash_absorb_data        ),
        .iterate            (Hash_iterate            ),
        .mode               (Hash_mode               ),
        .squeeze            (Hash_squeeze            ),
        .squeeze_address    (Hash_squeeze_address    ),
        .squeeze_data       (Hash_squeeze_data       ),
        .sample             (Hash_sample             ),
        .sample_out_address (Hash_sample_out_address ),
        .sample_data        (Hash_sample_data        ),
        .done               (Hash_done               )
    );
//---------------------------------{Hash}end--------------------------------//


    
endmodule
