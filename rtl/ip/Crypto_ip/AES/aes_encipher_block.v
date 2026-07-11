module aes_encipher_block (
    input clk,
    input reset_n,
    input next,

    input keylen,
    output reg [3:0] round,
    input [127:0] round_key,

    output reg [31:0] sboxw,
    input [31:0] new_sboxw,

    input [127:0] block,
    output [127:0] new_block,
    output reg ready
);

    localparam AES_128_BIT_KEY = 1'h0;
    localparam AES_256_BIT_KEY = 1'h1;

    localparam AES128_ROUNDS = 4'd10;
    localparam AES256_ROUNDS = 4'd14;

    localparam CTRL_IDLE = 5'b0_0001;
    localparam CTRL_KEY_WAIT = 5'b0_0010;
    localparam CTRL_INIT = 5'b0_0100;
    localparam CTRL_SBOX = 5'b0_1000;
    localparam CTRL_MAIN = 5'b1_0000;

    reg [1:0] sword_ctr_reg;
    reg [31:0] block_w0_reg;
    reg [31:0] block_w1_reg;
    reg [31:0] block_w2_reg;
    reg [31:0] block_w3_reg;

    reg [4:0] state;

    wire [3:0] num_rounds = (keylen == AES_256_BIT_KEY) ? AES256_ROUNDS : AES128_ROUNDS;
    wire [127:0] shiftrows_block = shiftrows(new_block);
    wire [127:0] mixcolumns_block = mixcolumns(shiftrows_block);
    wire [127:0] addkey_init_block = addroundkey(block, round_key);
    wire [127:0] addkey_main_block = addroundkey(mixcolumns_block, round_key);
    wire [127:0] addkey_final_block = addroundkey(shiftrows_block, round_key);

    assign new_block = {block_w0_reg, block_w1_reg, block_w2_reg, block_w3_reg};


    always @(posedge clk) begin
        if (!reset_n) begin
            block_w0_reg <= 32'h0;
            block_w1_reg <= 32'h0;
            block_w2_reg <= 32'h0;
            block_w3_reg <= 32'h0;
            sword_ctr_reg <= 2'h0;
            round <= 4'h0;
            ready <= 1'b1;
            state <= CTRL_IDLE;
        end else begin
            case (state)
                CTRL_IDLE: begin
                    if (next) begin
                        sword_ctr_reg <= 2'h0;
                        round <= 4'h0;
                        ready <= 1'b0;
                        state <= CTRL_KEY_WAIT;
                    end
                end

                CTRL_KEY_WAIT: begin
                    state <= CTRL_INIT;
                end

                CTRL_INIT: begin
                    {block_w0_reg, block_w1_reg, block_w2_reg, block_w3_reg} <= addkey_init_block;
                    round <= round + 1'b1;
                    state <= CTRL_SBOX;
                end

                CTRL_SBOX: begin
                    case (sword_ctr_reg)
                        2'h0: block_w0_reg <= new_sboxw;
                        2'h1: block_w1_reg <= new_sboxw;
                        2'h2: block_w2_reg <= new_sboxw;
                        2'h3: block_w3_reg <= new_sboxw;
                    endcase
                    sword_ctr_reg <= sword_ctr_reg + 1'b1;
                    if (sword_ctr_reg == 2'h3) begin
                        state <= CTRL_MAIN;
                    end
                end

                CTRL_MAIN: begin
                    round <= round + 1'b1;
                    if (round < num_rounds) begin
                        {block_w0_reg, block_w1_reg, block_w2_reg, block_w3_reg} <= addkey_main_block;
                        state <= CTRL_SBOX;
                    end else begin
                        {block_w0_reg, block_w1_reg, block_w2_reg, block_w3_reg} <= addkey_final_block;
                        ready <= 1'b1;
                        state <= CTRL_IDLE;
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
        case (sword_ctr_reg)
            2'h0: sboxw = block_w0_reg;
            2'h1: sboxw = block_w1_reg;
            2'h2: sboxw = block_w2_reg;
            2'h3: sboxw = block_w3_reg;
        endcase
    end

    function automatic [7:0] gm2(input [7:0] op);
        begin
            gm2 = {op[6:4], op[3] ^ op[7], op[2] ^ op[7], op[1], op[0] ^ op[7], op[7]};
        end
    endfunction

    function automatic [7:0] gm3(input [7:0] op);
        begin
            gm3 = gm2(op) ^ op;
        end
    endfunction

    function automatic [31:0] mixw(input [31:0] w);
        reg [7:0] b0, b1, b2, b3;
        reg [7:0] mb0, mb1, mb2, mb3;
        begin
            b0 = w[31:24];
            b1 = w[23:16];
            b2 = w[15:8];
            b3 = w[7:0];

            mb0 = gm2(b0) ^ gm3(b1) ^ b2 ^ b3;
            mb1 = b0 ^ gm2(b1) ^ gm3(b2) ^ b3;
            mb2 = b0 ^ b1 ^ gm2(b2) ^ gm3(b3);
            mb3 = gm3(b0) ^ b1 ^ b2 ^ gm2(b3);

            mixw = {mb0, mb1, mb2, mb3};
        end
    endfunction

    function automatic [127:0] mixcolumns(input [127:0] data);
        reg [31:0] w0, w1, w2, w3;
        reg [31:0] ws0, ws1, ws2, ws3;
        begin
            w0 = data[127:96];
            w1 = data[95:64];
            w2 = data[63:32];
            w3 = data[31:0];

            ws0 = mixw(w0);
            ws1 = mixw(w1);
            ws2 = mixw(w2);
            ws3 = mixw(w3);

            mixcolumns = {ws0, ws1, ws2, ws3};
        end
    endfunction

    function automatic [127:0] shiftrows(input [127:0] data);
        reg [31:0] w0, w1, w2, w3;
        reg [31:0] ws0, ws1, ws2, ws3;
        begin
            w0 = data[127:96];
            w1 = data[95:64];
            w2 = data[63:32];
            w3 = data[31:0];

            ws0 = {w0[31:24], w1[23:16], w2[15:8], w3[7:0]};
            ws1 = {w1[31:24], w2[23:16], w3[15:8], w0[7:0]};
            ws2 = {w2[31:24], w3[23:16], w0[15:8], w1[7:0]};
            ws3 = {w3[31:24], w0[23:16], w1[15:8], w2[7:0]};

            shiftrows = {ws0, ws1, ws2, ws3};
        end
    endfunction

    function automatic [127:0] addroundkey(input [127:0] data, input [127:0] rkey);
        begin
            addroundkey = data ^ rkey;
        end
    endfunction

endmodule

