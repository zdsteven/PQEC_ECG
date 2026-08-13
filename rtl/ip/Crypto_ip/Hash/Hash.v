module Hash (
    input aclk,
    input aresetn,

    input reset_data,
    input absorb,
    input [5:0] absorb_address,
    input [31:0] absorb_data,

    input iterate,

    input [1:0] mode, // 00:normal 01:rej 10:cbd(eta = 2) 11:cbd(eta = 3)

    input squeeze,
    input [5:0] squeeze_address,
    output reg [31:0] squeeze_data,

    input sample,
    input [6:0] sample_out_address,
    output reg [31:0] sample_data,

    output reg done
);
    `define ROL64(a, offset) (((a) << (offset)) | ((a) >> (64 - (offset))))

    integer i;

//-------------------------------{CTRL}begin----------------------------------//
    localparam  IDLE = 6'b000001,
                ITERATION = 6'b000010,
                REJECTION = 6'b000100,
                CBD = 6'b001000,
                SAMPLE = 6'b010000,
                DONE = 6'b100000;

    reg [5:0] current_state;
    reg [5:0] next_state;

    reg iteration_state;
    reg [4:0] iteration_count;

//-------------------------------{CTRL}end------------------------------------//


//-------------------------------{iteration}begin-----------------------------//
    reg [63:0] S [0:24];

    reg [63:0] middle_xor [0:4];
    wire [63:0] middle_iteration [0:4];
    wire [63:0] iteration_shift [0:24];
    wire [63:0] iteration_result_0_middle;
    wire [63:0] iteration_result [0:24];


    wire [6:0] SRC_rom [0:23];

    assign SRC_rom[0]  = 7'b0000001;
    assign SRC_rom[1]  = 7'b0011010;
    assign SRC_rom[2]  = 7'b1011110;
    assign SRC_rom[3]  = 7'b1110000;
    assign SRC_rom[4]  = 7'b0011111;
    assign SRC_rom[5]  = 7'b0100001;
    assign SRC_rom[6]  = 7'b1111001;
    assign SRC_rom[7]  = 7'b1010101;
    assign SRC_rom[8]  = 7'b0001110;
    assign SRC_rom[9]  = 7'b0001100;
    assign SRC_rom[10] = 7'b0110101;
    assign SRC_rom[11] = 7'b0100110;
    assign SRC_rom[12] = 7'b0111111;
    assign SRC_rom[13] = 7'b1001111;
    assign SRC_rom[14] = 7'b1011101;
    assign SRC_rom[15] = 7'b1010011;
    assign SRC_rom[16] = 7'b1010010;
    assign SRC_rom[17] = 7'b1001000;
    assign SRC_rom[18] = 7'b0010110;
    assign SRC_rom[19] = 7'b1100110;
    assign SRC_rom[20] = 7'b1111001;
    assign SRC_rom[21] = 7'b1011000;
    assign SRC_rom[22] = 7'b0100001;
    assign SRC_rom[23] = 7'b1110100;

//-------------------------------{iteration}end-------------------------------//

//-------------------------------{Sample}begin--------------------------------//

    reg [11:0] sample_result_0 [0:127];
    reg [11:0] sample_result_1 [0:127];

    reg [6:0] sample_address_0;
    reg [6:0] sample_address_1;

    reg [11:0] sample_result_0_data;
    wire sample_result_0_we;
    reg [11:0] sample_result_1_data;
    wire sample_result_1_we;

    reg [4:0] sample_nblock;
    reg [79:0] sample_buffer;
    reg [6:0] sample_buffer_left;
    reg [6:0] cbd_count;
    reg [6:0] rejection_count_0;
    reg [6:0] rejection_count_1;

    wire [23:0] cbd_2;
    wire [23:0] cbd_3;

    reg cbd_we;
    wire rejection_we_0;
    wire rejection_we_1;
    reg rejection_we_0_reg;
    reg rejection_we_1_reg;
    reg state_we;

    reg rejection_orientation; // 0:normal 1: reverse
//-------------------------------{Sample}end----------------------------------//


//--------------------------------------------------------------------------------------------------------//
//--------------------------------------------------------------------------------------------------------//
//--------------------------------------------------------------------------------------------------------//


//-------------------------------{CTRL}begin----------------------------------//
    always @(posedge aclk) begin
        if (!aresetn) begin
            current_state <= IDLE;
        end
        else begin
            current_state <= next_state;
        end
    end

    always @(*) begin
        case (current_state)
            IDLE: begin
                if (iterate) begin
                    next_state = ITERATION;
                end
                else begin
                    next_state = IDLE;
                end
            end
            ITERATION: begin
                if (iteration_state & iteration_count == 5'd23) begin
                    case (mode) 
                        2'b00: next_state = DONE;
                        2'b01: next_state = REJECTION;
                        2'b10: next_state = CBD;
                        2'b11: next_state = CBD;
                    endcase
                end
                else begin
                    next_state = ITERATION;
                end
            end
            REJECTION: begin
                if (sample_nblock == 5'd21) begin
                    next_state = ITERATION;
                end
                else begin
                    next_state = SAMPLE;
                end
            end
            CBD: begin
                if (sample_nblock == 5'd17) begin
                    next_state = ITERATION;
                end
                else begin
                    next_state = SAMPLE;
                end
            end
            SAMPLE: begin
                case (mode[1])
                    1'b0: begin
                        if ((~rejection_count_0[6] & rejection_count_1[6] & (rejection_we_0 | rejection_we_1)) | ((rejection_count_1 == 7'd127) & (rejection_we_0 & rejection_we_1))) begin
                            next_state = DONE;
                        end
                        else if (sample_buffer_left < 7'd48) begin
                            next_state = REJECTION;
                        end
                        else begin
                            next_state = SAMPLE;
                        end
                    end
                    1'b1: begin
                        if (cbd_count == 7'd127) begin
                            next_state = DONE;
                        end
                        else if (mode[0]) begin
                            if (sample_buffer_left < 7'd24) begin
                                next_state = CBD;
                            end
                            else begin
                                next_state = SAMPLE;
                            end
                        end
                        else begin
                            if (sample_buffer_left < 7'd16) begin
                                next_state = CBD;
                            end
                            else begin
                                next_state = SAMPLE;
                            end
                        end
                    end
                endcase
            end
            DONE: begin 
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            iteration_state <= 1'b0;
            iteration_count <= 5'd0;
            done <= 1'b0;
            sample_nblock <= 5'd0;
            sample_buffer_left <= 7'd0;
            cbd_count <= 7'd0;
            rejection_count_0 <= 7'd0;
            rejection_count_1 <= 7'd0;
            cbd_we <= 1'b0;
            rejection_we_0_reg <= 1'b0;
            rejection_we_1_reg <= 1'b0;
            rejection_orientation <= 1'b0;
        end
        else begin
            case (current_state)
                IDLE: begin
                    done <= 1'b0;
                    sample_nblock <= 5'd0;
                    sample_buffer_left <= 7'd0;
                    cbd_count <= 7'd0;
                    rejection_count_0 <= 7'd0;
                    rejection_count_1 <= 7'd0;
                    rejection_orientation <= 1'b0;
                end
                ITERATION: begin
                    case (iteration_state)
                        1'b0: begin
                            iteration_state <= 1'b1;
                        end
                        1'b1: begin
                            iteration_state <= 1'b0;
                            if (iteration_count == 5'd23) begin
                                iteration_count <= 5'd0;
                            end
                            else begin
                                iteration_count <= iteration_count + 1;
                            end
                        end
                    endcase
                end
                REJECTION: begin
                    if (sample_nblock == 5'd21) begin
                        sample_nblock <= 5'd0;
                    end
                    else begin
                        sample_nblock <= sample_nblock + 1;
                        if (sample_buffer_left[3]) begin
                            sample_buffer[71:8] <= S[sample_nblock];
                        end
                        else if (sample_buffer_left[4]) begin
                            sample_buffer[79:16] <= S[sample_nblock];
                        end
                        else begin
                            sample_buffer[63:0] <= S[sample_nblock];
                        end
                        sample_buffer_left <= sample_buffer_left + 7'd64;
                    end
                end
                CBD: begin
                    if (sample_nblock == 5'd17) begin
                        sample_nblock <= 5'd0;
                    end
                    else begin
                        sample_nblock <= sample_nblock + 1;
                        if (sample_buffer_left[3]) begin
                            sample_buffer[71:8] <= S[sample_nblock];
                        end
                        else if (sample_buffer_left[2]) begin
                            sample_buffer[67:4] <= S[sample_nblock];
                        end
                        else begin
                            sample_buffer[63:0] <= S[sample_nblock];
                        end
                        sample_buffer_left <= sample_buffer_left + 7'd64;
                    end
                end
                SAMPLE: begin
                    if (mode[1]) begin
                        cbd_count <= cbd_count + 7'd1;
                        cbd_we <= 1'b1;
                        if (mode[0]) begin
                            sample_buffer_left <= sample_buffer_left - 7'd12;
                            sample_buffer[67:0] <= sample_buffer[79:12];
                            sample_result_0_data <= cbd_3[11:0];
                            sample_result_1_data <= cbd_3[23:12];
                        end
                        else begin
                            sample_buffer_left <= sample_buffer_left - 7'd8;
                            sample_buffer[71:0] <= sample_buffer[79:8];
                            sample_result_0_data <= cbd_2[11:0];
                            sample_result_1_data <= cbd_2[23:12];
                        end
                    end
                    else begin
                        sample_buffer[55:0] <= sample_buffer[79:24];
                        sample_buffer_left <= sample_buffer_left - 7'd24;
                        case ({rejection_we_1,rejection_we_0})
                            2'b00: begin
                                rejection_we_0_reg <= 1'b0;
                                rejection_we_1_reg <= 1'b0;
                                sample_result_0_data <= sample_buffer[11:0];
                                sample_result_1_data <= sample_buffer[23:12];
                            end
                            2'b01: begin
                                rejection_orientation <= ~rejection_orientation;
                                if (rejection_orientation) begin
                                    rejection_we_0_reg <= 1'b0;
                                    rejection_we_1_reg <= 1'b1;
                                    sample_result_0_data <= sample_buffer[23:12];
                                    sample_result_1_data <= sample_buffer[11:0];
                                    rejection_count_1 <= rejection_count_1 + 7'd1;
                                end
                                else begin
                                    rejection_we_0_reg <= 1'b1;
                                    rejection_we_1_reg <= 1'b0;
                                    sample_result_0_data <= sample_buffer[11:0];
                                    sample_result_1_data <= sample_buffer[23:12];
                                    rejection_count_0 <= rejection_count_0 + 7'd1;
                                end
                            end
                            2'b10: begin
                                rejection_orientation <= ~rejection_orientation;
                                if (rejection_orientation) begin
                                    rejection_we_0_reg <= 1'b0;
                                    rejection_we_1_reg <= 1'b1;
                                    sample_result_0_data <= sample_buffer[11:0];
                                    sample_result_1_data <= sample_buffer[23:12];
                                    rejection_count_1 <= rejection_count_1 + 7'd1;
                                end
                                else begin
                                    rejection_we_0_reg <= 1'b1;
                                    rejection_we_1_reg <= 1'b0;
                                    sample_result_0_data <= sample_buffer[23:12];
                                    sample_result_1_data <= sample_buffer[11:0];
                                    rejection_count_0 <= rejection_count_0 + 7'd1;
                                end
                            end
                            2'b11: begin
                                rejection_we_1_reg <= 1'b1;
                                rejection_count_0 <= rejection_count_0 + 7'd1;
                                rejection_count_1 <= rejection_count_1 + 7'd1;
                                if (rejection_orientation) begin
                                    rejection_we_0_reg <= (rejection_count_1 != 7'd127);
                                    sample_result_0_data <= sample_buffer[23:12];
                                    sample_result_1_data <= sample_buffer[11:0];
                                end
                                else begin
                                    rejection_we_0_reg <= 1'b1;
                                    sample_result_0_data <= sample_buffer[11:0];
                                    sample_result_1_data <= sample_buffer[23:12];
                                end
                            end
                        endcase
                    end
                end
                DONE: begin
                    cbd_we <= 1'b0;
                    rejection_we_0_reg <= 1'b0;
                    rejection_we_1_reg <= 1'b0;
                    done <= 1'b1;
                end 
                default: ;
            endcase
        end
    end

    always @(posedge aclk) begin
        if (squeeze) begin
            if (squeeze_address[0]) begin
                squeeze_data <= S[squeeze_address[5:1]][63:32];
            end
            else begin
                squeeze_data <= S[squeeze_address[5:1]][31:0];
            end
        end
    end
//-------------------------------{CTRL}end------------------------------------//


//-------------------------------{iteration}begin-----------------------------//
    assign middle_iteration[0] = middle_xor[4] ^ `ROL64(middle_xor[1],1);
    assign middle_iteration[1] = middle_xor[0] ^ `ROL64(middle_xor[2],1);
    assign middle_iteration[2] = middle_xor[1] ^ `ROL64(middle_xor[3],1);
    assign middle_iteration[3] = middle_xor[2] ^ `ROL64(middle_xor[4],1);
    assign middle_iteration[4] = middle_xor[3] ^ `ROL64(middle_xor[0],1);


    assign iteration_shift[0] = S[0] ^ middle_iteration[0];
    assign iteration_shift[1] = `ROL64(S[1] ^ middle_iteration[1], 1);
    assign iteration_shift[2] = `ROL64(S[2] ^ middle_iteration[2], 62);
    assign iteration_shift[3] = `ROL64(S[3] ^ middle_iteration[3], 28);
    assign iteration_shift[4] = `ROL64(S[4] ^ middle_iteration[4], 27);
    assign iteration_shift[5] = `ROL64(S[5] ^ middle_iteration[0], 36);
    assign iteration_shift[6] = `ROL64(S[6] ^ middle_iteration[1], 44);
    assign iteration_shift[7] = `ROL64(S[7] ^ middle_iteration[2], 6);
    assign iteration_shift[8] = `ROL64(S[8] ^ middle_iteration[3], 55);
    assign iteration_shift[9] = `ROL64(S[9] ^ middle_iteration[4], 20);
    assign iteration_shift[10] = `ROL64(S[10] ^ middle_iteration[0], 3);
    assign iteration_shift[11] = `ROL64(S[11] ^ middle_iteration[1], 10);
    assign iteration_shift[12] = `ROL64(S[12] ^ middle_iteration[2], 43);
    assign iteration_shift[13] = `ROL64(S[13] ^ middle_iteration[3], 25);
    assign iteration_shift[14] = `ROL64(S[14] ^ middle_iteration[4], 39);
    assign iteration_shift[15] = `ROL64(S[15] ^ middle_iteration[0], 41);
    assign iteration_shift[16] = `ROL64(S[16] ^ middle_iteration[1], 45);
    assign iteration_shift[17] = `ROL64(S[17] ^ middle_iteration[2], 15);
    assign iteration_shift[18] = `ROL64(S[18] ^ middle_iteration[3], 21);
    assign iteration_shift[19] = `ROL64(S[19] ^ middle_iteration[4], 8);
    assign iteration_shift[20] = `ROL64(S[20] ^ middle_iteration[0], 18);
    assign iteration_shift[21] = `ROL64(S[21] ^ middle_iteration[1], 2);
    assign iteration_shift[22] = `ROL64(S[22] ^ middle_iteration[2], 61);
    assign iteration_shift[23] = `ROL64(S[23] ^ middle_iteration[3], 56);
    assign iteration_shift[24] = `ROL64(S[24] ^ middle_iteration[4], 14);

    assign iteration_result_0_middle = iteration_shift[0] ^ (~iteration_shift[6] & iteration_shift[12]);
    assign iteration_result[0] = {  iteration_result_0_middle[63] ^ SRC_rom[iteration_count][6],
                                    iteration_result_0_middle[62:32],
                                    iteration_result_0_middle[31] ^ SRC_rom[iteration_count][5],
                                    iteration_result_0_middle[30:16],
                                    iteration_result_0_middle[15] ^ SRC_rom[iteration_count][4],
                                    iteration_result_0_middle[14:8],
                                    iteration_result_0_middle[7] ^ SRC_rom[iteration_count][3],
                                    iteration_result_0_middle[6:4],
                                    iteration_result_0_middle[3] ^ SRC_rom[iteration_count][2],
                                    iteration_result_0_middle[2],
                                    iteration_result_0_middle[1] ^ SRC_rom[iteration_count][1], 
                                    iteration_result_0_middle[0] ^ SRC_rom[iteration_count][0]
                                };
    assign iteration_result[1] = iteration_shift[6] ^ (~iteration_shift[12] & iteration_shift[18]);
    assign iteration_result[2] = iteration_shift[12] ^ (~iteration_shift[18] & iteration_shift[24]);
    assign iteration_result[3] = iteration_shift[18] ^ (~iteration_shift[24] & iteration_shift[0]);
    assign iteration_result[4] = iteration_shift[24] ^ (~iteration_shift[0] & iteration_shift[6]);
    assign iteration_result[5] = iteration_shift[3] ^ (~iteration_shift[9] & iteration_shift[10]);
    assign iteration_result[6] = iteration_shift[9] ^ (~iteration_shift[10] & iteration_shift[16]);
    assign iteration_result[7] = iteration_shift[10] ^ (~iteration_shift[16] & iteration_shift[22]);
    assign iteration_result[8] = iteration_shift[16] ^ (~iteration_shift[22] & iteration_shift[3]);
    assign iteration_result[9] = iteration_shift[22] ^ (~iteration_shift[3] & iteration_shift[9]);
    assign iteration_result[10] = iteration_shift[1] ^ (~iteration_shift[7] & iteration_shift[13]);
    assign iteration_result[11] = iteration_shift[7] ^ (~iteration_shift[13] & iteration_shift[19]);
    assign iteration_result[12] = iteration_shift[13] ^ (~iteration_shift[19] & iteration_shift[20]);
    assign iteration_result[13] = iteration_shift[19] ^ (~iteration_shift[20] & iteration_shift[1]);
    assign iteration_result[14] = iteration_shift[20] ^ (~iteration_shift[1] & iteration_shift[7]);
    assign iteration_result[15] = iteration_shift[4] ^ (~iteration_shift[5] & iteration_shift[11]);
    assign iteration_result[16] = iteration_shift[5] ^ (~iteration_shift[11] & iteration_shift[17]);
    assign iteration_result[17] = iteration_shift[11] ^ (~iteration_shift[17] & iteration_shift[23]);
    assign iteration_result[18] = iteration_shift[17] ^ (~iteration_shift[23] & iteration_shift[4]);
    assign iteration_result[19] = iteration_shift[23] ^ (~iteration_shift[4] & iteration_shift[5]);
    assign iteration_result[20] = iteration_shift[2] ^ (~iteration_shift[8] & iteration_shift[14]);
    assign iteration_result[21] = iteration_shift[8] ^ (~iteration_shift[14] & iteration_shift[15]);
    assign iteration_result[22] = iteration_shift[14] ^ (~iteration_shift[15] & iteration_shift[21]);
    assign iteration_result[23] = iteration_shift[15] ^ (~iteration_shift[21] & iteration_shift[2]);
    assign iteration_result[24] = iteration_shift[21] ^ (~iteration_shift[2] & iteration_shift[8]);


    always @(posedge aclk) begin
        if (current_state[1] & !iteration_state) begin
            middle_xor[0] <= S[0] ^ S[5] ^ S[10] ^ S[15] ^ S[20];
            middle_xor[1] <= S[1] ^ S[6] ^ S[11] ^ S[16] ^ S[21];
            middle_xor[2] <= S[2] ^ S[7] ^ S[12] ^ S[17] ^ S[22];
            middle_xor[3] <= S[3] ^ S[8] ^ S[13] ^ S[18] ^ S[23];
            middle_xor[4] <= S[4] ^ S[9] ^ S[14] ^ S[19] ^ S[24];
        end
    end


    always @(posedge aclk) begin
        if (reset_data) begin
            for (i = 0; i < 25; i = i + 1) begin
                S[i] <= 64'h0;
            end
        end
        else if (absorb) begin
            if (absorb_address[0]) begin
                S[absorb_address[5:1]][63:32] <= S[absorb_address[5:1]][63:32] ^ absorb_data;
            end
            else begin
                S[absorb_address[5:1]][31:0] <= S[absorb_address[5:1]][31:0] ^ absorb_data;
            end
        end
        else if (iteration_state) begin
            for (i = 0; i < 25; i = i + 1) begin
                S[i] <= iteration_result[i];
            end
        end
    end
//-------------------------------{iteration}end-------------------------------//

//-------------------------------{Sample}begin--------------------------------//
    assign rejection_we_0 = sample_buffer[11:0] < 12'd3329;
    assign rejection_we_1 = sample_buffer[23:12] < 12'd3329;

    assign sample_result_0_we = state_we & (cbd_we | rejection_we_0_reg);
    assign sample_result_1_we = state_we & (cbd_we | rejection_we_1_reg);

    always @(posedge aclk) begin
        if (!aresetn) begin
            state_we <= 1'b0;
        end
        else begin
            state_we <= current_state[4];
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            sample_address_0 <= 7'd0;
            sample_address_1 <= 7'd0;
        end
        else begin
            if (current_state[4]) begin
                if (mode[1]) begin
                    sample_address_0 <= cbd_count;
                    sample_address_1 <= cbd_count;
                end
                else begin
                    sample_address_0 <= rejection_count_0;
                    sample_address_1 <= rejection_count_1;
                end
            end
        end
    end


    always @(posedge aclk) begin
        if (sample_result_0_we) begin
            sample_result_0[sample_address_0] <= sample_result_0_data;
        end
        if (sample_result_1_we) begin
            sample_result_1[sample_address_1] <= sample_result_1_data;
        end
    end

    always @(posedge aclk) begin
        if (sample) begin
            sample_data <= { 4'b0, sample_result_1[sample_out_address], 4'b0, sample_result_0[sample_out_address] };
        end
    end

//-------------------------------{Sample}end----------------------------------//

CBD_2 u_CBD_2(
    .in  (sample_buffer[7:0]  ),
    .out (cbd_2 )
);

CBD_3 u_CBD_3(
    .in  (sample_buffer[11:0]  ),
    .out (cbd_3 )
);


endmodule
