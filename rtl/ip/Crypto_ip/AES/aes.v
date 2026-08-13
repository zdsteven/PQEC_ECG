module aes (
    input clk,
    input reset_n,

    input init,
    input start,
    output reg ready,
    output reg auth_ok,

    input keylen,
    input load_key_en,
    input [2:0] load_key_addr,
    input [31:0] load_key,

    input [95:0] nonce,
    input [127:0] expected_tag,

    input load_ct_data_en,
    input [5:0] load_ct_data_addr,
    input [31:0] load_ct_data,

    input take_ct_data_en,
    input [5:0] take_ct_data_addr,
    output [31:0] take_ct_data
);

    localparam CT_LAST_BLOCK_ADDR = 6'd48;
    localparam TAG_COUNTER = 32'd1;
    localparam DATA_COUNTER_START = 32'd2;
    localparam [127:0] GCM_LENGTH_BLOCK = {64'd0, 64'd1600};

    localparam CTRL_IDLE = 15'h0001;
    localparam CTRL_KEY_START = 15'h0002;
    localparam CTRL_KEY_WAIT = 15'h0004;
    localparam CTRL_H_START = 15'h0008;
    localparam CTRL_H_WAIT = 15'h0010;
    localparam CTRL_TAG_START = 15'h0020;
    localparam CTRL_TAG_WAIT = 15'h0040;
    localparam CTRL_DATA_START = 15'h0080;
    localparam CTRL_DATA_FETCH = 15'h0100;
    localparam CTRL_DATA_HASH = 15'h0200;
    localparam CTRL_DATA_WAIT = 15'h0400;
    localparam CTRL_DATA_WRITE = 15'h0800;
    localparam CTRL_LENGTH_START = 15'h1000;
    localparam CTRL_LENGTH_WAIT = 15'h2000;
    localparam CTRL_VERIFY = 15'h4000;

    reg [14:0] state;

    reg keylen_reg;
    reg [31:0] key_word [0:7];

    reg [95:0] nonce_reg;
    reg [127:0] expected_tag_reg;
    reg [31:0] counter_reg;

    reg [5:0] ct_word_ctr_reg;
    reg [1:0] fetch_word_ctr_reg;
    reg [1:0] write_word_ctr_reg;
    reg [127:0] ciphertext_block_reg;
    reg [127:0] stream_block_reg;

    reg [127:0] aes_block_reg;
    reg [127:0] hash_subkey_reg;
    reg [127:0] tag_mask_reg;

    reg [31:0] ct_ram [0:49];
    reg [31:0] ct_ram_rdata;

    wire [255:0] key_core = {
        key_word[0], key_word[1], key_word[2], key_word[3],
        key_word[4], key_word[5], key_word[6], key_word[7]
    };

    wire [127:0] enc_block;
    wire [127:0] round_key;
    wire key_ready;
    wire [3:0] enc_round_nr;
    wire enc_ready;

    wire [31:0] enc_sboxw;
    wire [31:0] keymem_sboxw;
    reg [31:0] muxed_sboxw;
    wire [31:0] new_sboxw;

    wire [127:0] ghash_digest;
    wire ghash_ready;

    wire key_init = state[1];
    wire enc_next = state[3] || state[5] || state[7];
    wire keymem_active = state[1] || state[2];

    wire ghash_init = state[6] && enc_ready;
    wire ghash_next = state[9] || state[12];
    wire [127:0] ghash_block = state[12] ? GCM_LENGTH_BLOCK : ciphertext_block_reg;

    wire last_data_block = (ct_word_ctr_reg == CT_LAST_BLOCK_ADDR);
    wire [1:0] current_block_words = last_data_block ? 2'd1 : 2'd3;
    wire fetch_last_word = (fetch_word_ctr_reg == current_block_words);
    wire write_last_word = (write_word_ctr_reg == current_block_words);

    wire ct_ram_load_we = state[0] && load_ct_data_en;
    wire ct_ram_decrypt_we = state[11];
    wire ct_ram_we = ct_ram_load_we || ct_ram_decrypt_we;
    wire [5:0] ct_ram_waddr = ct_ram_decrypt_we ? (ct_word_ctr_reg + write_word_ctr_reg) : load_ct_data_addr;
    wire [31:0] ct_ram_wdata =  ct_ram_decrypt_we ? 
                                rearange_block(ciphertext_block_reg, write_word_ctr_reg) ^ 
                                rearange_block(stream_block_reg, write_word_ctr_reg) 
                                : load_ct_data;

    wire ct_ram_internal_re = state[7] || (state[8] && !fetch_last_word);
    wire ct_ram_take_re = state[0] && take_ct_data_en && auth_ok;
    wire ct_ram_re = ct_ram_internal_re || ct_ram_take_re;
    wire [5:0] ct_ram_internal_raddr = state[7] ? ct_word_ctr_reg 
                                        : (ct_word_ctr_reg + fetch_word_ctr_reg + 1'b1);
    wire [5:0] ct_ram_raddr = ct_ram_internal_re ? ct_ram_internal_raddr : take_ct_data_addr;

    wire [127:0] calculated_tag = tag_mask_reg ^ ghash_digest;
    assign take_ct_data = auth_ok ? ct_ram_rdata : 32'h0;

    always @(posedge clk) begin
        if (load_key_en) begin
            key_word[load_key_addr] <= swap32(load_key);
        end
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            ct_ram_rdata <= 32'h0;
        end else begin
            if (ct_ram_we) begin
                ct_ram[ct_ram_waddr] <= ct_ram_wdata;
            end

            if (ct_ram_re) begin
                ct_ram_rdata <= ct_ram[ct_ram_raddr];
            end
        end
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            state <= CTRL_IDLE;
            ready <= 1'b1;
            auth_ok <= 1'b0;
            keylen_reg <= 1'b0;
            nonce_reg <= 96'h0;
            expected_tag_reg <= 128'h0;
            counter_reg <= 32'h0;
            ct_word_ctr_reg <= 6'h0;
            fetch_word_ctr_reg <= 2'h0;
            write_word_ctr_reg <= 2'h0;
            ciphertext_block_reg <= 128'h0;
            stream_block_reg <= 128'h0;
            aes_block_reg <= 128'h0;
            hash_subkey_reg <= 128'h0;
            tag_mask_reg <= 128'h0;
        end else begin
            case (state)
                CTRL_IDLE: begin
                    if (init) begin
                        keylen_reg <= keylen;
                        ready <= 1'b0;
                        auth_ok <= 1'b0;
                        state <= CTRL_KEY_START;
                    end else if (start) begin
                        nonce_reg <= nonce;
                        expected_tag_reg <= rearange_tag(expected_tag);
                        ct_word_ctr_reg <= 6'h0;
                        aes_block_reg <= {nonce, TAG_COUNTER};
                        ready <= 1'b0;
                        auth_ok <= 1'b0;
                        state <= CTRL_TAG_START;
                    end else begin
                        ready <= 1'b1;
                    end
                end

                CTRL_KEY_START: begin
                    state <= CTRL_KEY_WAIT;
                end

                CTRL_KEY_WAIT: begin
                    if (key_ready) begin
                        aes_block_reg <= 128'h0;
                        state <= CTRL_H_START;
                    end
                end

                CTRL_H_START: begin
                    state <= CTRL_H_WAIT;
                end

                CTRL_H_WAIT: begin
                    if (enc_ready) begin
                        hash_subkey_reg <= enc_block;
                        ready <= 1'b1;
                        state <= CTRL_IDLE;
                    end
                end

                CTRL_TAG_START: begin
                    state <= CTRL_TAG_WAIT;
                end

                CTRL_TAG_WAIT: begin
                    if (enc_ready) begin
                        tag_mask_reg <= enc_block;
                        counter_reg <= DATA_COUNTER_START;
                        state <= CTRL_DATA_START;
                    end
                end

                CTRL_DATA_START: begin
                    fetch_word_ctr_reg <= 2'h0;
                    ciphertext_block_reg <= 128'h0;
                    aes_block_reg <= {nonce_reg, counter_reg};
                    state <= CTRL_DATA_FETCH;
                end

                CTRL_DATA_FETCH: begin
                    case (fetch_word_ctr_reg)
                        2'd0: ciphertext_block_reg[127:96] <= swap32(ct_ram_rdata);
                        2'd1: ciphertext_block_reg[95:64] <= swap32(ct_ram_rdata);
                        2'd2: ciphertext_block_reg[63:32] <= swap32(ct_ram_rdata);
                        2'd3: ciphertext_block_reg[31:0] <= swap32(ct_ram_rdata);
                    endcase

                    if (fetch_last_word) begin
                        state <= CTRL_DATA_HASH;
                    end else begin
                        fetch_word_ctr_reg <= fetch_word_ctr_reg + 1'b1;
                    end
                end

                CTRL_DATA_HASH: begin
                    state <= CTRL_DATA_WAIT;
                end

                CTRL_DATA_WAIT: begin
                    if (enc_ready && ghash_ready) begin
                        stream_block_reg <= enc_block;
                        write_word_ctr_reg <= 2'h0;
                        state <= CTRL_DATA_WRITE;
                    end
                end

                CTRL_DATA_WRITE: begin
                    if (write_last_word) begin
                        if (last_data_block) begin
                            state <= CTRL_LENGTH_START;
                        end else begin
                            counter_reg <= counter_reg + 1'b1;
                            ct_word_ctr_reg <= ct_word_ctr_reg + 3'd4;
                            state <= CTRL_DATA_START;
                        end
                    end else begin
                        write_word_ctr_reg <= write_word_ctr_reg + 1'b1;
                    end
                end

                CTRL_LENGTH_START: begin
                    state <= CTRL_LENGTH_WAIT;
                end

                CTRL_LENGTH_WAIT: begin
                    if (ghash_ready) begin
                        state <= CTRL_VERIFY;
                    end
                end

                CTRL_VERIFY: begin
                    auth_ok <= ~|(calculated_tag ^ expected_tag_reg);
                    ready <= 1'b1;
                    state <= CTRL_IDLE;
                end

                default: begin
                    ready <= 1'b1;
                    auth_ok <= 1'b0;
                    state <= CTRL_IDLE;
                end
            endcase
        end
    end

    always @(*) begin
        if (keymem_active) begin
            muxed_sboxw = keymem_sboxw;
        end else begin
            muxed_sboxw = enc_sboxw;
        end
    end

    aes_encipher_block u_aes_encipher_block (
        .clk(clk),
        .reset_n(reset_n),
        .next(enc_next),
        .keylen(keylen_reg),
        .round(enc_round_nr),
        .round_key(round_key),
        .sboxw(enc_sboxw),
        .new_sboxw(new_sboxw),
        .block(aes_block_reg),
        .new_block(enc_block),
        .ready(enc_ready)
    );

    aes_key_mem u_aes_key_mem (
        .clk(clk),
        .reset_n(reset_n),
        .key(key_core),
        .keylen(keylen_reg),
        .init(key_init),
        .round(enc_round_nr),
        .round_key(round_key),
        .ready(key_ready),
        .sboxw(keymem_sboxw),
        .new_sboxw(new_sboxw)
    );

    aes_sbox u_aes_sbox (
        .sboxw(muxed_sboxw),
        .new_sboxw(new_sboxw)
    );

    ghash u_ghash (
        .clk(clk),
        .reset_n(reset_n),
        .init(ghash_init),
        .next(ghash_next),
        .hash_subkey(hash_subkey_reg),
        .block(ghash_block),
        .digest(ghash_digest),
        .ready(ghash_ready)
    );

    function automatic [31:0] swap32(input [31:0] word);
        begin
            swap32 = {word[7:0], word[15:8], word[23:16], word[31:24]};
        end
    endfunction

    function automatic [31:0] rearange_block(input [127:0] block, input [1:0] index);
        begin
            case (index)
                2'd0: rearange_block = swap32(block[127:96]);
                2'd1: rearange_block = swap32(block[95:64]);
                2'd2: rearange_block = swap32(block[63:32]);
                2'd3: rearange_block = swap32(block[31:0]);
            endcase
        end
    endfunction

    function automatic [127:0] rearange_tag(input [127:0] tag);
        begin
            rearange_tag = {swap32(tag[31:0]), swap32(tag[63:32]), swap32(tag[95:64]), swap32(tag[127:96])};
        end
    endfunction

endmodule
