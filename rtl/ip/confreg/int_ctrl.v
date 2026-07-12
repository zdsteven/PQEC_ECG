module int_ctrl #(
    parameter N = 6
) (
    input sys_clk,
    input sys_resetn,
    input cpu_clk,
    input cpu_resetn,

    input [N-1:0] int_in,
    input [N-1:0] int_en,
    input [N-1:0] int_edge,
    input [N-1:0] int_pol,
    input [N-1:0] int_clr,
    output [N-1:0] int_state,
    output int_out
);
    reg [3:0] int_edge_new;
    reg [3:0] int_pol_new;
    reg [3:0] int_in_prev;


    reg [N-1:0] int_state_reg;  //中断状态寄存器

    genvar l;
    generate
        for (l = 0; l < 4; l = l + 1) begin : bottons
            always @(posedge sys_clk or negedge sys_resetn) begin
                if (!sys_resetn) begin
                    int_in_prev[l] <= 1'b0;
                end else begin
                    int_in_prev[l] <= int_in[l];
                end
            end
            always @(posedge sys_clk or negedge sys_resetn) begin
                if (!sys_resetn) begin
                    int_edge_new[l] <= 1'b0;
                    int_pol_new[l]  <= 1'b0;
                end else if (int_in[l] & !int_in_prev[l]) begin
                    int_edge_new[l] <= 1'b1;
                    int_pol_new[l]  <= 1'b1;
                end else begin
                    int_edge_new[l] <= 1'b0;
                    int_pol_new[l]  <= 1'b0;
                end
            end
        end
    endgenerate



    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_int_ctrl
            always @(posedge sys_clk or negedge sys_resetn) begin
                if (!sys_resetn) begin
                    // 复位状态
                    int_state_reg[i] <= 1'b0;
                end else begin
                    if (int_edge_new[i]) begin
                        // 正边沿触发
                        if (int_pol_new[i]) begin
                            int_state_reg[i] <= 1'b1;
                        end
                    end else begin
                        if (int_clr[i]) begin
                            int_state_reg[i] <= 1'b0;
                        end
                    end
                end
            end
        end
    endgenerate

    always @(posedge sys_clk or negedge sys_resetn) begin
        if (!sys_resetn) begin
            int_state_reg[4] <= 1'b0;
        end else begin
            int_state_reg[4] <= int_in[4];
        end
    end

    // UART is level-sensitive and clears when software drains the RX FIFO.
    always @(posedge sys_clk or negedge sys_resetn) begin
        if (!sys_resetn) begin
            int_state_reg[5] <= 1'b0;
        end else begin
            int_state_reg[5] <= int_in[5];
        end
    end
    assign int_state = (int_state_reg & int_en);

    reg int_valid;
    always @(posedge sys_clk or negedge sys_resetn) begin
        if (~sys_resetn) begin
            int_valid <= 1'b0;
        end else begin
            int_valid <= |int_state;  // 任一中断有效则输出高电平
        end
    end
    reg [1:0] int_valid_r;
    always @(posedge cpu_clk or negedge cpu_resetn) begin
        if (~cpu_resetn) begin
            int_valid_r <= 2'b0;
        end else begin
            int_valid_r <= {int_valid_r[0], int_valid};
        end
    end
    assign int_out = int_valid_r[1];

endmodule
