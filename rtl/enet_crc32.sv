module enet_crc32 (
    input  logic        clk,
    input  logic        rst_n,   
    input  logic        init,  
    input  logic        valid,  
    input  logic [7:0]  data,
    output logic [31:0] crc     
);
    localparam logic [31:0] DEFAULT = 32'hFFFFFFFF;
    localparam logic [31:0] KEY = 32'hEDB88320;
    
    function automatic logic [31:0] stir (
        input logic [7:0] din,
        input logic [31:0] cache
    );
        logic r;
        for (int i = 0; i< 8;i++) begin
            r = cache[0] ^ din[i];
            cache = cache >> 1;
            if (r) begin 
                cache = cache ^ KEY;
            end
        end
        return cache;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc <= DEFAULT;
        end else if (init) begin
            crc <= valid ? stir(data,DEFAULT) : DEFAULT; 
        end else if (valid) begin
            crc <= stir(data,crc);
        end
    end
endmodule