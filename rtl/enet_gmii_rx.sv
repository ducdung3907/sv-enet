module enet_gmii_rx (
    input  logic       rx_clk,          
    input  logic [7:0] gmii_rxd,          
    input  logic       gmii_rx_dv,
    input  logic       gmii_rx_er,
    output logic [7:0] rxd,              
    output logic       rx_dv,
    output logic       rx_er
);
    always_ff @(posedge rx_clk) begin
        rxd <= gmii_rxd;
        rx_dv <= gmii_rx_dv;
        rx_er <= gmii_rx_er;
    end
endmodule