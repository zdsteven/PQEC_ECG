module aes (
    input clk,
    input reset_n,

    input init,
    input start,
    output reg ready,

    input keylen,
    input load_key_en,
    input [2:0] load_key_addr,
    input [31:0] load_key,

    input [95:0] nonce,

    input load_ct_data_en,
    input [5:0] load_ct_data_addr,
    input [31:0] load_ct_data,

    input take_ct_data_en,
    input [5:0] take_ct_data_addr,
    output [31:0] take_ct_data
);

    localparam CT_LAST_WORD = 6'd49;
    localparam CTR_START = 32'd2;

    localparam CTRL_IDLE = 7'b000_0001;
    localparam CTRL_KEY_START = 7'b000_0010;
    localparam CTRL_KEY_WAIT = 7'b000_0100;
    localparam CTRL_ENC_START = 7'b000_1000;
    localparam CTRL_ENC_WAIT = 7'b001_0000;
    localparam CTRL_READ_DATA = 7'b010_0000;
    localparam CTRL_XOR_DATA = 7'b100_0000;

    reg [6:0] state;

    reg keylen_reg;

    reg [31:0] key_word [0:7];
    reg [95:0] nonce_reg;
    reg [31:0] counter_reg;

    reg [5:0] ct_word_ctr_reg;
    reg [1:0] stream_word_ctr_reg;
    reg [127:0] stream_block_reg;

    (* ram_style = "distributed" *) reg [31:0] ct_ram [0:49];
    reg [31:0] ct_ram_rdata;

    wire [255:0] key_core = {
        key_word[0], key_word[1], key_word[2], key_word[3],
        key_word[4], key_word[5], key_word[6], key_word[7]
    };

    wire [127:0] ctr_block = {nonce_reg, counter_reg};
    wire [127:0] enc_block;

    wire [127:0] round_key;
    wire key_ready;

    wire [3:0] enc_round_nr;
    wire enc_ready;

    wire [31:0] enc_sboxw;
    wire [31:0] keymem_sboxw;
    reg [31:0] muxed_sboxw;
    wire [31:0] new_sboxw;

    wire key_init = state[1];
    wire enc_next = state[3];
    wire keymem_active = state[1] || state[2];

    wire ct_ram_load_we = state[0] && load_ct_data_en;
    wire ct_ram_xor_we = state[6];
    wire ct_ram_we = ct_ram_load_we || ct_ram_xor_we;
    wire [5:0] ct_ram_waddr = ct_ram_xor_we ? ct_word_ctr_reg : load_ct_data_addr;
    wire [31:0] ct_ram_wdata = ct_ram_xor_we ? (ct_ram_rdata ^ stream_word(stream_block_reg, stream_word_ctr_reg)) 
                                : load_ct_data;

    wire ct_ram_internal_re = state[5];
    wire ct_ram_take_re = state[0] && take_ct_data_en;
    wire ct_ram_re = ct_ram_internal_re || ct_ram_take_re;
    wire [5:0] ct_ram_raddr = ct_ram_internal_re ? ct_word_ctr_reg : take_ct_data_addr;

    assign take_ct_data = ct_ram_rdata;

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
            keylen_reg <= 1'b0;
            nonce_reg <= 96'h0;
            counter_reg <= 32'h0;
            ct_word_ctr_reg <= 6'h0;
            stream_word_ctr_reg <= 2'h0;
            stream_block_reg <= 128'h0;
        end else begin
            case (state)
                CTRL_IDLE: begin
                    if (init) begin
                        keylen_reg <= keylen;
                        ready <= 1'b0;
                        state <= CTRL_KEY_START;
                    end else if (start) begin
                        nonce_reg <= nonce;
                        counter_reg <= CTR_START;
                        ct_word_ctr_reg <= 6'h0;
                        stream_word_ctr_reg <= 2'h0;
                        ready <= 1'b0;
                        state <= CTRL_ENC_START;
                    end
                    else begin
                        ready <= 1'b1;
                    end
                end

                CTRL_KEY_START: begin
                    state <= CTRL_KEY_WAIT;
                end

                CTRL_KEY_WAIT: begin
                    if (key_ready) begin
                        ready <= 1'b1;
                        state <= CTRL_IDLE;
                    end
                end

                CTRL_ENC_START: begin
                    state <= CTRL_ENC_WAIT;
                end

                CTRL_ENC_WAIT: begin
                    if (enc_ready) begin
                        stream_block_reg <= enc_block;
                        stream_word_ctr_reg <= 2'h0;
                        state <= CTRL_READ_DATA;
                    end
                end

                CTRL_READ_DATA: begin
                    state <= CTRL_XOR_DATA;
                end

                CTRL_XOR_DATA: begin
                    if (ct_word_ctr_reg == CT_LAST_WORD) begin
                        ready <= 1'b1;
                        state <= CTRL_IDLE;
                    end else begin
                        ct_word_ctr_reg <= ct_word_ctr_reg + 1'b1;
                        if (stream_word_ctr_reg == 2'd3) begin
                            counter_reg <= counter_reg + 1'b1;
                            stream_word_ctr_reg <= 2'h0;
                            state <= CTRL_ENC_START;
                        end else begin
                            stream_word_ctr_reg <= stream_word_ctr_reg + 1'b1;
                            state <= CTRL_READ_DATA;
                        end
                    end
                end

                default: begin
                    ready <= 1'b1;
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
        .block(ctr_block),
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

    function automatic [31:0] swap32(input [31:0] word);
        begin
            swap32 = {word[7:0], word[15:8], word[23:16], word[31:24]};
        end
    endfunction

    function automatic [31:0] stream_word(input [127:0] stream, input [1:0] index);
        begin
            case (index)
                2'd0: stream_word = swap32(stream[127:96]);
                2'd1: stream_word = swap32(stream[95:64]);
                2'd2: stream_word = swap32(stream[63:32]);
                2'd3: stream_word = swap32(stream[31:0]);
            endcase
        end
    endfunction

endmodule
