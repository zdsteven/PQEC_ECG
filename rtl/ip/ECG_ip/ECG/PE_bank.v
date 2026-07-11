module PE_bank (
    input aclk,
    input aresetn,
    input signed [8:0] data,
    input [31:0] weight,
    input first,
    output signed [18:0] result_0,
    output signed [18:0] result_1,
    output signed [18:0] result_2,
    output signed [18:0] result_3
);

    PE u_PE_0 (
        .aclk(aclk),
        .aresetn(aresetn),
        .data(data),
        .weight(weight[7:0]),
        .first(first),
        .result(result_0)
    );

    PE u_PE_1 (
        .aclk(aclk),
        .aresetn(aresetn),
        .data(data),
        .weight(weight[15:8]),
        .first(first),
        .result(result_1)
    );
    
    PE u_PE_2 (
        .aclk(aclk),
        .aresetn(aresetn),
        .data(data),
        .weight(weight[23:16]),
        .first(first),
        .result(result_2)
    );

    PE u_PE_3 (
        .aclk(aclk),
        .aresetn(aresetn),
        .data(data),
        .weight(weight[31:24]),
        .first(first),
        .result(result_3)
    );
endmodule
