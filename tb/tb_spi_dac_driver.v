`timescale 1ns/1ps

// =============================================================================
// Testbench : tb_spi_dac_driver
// DUT       : spi_dac_driver
//
// Fluxo de teste (igual ao quadro):
//   1. Aplica data_in
//   2. Pulsa start por 1 ciclo de clock
//   3. Captura o frame SPI (SDI/SCK/CS) ENQUANTO espera done subir
//   4. Quando done = 1 -> transmissao terminou -> compara frame capturado
//
// Para rodar no ModelSim:
//   vlib work
//   vlog spi_dac_driver.v tb_dac_driver.v
//   vsim -novopt tb_spi_dac_driver
//   add wave -r *
//   run -all
// =============================================================================

module tb_spi_dac_driver;

    // -- Parametros ------------------------------------------------------------
    localparam CLK_PERIOD = 20;     // 50 MHz
    localparam CLK_DIV_TB = 5;      // spi_clk = 50MHz/(2*5) = 5 MHz
    localparam TOTAL_BITS = 16;

    // -- Sinais ------------------------------------------------------------------
    reg         clk;
    reg         rst_n;
    reg  [11:0] data_in;
    reg         start;
    wire        busy;
    wire        done;          // <-- novo: sinal "DN" do quadro
    wire        spi_clk;
    wire        spi_mosi;
    wire        spi_cs_n;

    reg [15:0] captured;
    integer    error_count;
    integer    idx;
    reg        spi_clk_prev;   // guarda valor anterior de spi_clk p/ detectar borda

    // -- DUT -----------------------------------------------------------------
    spi_dac_driver #(.CLK_DIV(CLK_DIV_TB)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .data_in  (data_in),
        .start    (start),
        .busy     (busy),
        .done     (done),
        .spi_clk  (spi_clk),
        .spi_mosi (spi_mosi),
        .spi_cs_n (spi_cs_n)
    );

    // -- Clock -----------------------------------------------------------------
    initial clk = 1'b0;
    always  #(CLK_PERIOD/2) clk = ~clk;

    // ===========================================================================
    // Tarefa: aplica start, captura o frame em paralelo, espera done, compara
    // ===========================================================================
    task testa;
        input [11:0] amostra;
        input [15:0] esperado;
        integer bit_idx;
        begin
            // 1) Garante que o driver esta livre antes de comecar
            if (busy) @(negedge busy);
            @(negedge clk);

            // 2) Aplica o dado de entrada (DAT)
            data_in = amostra;

            // 3) Pulsa START por exatamente 1 ciclo de clock
            @(negedge clk);
            start = 1'b1;
            $display("[%0t ns] START=1 (1 ciclo) -- data_in=0x%03X", $time, amostra);
            @(negedge clk);
            start = 1'b0;

            // 4) Reseta o frame capturado antes de comecar a amostrar
            captured = 16'h0000;
            bit_idx  = TOTAL_BITS - 1;

            // 5) Loop: amostra SDI a cada SCK e ao mesmo tempo fica de olho em DONE.
            //    Sai do loop assim que done=1 (transmissao concluida).
            while (!done) begin
                @(posedge clk);
                // Sempre que o SCK sobe, captura o bit que esta em SDI
                if (spi_clk && !spi_clk_prev) begin
                    captured[bit_idx] = spi_mosi;
                    if (bit_idx > 0) bit_idx = bit_idx - 1;
                end
            end

            // 6) DONE chegou em 1 -> transmissao concluida, onda completa gerada
            $display("[%0t ns] DONE=1 -- frame capturado = 0x%04X", $time, captured);

            // 7) Verifica o frame
            if (captured === esperado)
                $display("  PASS  data_in=0x%03X  frame=0x%04X  OK", amostra, captured);
            else begin
                $display("  FAIL  data_in=0x%03X  capturado=0x%04X  esperado=0x%04X",
                          amostra, captured, esperado);
                error_count = error_count + 1;
            end

            repeat(10) @(posedge clk);  // pausa entre testes
        end
    endtask

    // -- Auxiliar: atualiza spi_clk_prev a cada ciclo para detectar borda de subida --
    always @(posedge clk) spi_clk_prev <= spi_clk;

    // ===========================================================================
    // Corpo principal
    // ===========================================================================
    initial begin
        $dumpfile("tb_spi_dac_driver.vcd");
        $dumpvars(0, tb_spi_dac_driver);

        clk          = 1'b0;
        rst_n        = 1'b0;
        start        = 1'b0;
        data_in      = 12'h000;
        captured     = 16'h0000;
        error_count  = 0;
        idx          = 0;
        spi_clk_prev = 1'b0;

        // Reset
        $display("[%0t ns] Reset asserted", $time);
        repeat(8) @(posedge clk);
        rst_n = 1'b1;
        $display("[%0t ns] Reset released", $time);
        repeat(6) @(posedge clk);

        // -- Teste 0: sinais pos-reset --------------------------------------
        $display("\n=== TESTE 0: sinais pos-reset ===");
        if (spi_cs_n !== 1'b1) begin
            $display("  FAIL spi_cs_n=%b esperado=1", spi_cs_n); error_count=error_count+1;
        end else $display("  PASS spi_cs_n=1");
        if (busy !== 1'b0) begin
            $display("  FAIL busy=%b esperado=0", busy); error_count=error_count+1;
        end else $display("  PASS busy=0");
        if (done !== 1'b0) begin
            $display("  FAIL done=%b esperado=0", done); error_count=error_count+1;
        end else $display("  PASS done=0");

        $display("\n=== TESTE 1: 0xABC -> 0x3ABC ===");
        testa(12'hABC, 16'h3ABC);

        $display("\n=== TESTE 2: 0x000 -> 0x3000 ===");
        testa(12'h000, 16'h3000);

        $display("\n=== TESTE 3: 0xFFF -> 0x3FFF ===");
        testa(12'hFFF, 16'h3FFF);

        $display("\n=== TESTE 4: 0x555 -> 0x3555 ===");
        testa(12'h555, 16'h3555);

        $display("\n=== TESTE 5: 0xAAA -> 0x3AAA ===");
        testa(12'hAAA, 16'h3AAA);

        $display("\n============================================");
        if (error_count == 0)
            $display("  TODOS OS TESTES PASSARAM");
        else
            $display("  %0d TESTE(S) FALHARAM", error_count);
        $display("============================================");

        $finish;
    end

    // -- Timeout de seguranca ---------------------------------------------------
    initial begin
        #(6 * TOTAL_BITS * 2 * CLK_DIV_TB * CLK_PERIOD * 100);
        $display("TIMEOUT -- simulacao travada!");
        $finish;
    end

endmodule