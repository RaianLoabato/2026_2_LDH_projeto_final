`timescale 1ns/1ps

// =============================================================================
// Testbench : tb_spi_dac_driver
// DUT       : spi_dac_driver
//
// Verifica o frame SPI de 16 bits gerado pelo driver para o MCP4921.
// Frame esperado: [15:12]=0011 (ctrl), [11:0]=data_in
//
// Para rodar no ModelSim:
//   vlib work
//   vlog spi_dac_driver.v tb_spi_dac_driver.v
//   vsim -novopt tb_spi_dac_driver
//   add wave -r *
//   run -all
// =============================================================================

module tb_spi_dac_driver;

    // ── Parâmetros ────────────────────────────────────────────────────────────
    localparam CLK_PERIOD = 20;     // 50 MHz
    localparam CLK_DIV_TB = 5;      // spi_clk = 50MHz/(2*5) = 5 MHz
    localparam TOTAL_BITS = 16;

    // ── Sinais ────────────────────────────────────────────────────────────────
    reg         clk;
    reg         rst_n;
    reg  [11:0] data_in;
    reg         start;
    wire        busy;
    wire        spi_clk;
    wire        spi_mosi;
    wire        spi_cs_n;

    // Auxiliares
    reg [15:0] captured;
    integer    error_count;
    integer    idx;

    // ── DUT ───────────────────────────────────────────────────────────────────
    spi_dac_driver #(.CLK_DIV(CLK_DIV_TB)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .data_in  (data_in),
        .start    (start),
        .busy     (busy),
        .spi_clk  (spi_clk),
        .spi_mosi (spi_mosi),
        .spi_cs_n (spi_cs_n)
    );

    // ── Clock ─────────────────────────────────────────────────────────────────
    initial clk = 1'b0;
    always  #(CLK_PERIOD/2) clk = ~clk;

    // ── Tarefa principal: dispara + captura + verifica ─────────────────────
    task testa;
        input [11:0] amostra;
        input [15:0] esperado;
        begin
            // 1) Garante que driver está livre
            if (busy) begin
                $display("[%0t] Aguardando fim de busy antes de disparar...", $time);
                @(negedge busy);
                repeat(4) @(posedge clk);
            end

            // 2) Apresenta dado ANTES do start (setup)
            @(negedge clk);             // muda em borda de descida (safe)
            data_in = amostra;

            // 3) Pulsa start por exatamente 1 ciclo de clock
            @(negedge clk);
            start = 1'b1;
            $display("[%0t ns] START pulsado — data_in=0x%03X", $time, amostra);
            @(negedge clk);
            start = 1'b0;

            // 4) Confirma que busy subiu (DUT aceitou o start)
            // Se não subiu em 5 ciclos, algo está errado
            repeat(5) @(posedge clk);
            if (!busy) begin
                $display("[%0t] ERRO: busy nao subiu apos start!", $time);
                error_count = error_count + 1;
                disable testa;
            end

            // 5) Aguarda /CS cair (DUT asserta /CS ao aceitar o start)
            @(negedge spi_cs_n);
            $display("[%0t ns] /CS caiu — frame iniciando", $time);

            // 6) Amostra SDI em cada borda de SUBIDA do SCK (como o MCP4921)
            captured = 16'h0000;
            for (idx = TOTAL_BITS-1; idx >= 0; idx = idx - 1) begin
                @(posedge spi_clk);
                captured[idx] = spi_mosi;
            end

            // 7) Aguarda /CS subir (frame completo — DAC converte)
            @(posedge spi_cs_n);
            $display("[%0t ns] /CS subiu — frame = 0x%04X", $time, captured);

            // 8) Verifica
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

    // ── Corpo principal ───────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_spi_dac_driver.vcd");
        $dumpvars(0, tb_spi_dac_driver);

        // Inicialização
        clk         = 1'b0;
        rst_n       = 1'b0;
        start       = 1'b0;
        data_in     = 12'h000;
        captured    = 16'h0000;
        error_count = 0;
        idx         = 0;

        // Reset
        $display("[%0t ns] Reset asserted", $time);
        repeat(8) @(posedge clk);
        rst_n = 1'b1;
        $display("[%0t ns] Reset released", $time);
        repeat(6) @(posedge clk);

        // ── Teste 0: pós-reset ─────────────────────────────────────────────
        $display("\n=== TESTE 0: sinais pos-reset ===");
        if (spi_cs_n !== 1'b1) begin
            $display("  FAIL spi_cs_n=%b esperado=1", spi_cs_n); error_count=error_count+1;
        end else $display("  PASS spi_cs_n=1");

        if (spi_clk !== 1'b0) begin
            $display("  FAIL spi_clk=%b esperado=0 (CPOL=0)", spi_clk); error_count=error_count+1;
        end else $display("  PASS spi_clk=0 (CPOL=0)");

        if (busy !== 1'b0) begin
            $display("  FAIL busy=%b esperado=0", busy); error_count=error_count+1;
        end else $display("  PASS busy=0");

        // ── Teste 1: 0xABC → 0x3ABC ──────────────────────────────────────
        $display("\n=== TESTE 1: 0xABC -> 0x3ABC ===");
        testa(12'hABC, 16'h3ABC);

        // ── Teste 2: 0x000 → 0x3000 ──────────────────────────────────────
        $display("\n=== TESTE 2: 0x000 -> 0x3000 ===");
        testa(12'h000, 16'h3000);

        // ── Teste 3: 0xFFF → 0x3FFF ──────────────────────────────────────
        $display("\n=== TESTE 3: 0xFFF -> 0x3FFF ===");
        testa(12'hFFF, 16'h3FFF);

        // ── Teste 4: 0x555 → 0x3555 ──────────────────────────────────────
        $display("\n=== TESTE 4: 0x555 -> 0x3555 ===");
        testa(12'h555, 16'h3555);

        // ── Teste 5: 0xAAA → 0x3AAA ──────────────────────────────────────
        $display("\n=== TESTE 5: 0xAAA -> 0x3AAA ===");
        testa(12'hAAA, 16'h3AAA);

        // ── Resumo ────────────────────────────────────────────────────────
        $display("\n============================================");
        if (error_count == 0)
            $display("  TODOS OS TESTES PASSARAM");
        else
            $display("  %0d TESTE(S) FALHARAM", error_count);
        $display("============================================");

        $finish;
    end

    // ── Timeout de segurança ─────────────────────────────────────────────────
    initial begin
        #(6 * TOTAL_BITS * 2 * CLK_DIV_TB * CLK_PERIOD * 100);
        $display("TIMEOUT — simulacao travada!");
        $finish;
    end

endmodule