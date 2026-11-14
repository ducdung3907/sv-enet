module enet_rx_fifo #(
    parameter int DEPTH = 4096
)(
    input logic rst_n,

    input logic wclk,
    input logic [7:0] s_axis_tdata,
    input logic s_axis_tvalid,
    input logic s_axis_tlast,
    input logic s_axis_tuser,       // with tlast: 1 = discard this frame
    output logic stat_overflow,     // wclk pulse: a frame was discarded because the FIFO was full

    input logic rclk,
    output logic [7:0] m_axis_tdata,
    output logic m_axis_tvalid,
    output logic m_axis_tlast,
    input logic m_axis_tready
);
    localparam int PTR_W = $clog2(DEPTH) + 1;

    logic [7:0] mem [DEPTH-1:0];

    logic [PTR_W-1:0] wptr_bin, wptr_gray;
    logic [PTR_W-1:0] rptr_bin, rptr_gray;

    logic [PTR_W-1:0] wptr_bin_next, wptr_gray_next;
    logic [PTR_W-1:0] rptr_bin_next, rptr_gray_next;

    logic [PTR_W-1:0] rgray_wsync;
    logic [PTR_W-1:0] wgray_rsync;

    logic full_next;
    logic empty_next;

    initial begin
        if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0) begin
            $fatal(1, "DEPTH must be a power of two and >= 4");
        end
    end

    localparam int ADDR_W = PTR_W - 1;

    logic       last_mem [DEPTH-1:0];
    logic       full_w, empty_r;

    always_comb begin
        wptr_bin_next = wptr_bin + 1'b1;
        rptr_bin_next = rptr_bin + 1'b1;

        wptr_gray_next = wptr_bin_next ^ (wptr_bin_next >> 1);
        rptr_gray_next = rptr_bin_next ^ (rptr_bin_next >> 1);

        full_w = (wptr_gray == (rgray_wsync ^ {1'b1, {PTR_W-2{1'b0}}}));
        empty_r = (wgray_rsync == rptr_gray);

        full_next = (wptr_gray_next == (rgray_wsync ^ {1'b1, {PTR_W-2{1'b0}}}));
        empty_next = (wptr_gray_next == wgray_rsync);
    end

    always_ff @(posedge wclk or negedge rst_n) begin
        if (!rst_n) begin
            wptr_bin <= '0;
            wptr_gray <= '0;
            rgray_wsync <= '0;
            stat_overflow <= 1'b0;
        end else begin
            rgray_wsync <= rptr_gray;
            stat_overflow <= 1'b0;

            if (s_axis_tvalid) begin
                if (full_w) begin
                    if (s_axis_tlast && s_axis_tuser) begin
                        stat_overflow <= 1'b1;
                    end
                end else begin
                    if (!(s_axis_tlast && s_axis_tuser)) begin
                        mem[wptr_bin[ADDR_W-1:0]] <= s_axis_tdata;
                        last_mem[wptr_bin[ADDR_W-1:0]] <= s_axis_tlast;
                        wptr_bin <= wptr_bin_next;
                        wptr_gray <= wptr_gray_next;
                    end
                end
            end
        end
    end

    always_ff @(posedge rclk or negedge rst_n) begin
        if (!rst_n) begin
            rptr_bin <= '0;
            rptr_gray <= '0;
            wgray_rsync <= '0;
            m_axis_tdata <= '0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast <= 1'b0;
        end else begin
            wgray_rsync <= wptr_gray;

            if (empty_r) begin
                m_axis_tdata <= '0;
                m_axis_tvalid <= 1'b0;
                m_axis_tlast <= 1'b0;
            end else begin
                m_axis_tdata <= mem[rptr_bin[ADDR_W-1:0]];
                m_axis_tlast <= last_mem[rptr_bin[ADDR_W-1:0]];
                m_axis_tvalid <= 1'b1;

                if (m_axis_tready) begin
                    rptr_bin <= rptr_bin_next;
                    rptr_gray <= rptr_gray_next;
                end
            end
        end
    end

endmodule