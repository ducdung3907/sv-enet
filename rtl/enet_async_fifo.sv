module enet_async_fifo #(
    parameter int WIDTH = 9,
    parameter int DEPTH = 16            // power of 2, >= 4
) (
    input  logic rst_n,    

    input  logic wclk,
    input  logic [WIDTH-1:0] s_axis_tdata,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,

    input  logic rclk,
    output logic [WIDTH-1:0] m_axis_tdata,
    output logic m_axis_tvalid,
    input  logic m_axis_tready
);

    localparam int ADDR_WIDTH = $clog2(DEPTH);
    localparam int PTR_WIDTH  = ADDR_WIDTH + 1;

    logic [WIDTH-1:0] mem [0:DEPTH-1];

    logic [PTR_WIDTH-1:0] wbin, wgray;
    logic [PTR_WIDTH-1:0] rbin, rgray;
    logic [PTR_WIDTH-1:0] wbin_next, wgray_next;
    logic [PTR_WIDTH-1:0] rbin_next, rgray_next;
    logic [PTR_WIDTH-1:0] rgray_wclk, wgray_rclk;
    logic wfull, wfull_next;
    logic rempty;
    logic write_fire, read_fire;

    function automatic logic [PTR_WIDTH-1:0] bin_to_gray(
        input logic [PTR_WIDTH-1:0] value
    );
        bin_to_gray = (value >> 1) ^ value;
    endfunction

    enet_synchronizer #(.WIDTH(PTR_WIDTH)) u_rptr_sync (
        .clk       (wclk),
        .rst_n     (rst_n),
        .async_in  (rgray),
        .sync_out  (rgray_wclk)
    );

    enet_synchronizer #(.WIDTH(PTR_WIDTH)) u_wptr_sync (
        .clk       (rclk),
        .rst_n     (rst_n),
        .async_in  (wgray),
        .sync_out  (wgray_rclk)
    );

    assign s_axis_tready = !wfull;
    assign write_fire = s_axis_tvalid && s_axis_tready;

    always_comb begin
        wbin_next  = wbin + write_fire;
        wgray_next = bin_to_gray(wbin_next);
        wfull_next = (wgray_next ==
                      {~rgray_wclk[PTR_WIDTH-1:PTR_WIDTH-2],
                        rgray_wclk[PTR_WIDTH-3:0]});
    end

    always_ff @(posedge wclk or negedge rst_n) begin
        if (!rst_n) begin
            wbin  <= '0;
            wgray <= '0;
            wfull <= 1'b0;
        end else begin
            wbin  <= wbin_next;
            wgray <= wgray_next;
            wfull <= wfull_next;
        end
    end

    always_ff @(posedge wclk) begin
        if (write_fire)
            mem[wbin[ADDR_WIDTH-1:0]] <= s_axis_tdata;
    end

    assign rempty = (rgray == wgray_rclk);
    assign read_fire = (!m_axis_tvalid || m_axis_tready) && !rempty;

    always_comb begin
        rbin_next  = rbin + read_fire;
        rgray_next = bin_to_gray(rbin_next);
    end

    always_ff @(posedge rclk or negedge rst_n) begin
        if (!rst_n) begin
            rbin          <= '0;
            rgray         <= '0;
            m_axis_tvalid <= 1'b0;
        end else begin
            rbin  <= rbin_next;
            rgray <= rgray_next;
            if (read_fire)
                m_axis_tvalid <= 1'b1;
            else if (m_axis_tvalid && m_axis_tready)
                m_axis_tvalid <= 1'b0;
        end
    end

    always_ff @(posedge rclk) begin
        if (read_fire)
            m_axis_tdata <= mem[rbin[ADDR_WIDTH-1:0]];
    end

endmodule

