module aes_key_mem (
    input clk,
    input reset_n,

    input [255:0] key,
    input keylen,
    input init,

    input [3:0] round,
    output reg [127:0] round_key,
    output reg ready,

    output [31:0] sboxw,
    input [31:0] new_sboxw
);

    localparam AES_128_BIT_KEY = 1'h0;
    localparam AES_256_BIT_KEY = 1'h1;

    localparam AES128_ROUNDS = 4'd10;
    localparam AES256_ROUNDS = 4'd14;

    localparam CTRL_IDLE = 4'b0001;
    localparam CTRL_INIT = 4'b0010;
    localparam CTRL_GENERATE = 4'b0100;
    localparam CTRL_DONE = 4'b1000;

    reg [3:0] state;

    (* ram_style = "distributed" *) reg [127:0] key_mem [0:14];
    reg [127:0] prev_key0_reg;
    reg [127:0] prev_key1_reg;
    reg [3:0] round_ctr_reg;
    reg [7:0] rcon_reg;

    wire [3:0] num_rounds = (keylen == AES_128_BIT_KEY) ? AES128_ROUNDS : AES256_ROUNDS;

    wire [31:0] w0 = prev_key0_reg[127:96];
    wire [31:0] w1 = prev_key0_reg[95:64];
    wire [31:0] w2 = prev_key0_reg[63:32];
    wire [31:0] w3 = prev_key0_reg[31:0];
    wire [31:0] w4 = prev_key1_reg[127:96];
    wire [31:0] w5 = prev_key1_reg[95:64];
    wire [31:0] w6 = prev_key1_reg[63:32];
    wire [31:0] w7 = prev_key1_reg[31:0];

    wire [31:0] rconw = {rcon_reg, 24'h0};
    wire [31:0] rotstw = {new_sboxw[23:0], new_sboxw[31:24]};
    wire [31:0] trw = rotstw ^ rconw;
    wire [31:0] tw = new_sboxw;

    wire [127:0] aes128_next_key = {
        w4 ^ trw,
        w5 ^ w4 ^ trw,
        w6 ^ w5 ^ w4 ^ trw,
        w7 ^ w6 ^ w5 ^ w4 ^ trw
    };

    wire [127:0] aes256_even_key = {
        w0 ^ trw,
        w1 ^ w0 ^ trw,
        w2 ^ w1 ^ w0 ^ trw,
        w3 ^ w2 ^ w1 ^ w0 ^ trw
    };

    wire [127:0] aes256_odd_key = {
        w0 ^ tw,
        w1 ^ w0 ^ tw,
        w2 ^ w1 ^ w0 ^ tw,
        w3 ^ w2 ^ w1 ^ w0 ^ tw
    };

    wire key_mem_we = state[2];
    wire [127:0] key_mem_wdata = (keylen == AES_128_BIT_KEY) ?((round_ctr_reg == 4'd0) ? key[255:128] : aes128_next_key) 
                                : (round_ctr_reg == 4'd0) ? key[255:128] 
                                : (round_ctr_reg == 4'd1) ? key[127:0] 
                                : (round_ctr_reg[0] == 1'b0) ? aes256_even_key 
                                : aes256_odd_key;

    assign sboxw = w7;

    always @(posedge clk) begin
        if (key_mem_we) begin
            key_mem[round_ctr_reg] <= key_mem_wdata;
        end

        round_key <= key_mem[round];
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            prev_key0_reg <= 128'h0;
            prev_key1_reg <= 128'h0;
            round_ctr_reg <= 4'h0;
            state <= CTRL_IDLE;
            ready <= 1'b1;
            rcon_reg <= 8'h0;
        end else begin
            case (state)
                CTRL_IDLE: begin
                    if (init) begin
                        round_ctr_reg <= 4'h0;
                        ready <= 1'b0;
                        rcon_reg <= 8'h8d;
                        state <= CTRL_INIT;
                    end
                end

                CTRL_INIT: begin
                    round_ctr_reg <= 4'h0;
                    state <= CTRL_GENERATE;
                end

                CTRL_GENERATE: begin
                    if (keylen == AES_128_BIT_KEY) begin
                        if (round_ctr_reg == 4'd0) begin
                            prev_key1_reg <= key[255:128];
                        end else begin
                            prev_key1_reg <= aes128_next_key;
                        end
                        rcon_reg <= next_rcon(rcon_reg);
                    end else begin
                        if (round_ctr_reg == 4'd0) begin
                            prev_key0_reg <= key[255:128];
                        end else if (round_ctr_reg == 4'd1) begin
                            prev_key1_reg <= key[127:0];
                            rcon_reg <= next_rcon(rcon_reg);
                        end else begin
                            prev_key0_reg <= prev_key1_reg;
                            if (round_ctr_reg[0] == 1'b0) begin
                                prev_key1_reg <= aes256_even_key;
                            end else begin
                                prev_key1_reg <= aes256_odd_key;
                                rcon_reg <= next_rcon(rcon_reg);
                            end
                        end
                    end

                    round_ctr_reg <= round_ctr_reg + 1'b1;
                    if (round_ctr_reg == num_rounds) begin
                        state <= CTRL_DONE;
                    end
                end

                CTRL_DONE: begin
                    ready <= 1'b1;
                    state <= CTRL_IDLE;
                end

                default: begin
                    ready <= 1'b1;
                    state <= CTRL_IDLE;
                end
            endcase
        end
    end

    function [7:0] next_rcon;
        input [7:0] rcon;
        begin
            next_rcon = {rcon[6:4], rcon[3] ^ rcon[7], rcon[2] ^ rcon[7], rcon[1], rcon[0] ^ rcon[7], rcon[7]};
        end
    endfunction

endmodule
