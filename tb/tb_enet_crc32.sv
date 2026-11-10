`timescale 1ns/1ps

// Self-checking testbench for enet_crc32 (spec: docs/architecture.md 6.1).
//
// Vectors come from tb/gen_crc32_vectors.py (reference: Python zlib.crc32).
// For each message the testbench restarts the CRC, feeds the bytes, and checks
// `crc` against the expected register value one cycle after the last byte.
//
// Checked:
//   1. reset value 32'hFFFFFFFF
//   2. every message, including "123456789", an empty message, all lengths
//      1..16, random lengths up to 1518, and frames with FCS appended
//      (must leave the residue 32'hDEBB20E3)
//   3. the state holds while valid = 0 (idle gaps inside and after messages)
//   4. init alone for a cycle before a message, and init together with the
//      first byte (back-to-back frames), chosen at random per message
//
// Run (from the repository root):
//   iverilog -g2012 -o sim.vvp rtl/enet_crc32.sv tb/tb_enet_crc32.sv && vvp sim.vvp
//   vvp sim.vvp +seed=7

module tb_enet_crc32;
    parameter int MAX_BYTES = 65536;
    parameter int MAX_MSGS  = 256;

    logic        clk = 0, rst_n = 0;
    logic        init = 0, valid = 0;
    logic [7:0]  data = 0;
    logic [31:0] crc;

    enet_crc32 dut (.*);
    always #4 clk = ~clk;          // 125 MHz

    logic [7:0]  mem  [0:MAX_BYTES-1];
    logic [31:0] lens [0:MAX_MSGS];        // lens[0] = number of messages
    logic [31:0] exps [0:MAX_MSGS-1];

    int errors = 0, checks = 0;
    int seed = 1;
    int n_msgs, pos, m, i, gap, len;
    int n_joined = 0, n_gapped = 0, n_bytes = 0;
    logic joined, gapped;
    logic [31:0] held;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 10) $display("FAIL @%0t: %s", $time, msg);
    endtask

    task automatic expect_crc(input logic [31:0] exp, input string what);
        checks++;
        if (crc !== exp)
            fail($sformatf("%s: crc=%08h expected %08h", what, crc, exp));
    endtask

    // Watchdog
    initial begin
        #50_000_000;
        $display("FAIL timeout");
        $finish;
    end

    initial begin
        if ($value$plusargs("seed=%d", seed)) ;
        void'($urandom(seed));

        $readmemh("tb/vectors/crc32_data.hex", mem);
        $readmemh("tb/vectors/crc32_len.hex", lens);
        $readmemh("tb/vectors/crc32_exp.hex", exps);
        n_msgs = lens[0];
        if (n_msgs <= 0 || n_msgs > MAX_MSGS) begin
            $display("FAIL bad vector files (n_msgs=%0d); run python3 tb/gen_crc32_vectors.py", n_msgs);
            $finish;
        end

        // 1. reset
        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        expect_crc(32'hFFFFFFFF, "after reset");

        // 2-4. messages
        pos = 0;
        for (m = 0; m < n_msgs; m++) begin
            len    = lens[m + 1];
            joined = (len > 0) && ($urandom % 2);
            gapped = ($urandom % 3) != 0;
            if (joined) n_joined++;
            if (gapped) n_gapped++;

            if (!joined) begin
                @(negedge clk); init = 1; valid = 0;
                @(negedge clk); init = 0;
            end

            for (i = 0; i < len; i++) begin
                if (gapped && i > 0) begin
                    gap = $urandom % 4;           // 0..3 idle cycles
                    repeat (gap) begin
                        @(negedge clk); valid = 0; init = 0;
                    end
                end
                @(negedge clk);
                init  = joined && (i == 0);
                valid = 1;
                data  = mem[pos + i];
                n_bytes++;
            end

            // The edge after the last byte has updated crc by the next negedge.
            @(negedge clk); valid = 0; init = 0;
            expect_crc(exps[m], $sformatf("message %0d (len %0d, %s, %s)", m, len,
                       joined ? "init+first byte" : "init alone",
                       gapped ? "gaps" : "no gaps"));

            // 3. state holds while idle
            held = crc;
            gap = 1 + $urandom % 3;
            repeat (gap) @(negedge clk);
            expect_crc(held, $sformatf("message %0d: hold while valid=0", m));

            pos += len;
        end

        if (errors == 0)
            $display("PASS %0d messages, %0d bytes, %0d checks (%0d init+first byte, %0d with gaps)",
                     n_msgs, n_bytes, checks, n_joined, n_gapped);
        else
            $display("FAIL %0d errors in %0d checks", errors, checks);
        $finish;
    end
endmodule