module Crypto (
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
    //ctrl[0] = 1: ntt_intt_start, 0: idle
    //ctrl[1] = 1: reserved
    //ctrl[2] = 1: start NTT, 0: start INTT (only valid when ctrl[0] is 1)
    //ctrl[3] = 1: reset Hash data
    //ctrl[4] = 1: iterate Hash
    //ctrl[6:5] Hash mode: 00:normal 01:rej 10:cbd(eta = 2) 11:cbd(eta = 3)
    //ctrl[7] = 1: start basemul
    //ctrl[8] = 1: polyvec fqadd from sample
    //ctrl[9] = 1: polyvec fqadd from ntt_intt
    //ctrl[11:10] : polyvec_addr_high
    //ctrl [12] : polyvec reset
    //ctrl [14:13] : polyvec reset bank quantity
    //ctrl[15] : polyvec fqadd from intt 0: add 1: sub
    //ctrl[16] :aes init
    //ctrl[17] :aes keylen 0: 128bit 1: 256bit
    //ctrl[18] :aes start
    localparam STATUS_ADDR     = 16'h0004;
    //status[0] = 1: ntt_intt buzy
    //status[1] = 1: Hash buzy
    //status[2] = 1: polyvec reset buzy
    //status[3] = 1: polyvec buzy
    //status[4] = 1: aes buzy

    localparam NTT_INTT_DATA_BASE_ADDR  = 16'h0100;
    localparam NTT_INTT_DATA_LAST_ADDR  = NTT_INTT_DATA_BASE_ADDR + 128 * 4 - 4;//16'h02FC
    localparam HASH_DATA_BASE_ADDR = 16'h0300;
    localparam HASH_DATA_LAST_ADDR = HASH_DATA_BASE_ADDR + 128 * 4 - 4;//16'h04FC
    localparam BASEMUL_DATA_BASE_ADDR = 16'h0500;
    localparam BASEMUL_DATA_LAST_ADDR = BASEMUL_DATA_BASE_ADDR + 128 * 4 - 4;//16'h06FC
    localparam POLYVEC_DATA_BASE_ADDR = 16'h0700;
    localparam POLYVEC_DATA_LAST_ADDR = POLYVEC_DATA_BASE_ADDR + 512 * 4 - 4;//16'h0EFC

    localparam AES_DATA_BASE_ADDR = 16'h0F00;
    localparam AES_DATA_LAST_ADDR = AES_DATA_BASE_ADDR + 64 * 4 - 4;//16'h0FFC
    localparam AES_KEY_BASE_ADDR = 16'h1000;
    localparam AES_KEY_LAST_ADDR = AES_KEY_BASE_ADDR + 8 * 4 - 4;//16'h101C
    localparam AES_NONCE_COUNTER_ADDR = 16'h1020;
    localparam AES_NONCE_2_ADDR = 16'h1024;
    localparam AES_NONCE_1_ADDR = 16'h1028;



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
    reg         read_pipe_is_ntt_intt;
    reg         read_pipe_is_hash;
    reg         read_pipe_is_polyvec;
    reg         read_pipe_is_aes;
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
    //wire clear_done = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[1] == 1'b1);
//--------------------------------{axi ctrl}end----------------------------//

    wire [6:0] write_word_index = {~write_addr[8], write_addr[7:2]};
    wire [6:0] read_word_index = {~read_addr[8], read_addr[7:2]};

//---------------------------------{basemul_ctrl}begin---------------------//
    wire write_addr_is_basemul = write_addr[11:8] == 4'b0101 | write_addr[11:8] == 4'b0110;
    wire basemul_start = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[7] == 1'b1);
    wire basemul_state;
    wire [6:0] basemul_request_addr;
    wire basemul_valid_out;
    wire [23:0] basemul_result;
//---------------------------------{basemul_ctrl}end------------------------//

//---------------------------------{polyvec}begin---------------------------//
    wire read_addr_is_polyvec = read_addr[11:8] >= 4'b0111 & read_addr[11:8] <= 4'b1110;
    wire write_addr_is_polyvec = write_addr[11:8] >= 4'b0111 & write_addr[11:8] <= 4'b1110;
    wire [8:0] polyvec_read_addr_ext = {read_addr[11] & (read_addr[10] | (read_addr[9] & read_addr[8])),
                                        (read_addr[9] ^ read_addr[8]), read_word_index};
    wire [8:0] polyvec_write_addr_ext = {write_addr[11] & (write_addr[10] | (write_addr[9] & write_addr[8])),
                                        (write_addr[9] ^ write_addr[8]), write_word_index};
    wire polyvec_write_from_ext = w_fire & write_addr_is_polyvec;
    wire polyvec_fqadd_from_sample_start = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[8] == 1'b1);
    wire polyvec_fqadd_from_intt_start = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[9] == 1'b1);
    wire polyvec_reset_start = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[12] == 1'b1);
    wire polyvec_from_sample_state;
    wire [6:0] polyvec_sample_take_addr;
    wire polyvec_from_intt_state;
    wire [6:0] polyvec_intt_take_addr;
    wire [31:0] polyvec_read_data;
    wire polyvec_done;
    wire polyvec_reset_done;
//---------------------------------{polyvec}end-----------------------------//


//---------------------------------{NTT}begin-------------------------------//
    wire write_addr_is_ntt_intt = write_addr[11:8] == 4'b0001 | write_addr[11:8] == 4'b0010;
    wire read_addr_is_ntt_intt = read_addr[11:8] == 4'b0001 | read_addr[11:8] == 4'b0010;
    wire ntt_intt_load_en = w_fire & write_addr_is_ntt_intt;
    wire [23:0] ntt_intt_load_data = {s_wdata[27:16], s_wdata[11:0]};
    wire ntt_intt_start = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[0] == 1'b1);
    wire [6:0] ntt_intt_data_address = basemul_state ? basemul_request_addr
                                        : polyvec_from_intt_state ? polyvec_intt_take_addr
                                        : write_active ? write_word_index
                                        : read_word_index;
    wire ntt_intt_read_en = (read_issue & read_addr_is_ntt_intt) |
                            basemul_state | polyvec_from_intt_state;
    wire [31:0] ntt_intt_read_data;
    wire ntt_intt_done;
//---------------------------------{NTT}end---------------------------------//

//---------------------------------{Hash}begin------------------------------//
    wire write_addr_is_hash = write_addr[11:8] == 4'b0011 | write_addr[11:8] == 4'b0100;
    wire read_addr_is_hash = read_addr[11:8] == 4'b0011 | read_addr[11:8] == 4'b0100;
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
    wire Hash_sample = (read_issue & read_addr_is_hash & Hash_mode_is_sample) | polyvec_from_sample_state;
    wire [6:0] Hash_sample_out_address = polyvec_from_sample_state ? polyvec_sample_take_addr : read_word_index;
    wire [31:0] Hash_sample_data;
    wire Hash_done;
//---------------------------------{Hash}end--------------------------------//

//---------------------------------{aes}begin-------------------------------//
    // aes Inputs
    wire write_addr_is_aes = write_addr[11:8] == 4'b1111;
    wire read_addr_is_aes = read_addr[11:8] == 4'b1111;
    wire aes_init = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[16] == 1'b1);
    wire aes_keylen = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[17] == 1'b1);
    wire aes_start = w_fire & (write_addr[15:0] == CTRL_ADDR) & (s_wdata[18] == 1'b1);
    wire aes_load_key_en = w_fire & write_addr[12] & (~write_addr[5]);
    wire [2:0] aes_load_key_addr = write_addr[4:2];
    wire [31:0] aes_load_key = s_wdata;
    reg [95:0] aes_nonce;
    wire aes_load_ct_data_en = w_fire & write_addr_is_aes;
    wire [5:0] aes_load_ct_data_addr = write_addr[7:2];
    wire [31:0] aes_load_ct_data = s_wdata;
    wire aes_take_ct_data_en = read_issue & read_addr_is_aes;
    wire [5:0] aes_take_ct_data_addr = read_addr[7:2];
    wire [31:0] aes_take_ct_data;
    wire aes_ready;
//---------------------------------{aes}end---------------------------------//

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
            read_pipe_is_polyvec <= 1'b0;
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
                else if (read_pipe_is_polyvec) begin
                    s_rdata_r <= polyvec_read_data;
                end
                else if(read_pipe_is_aes) begin
                    s_rdata_r <= aes_take_ct_data;
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
                read_pipe_is_polyvec <= read_addr_is_polyvec;
                read_pipe_is_aes <= read_addr_is_aes;
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
            if (ntt_intt_done) begin
                status_reg[0] <= 1'b0;
            end
            else if (ntt_intt_start) begin
                status_reg[0] <= 1'b1;
            end
            if (Hash_done) begin
                status_reg[1] <= 1'b0;
            end
            else if (Hash_iterate) begin
                status_reg[1] <= 1'b1;
            end
            if (polyvec_reset_done) begin
                status_reg[2] <= 1'b0;
            end
            else if (polyvec_reset_start) begin
                status_reg[2] <= 1'b1;
            end
            if (polyvec_done) begin
                status_reg[3] <= 1'b0;
            end
            else if (basemul_start | polyvec_fqadd_from_sample_start | polyvec_fqadd_from_intt_start) begin
                status_reg[3] <= 1'b1;
            end
            if (aes_start | aes_init) begin
                status_reg[4] <= 1'b1;
            end
            else if (aes_ready) begin
                status_reg[4] <= 1'b0;
            end
        end
    end
//--------------------------------{axi ctrl}end-----------------------------//

//---------------------------------{basemul}begin---------------------------//
    Basemul_ctrl u_Basemul_ctrl (
        .aclk                       (aclk                            ),
        .aresetn                    (aresetn                         ),
        .basemul_start              (basemul_start                   ),
        .basemul_bank_in_we         (w_fire & write_addr_is_basemul  ),
        .basemul_bank_in_write_addr (write_word_index                ),
        .basemul_bank_in_din        ({s_wdata[27:16], s_wdata[11:0]} ),
        .ntt_intt_read_data         (ntt_intt_read_data              ),
        .basemul_state              (basemul_state                   ),
        .basemul_request_addr       (basemul_request_addr            ),
        .basemul_result             (basemul_result                  ),
        .basemul_valid_out          (basemul_valid_out               )
    );

//---------------------------------{basemul}end-----------------------------//

//---------------------------------{polyvec}begin---------------------------//
    Polyvec u_Polyvec (
        .aclk                            (aclk                            ),
        .aresetn                         (aresetn                         ),
        .basemul_start                   (basemul_start                   ),
        .basemul_valid_out               (basemul_valid_out               ),
        .basemul_result                  (basemul_result                  ),
        .polyvec_fqadd_from_sample_start (polyvec_fqadd_from_sample_start ),
        .polyvec_fqadd_from_intt_start   (polyvec_fqadd_from_intt_start   ),
        .polyvec_reset_start             (polyvec_reset_start             ),
        .polyvec_addr_high_in            (s_wdata[11:10]                  ),
        .polyvec_is_sub_in               (s_wdata[15]                     ),
        .polyvec_reset_mode              (s_wdata[14:13]                  ),
        .polyvec_read_from_ext           (read_issue & read_addr_is_polyvec),
        .polyvec_read_addr_ext           (polyvec_read_addr_ext           ),
        .polyvec_write_from_ext          (polyvec_write_from_ext          ),
        .polyvec_write_addr_ext          (polyvec_write_addr_ext          ),
        .polyvec_write_data_ext          ({s_wdata[27:16], s_wdata[11:0]} ),
        .Hash_sample_data                (Hash_sample_data                ),
        .ntt_intt_read_data              (ntt_intt_read_data              ),
        .polyvec_from_sample_state       (polyvec_from_sample_state       ),
        .polyvec_sample_take_addr        (polyvec_sample_take_addr        ),
        .polyvec_from_intt_state         (polyvec_from_intt_state         ),
        .polyvec_intt_take_addr          (polyvec_intt_take_addr          ),
        .polyvec_read_data               (polyvec_read_data               ),
        .polyvec_done                    (polyvec_done                    ),
        .polyvec_reset_done              (polyvec_reset_done              )
    );

//---------------------------------{polyvec}end-----------------------------//

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

//---------------------------------{aes}begin-------------------------------//
    always @(posedge aclk) begin
        if (~aresetn) begin
            aes_nonce <= 96'b0;
        end
        else if (w_fire & write_addr[12] & write_addr[5] & (write_addr[3:2] == 2'd0)) begin
            aes_nonce[31:0] <= s_wdata;
        end
        else if (w_fire & write_addr[12] & write_addr[5] & (write_addr[3:2] == 2'd1)) begin
            aes_nonce[63:32] <= {s_wdata[7:0], s_wdata[15:8], s_wdata[23:16], s_wdata[31:24]};
        end
        else if (w_fire & write_addr[12] & write_addr[5] & (write_addr[3:2] == 2'd2)) begin
            aes_nonce[95:64] <= {s_wdata[7:0], s_wdata[15:8], s_wdata[23:16], s_wdata[31:24]};
        end
    end

    aes  u_aes (
        .clk                     ( aclk                 ),
        .reset_n                 ( aresetn              ),
        .init                    ( aes_init             ),
        .start                   ( aes_start            ),
        .keylen                  ( aes_keylen           ),
        .load_key_en             ( aes_load_key_en      ),
        .load_key_addr           ( aes_load_key_addr    ),
        .load_key                ( aes_load_key         ),
        .nonce                   ( aes_nonce            ),
        .load_ct_data_en         ( aes_load_ct_data_en  ),
        .load_ct_data_addr       ( aes_load_ct_data_addr),
        .load_ct_data            ( aes_load_ct_data     ),
        .take_ct_data_en         ( aes_take_ct_data_en  ),
        .take_ct_data_addr       ( aes_take_ct_data_addr),
        .ready                   ( aes_ready            ),
        .take_ct_data            ( aes_take_ct_data     )
    );
//---------------------------------{aes}end---------------------------------//

endmodule
