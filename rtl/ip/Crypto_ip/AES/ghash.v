module ghash (
    input clk,
    input reset_n,

    input init,
    input next,
    input [127:0] hash_subkey,
    input [127:0] block,

    output reg [127:0] digest,
    output reg ready
);

    localparam CTRL_IDLE = 1'b0;
    localparam CTRL_MULTIPLY = 1'b1;

    localparam [127:0] REDUCTION_POLY = 128'he1000000000000000000000000000000;

    reg state;
    reg [4:0] step_ctr_reg;
    reg [127:0] x_reg;
    reg [127:0] z_reg;
    reg [127:0] v_reg;

    reg [127:0] x_next;
    reg [127:0] z_next;
    reg [127:0] v_next;
    reg [127:0] x_work;
    reg [127:0] z_work;
    reg [127:0] v_work;
    integer i;

    always @(*) begin
        x_work = x_reg;
        z_work = z_reg;
        v_work = v_reg;

        for (i = 0; i < 4; i = i + 1) begin
            if (x_work[127]) begin
                z_work = z_work ^ v_work;
            end

            x_work = {x_work[126:0], 1'b0};
            if (v_work[0]) begin
                v_work = {1'b0, v_work[127:1]} ^ REDUCTION_POLY;
            end else begin
                v_work = {1'b0, v_work[127:1]};
            end
        end

        x_next = x_work;
        z_next = z_work;
        v_next = v_work;
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            state <= CTRL_IDLE;
            step_ctr_reg <= 5'h0;
            x_reg <= 128'h0;
            z_reg <= 128'h0;
            v_reg <= 128'h0;
            digest <= 128'h0;
            ready <= 1'b1;
        end else begin
            case (state)
                CTRL_IDLE: begin
                    if (init) begin
                        digest <= 128'h0;
                    end else if (next) begin
                        step_ctr_reg <= 5'h0;
                        x_reg <= digest ^ block;
                        z_reg <= 128'h0;
                        v_reg <= hash_subkey;
                        ready <= 1'b0;
                        state <= CTRL_MULTIPLY;
                    end
                end

                CTRL_MULTIPLY: begin
                    x_reg <= x_next;
                    z_reg <= z_next;
                    v_reg <= v_next;
                    step_ctr_reg <= step_ctr_reg + 1'b1;

                    if (step_ctr_reg == 5'd31) begin
                        digest <= z_next;
                        ready <= 1'b1;
                        state <= CTRL_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
