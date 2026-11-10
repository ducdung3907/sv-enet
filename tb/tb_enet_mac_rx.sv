`timescale 1ns/1ps

// Self-checking testbench for enet_gmii_rx -> enet_mac_rx (the board's RX path).
//
// Vectors come from tb/gen_mac_rx_vectors.py (reference: Python zlib.crc32):
//   mac_rx_in.hex    the GMII pins, one line per clock: {rx_er, rx_dv, rxd}
//   mac_rx_exp.hex   every byte enet_mac_rx must output, in order: {tlast, tuser, tdata}
//   mac_rx_meta.hex  number of cycles, number of output beats, expected stat pulse counts
//
// Checked:
//   1. every output beat (tvalid) against the expected list: data, tlast, and
//      tuser on the tlast beat
//   2. tlast / tuser never high without tvalid; tuser never high without tlast
//   3. no extra or missing beats
//   4. number of pulses on stat_good, stat_crc_err, stat_runt, stat_too_long,
//      stat_rx_er; stat_good never in the same cycle as an error pulse
//
// Scenarios covered (see the generator): good frames 64..1518 bytes, preamble
// lengths 0..10, CRC errors in data and FCS, rx_er inside a frame and in the gap,
// runts (63, 20, 5, 4, 1, 0 bytes), too-long frames (1519, 3000 bytes), a broken
// preamble, and back-to-back frames with the minimum 12-cycle gap.
//
// Run (from the repository root):
//   iverilog -g2012 -o sim.vvp rtl/enet_crc32.sv rtl/enet_gmii_rx.sv rtl/enet_mac_rx.sv tb/tb_enet_mac_rx.sv && vvp sim.vvp

module tb_enet_mac_rx;
    parameter int MAX_CYC  = 65536;
    parameter int MAX_BEAT = 65536;

    logic       clk = 0, rst_n = 0;
    logic [7:0] gmii_rxd = 0;
    logic       gmii_rx_dv = 0, gmii_rx_er = 0;

    logic [7:0] rxd;
    logic       rx_dv, rx_er;
    logic [7:0] m_axis_tdata;
    logic       m_axis_tvalid, m_axis_tlast, m_axis_tuser;
    logic       stat_good, stat_crc_err, stat_runt, stat_too_long, stat_rx_er;

    enet_gmii_rx u_pins (
        .rx_clk(clk), .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
        .rxd(rxd), .rx_dv(rx_dv), .rx_er(rx_er)
    );
    enet_mac_rx #(.MAX_FRAME(1518)) dut (.*);

    always #4 clk = ~clk;          // 125 MHz

    logic [9:0]  stim [0:MAX_CYC-1];
    logic [9:0]  expb [0:MAX_BEAT-1];
    logic [31:0] meta [0:6];

    int n_cyc, n_beat, cyc, beat;
    int errors = 0, checks = 0;
    int c_good = 0, c_crc = 0, c_runt = 0, c_long = 0, c_rxer = 0, n_frames = 0;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 10) $display("FAIL @%0t: %s", $time, msg);
    endtask

    // Check the outputs of one clock cycle (called at the negedge, so the
    // registered outputs from the preceding posedge are stable).
    task automatic check_outputs();
        if (m_axis_tvalid) begin
            checks++;
            if (beat >= n_beat) begin
                fail($sformatf("extra output beat data=%02h tlast=%b (all %0d expected beats already seen)",
                               m_axis_tdata, m_axis_tlast, n_beat));
            end else begin
                if (m_axis_tdata !== expb[beat][7:0] || m_axis_tlast !== expb[beat][9])
                    fail($sformatf("beat %0d: data=%02h tlast=%b, expected data=%02h tlast=%b",
                                   beat, m_axis_tdata, m_axis_tlast, expb[beat][7:0], expb[beat][9]));
                else if (m_axis_tlast && m_axis_tuser !== expb[beat][8])
                    fail($sformatf("beat %0d (tlast, frame %0d): tuser=%b, expected %b",
                                   beat, n_frames, m_axis_tuser, expb[beat][8]));
                if (m_axis_tlast) n_frames++;
                beat++;
            end
        end else begin
            if (m_axis_tlast !== 1'b0) fail("tlast high without tvalid");
            if (m_axis_tuser !== 1'b0) fail("tuser high without tvalid");
        end
        if (m_axis_tuser && !m_axis_tlast) fail("tuser high on a beat that is not tlast");

        if (stat_good && (stat_crc_err || stat_runt || stat_too_long || stat_rx_er))
            fail("stat_good in the same cycle as an error pulse");
        c_good += stat_good;
        c_crc  += stat_crc_err;
        c_runt += stat_runt;
        c_long += stat_too_long;
        c_rxer += stat_rx_er;
    endtask

    initial begin
        #100_000_000;
        $display("FAIL timeout");
        $finish;
    end

    initial begin
        $readmemh("tb/vectors/mac_rx_in.hex", stim);
        $readmemh("tb/vectors/mac_rx_exp.hex", expb);
        $readmemh("tb/vectors/mac_rx_meta.hex", meta);
        n_cyc  = meta[0];
        n_beat = meta[1];
        if (n_cyc <= 0 || n_cyc > MAX_CYC || n_beat <= 0 || n_beat > MAX_BEAT) begin
            $display("FAIL bad vector files (cycles=%0d beats=%0d); run python3 tb/gen_mac_rx_vectors.py",
                     n_cyc, n_beat);
            $finish;
        end

        // Reset with the clock running and the pins idle (enet_gmii_rx has no
        // reset, so its registers fill with idle values here).
        repeat (5) @(negedge clk);
        rst_n = 1;
        beat = 0;

        for (cyc = 0; cyc < n_cyc; cyc++) begin
            @(negedge clk);
            check_outputs();
            gmii_rx_er = stim[cyc][9];
            gmii_rx_dv = stim[cyc][8];
            gmii_rxd   = stim[cyc][7:0];
        end
        // drain
        gmii_rx_dv = 0; gmii_rx_er = 0;
        repeat (20) begin
            @(negedge clk);
            check_outputs();
        end

        if (beat != n_beat)
            fail($sformatf("only %0d of %0d expected output beats seen", beat, n_beat));
        if (c_good != meta[2]) fail($sformatf("stat_good pulsed %0d times, expected %0d", c_good, meta[2]));
        if (c_crc  != meta[3]) fail($sformatf("stat_crc_err pulsed %0d times, expected %0d", c_crc, meta[3]));
        if (c_runt != meta[4]) fail($sformatf("stat_runt pulsed %0d times, expected %0d", c_runt, meta[4]));
        if (c_long != meta[5]) fail($sformatf("stat_too_long pulsed %0d times, expected %0d", c_long, meta[5]));
        if (c_rxer != meta[6]) fail($sformatf("stat_rx_er pulsed %0d times, expected %0d", c_rxer, meta[6]));

        if (errors == 0)
            $display("PASS %0d frames out, %0d beats, %0d cycles (good %0d, crc %0d, runt %0d, long %0d, rx_er %0d)",
                     n_frames, beat, n_cyc, c_good, c_crc, c_runt, c_long, c_rxer);
        else
            $display("FAIL %0d errors in %0d checks", errors, checks);
        $finish;
    end
endmodule