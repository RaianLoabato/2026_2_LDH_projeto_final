

module spi_dac_driver #(
    parameter CLK_DIV = 25              // Divisor de clock → SPI = 1 MHz @ 50 MHz
)(
    // ── Sinais de sistema ────────────────────────────────────────────────────
    input  wire        clk,             // Clock do sistema (50 MHz no DE10-Lite)
    input  wire        rst_n,           // Reset assíncrono ativo-baixo

    // ── Interface com bloco upstream (FIR / ADC wrapper) ─────────────────────
    input  wire [11:0] data_in,         // Amostra de 12 bits a converter
    input  wire        start,           // Pulso de 1 ciclo: inicia transmissão
    output reg         busy,            // '1' durante transmissão em curso

    // ── Pinos SPI → GPIO do DE10-Lite ────────────────────────────────────────
    output reg         spi_clk,         // SCK  → GPIO_0[0]
    output reg         spi_mosi,        // SDI  → GPIO_0[2]
    output reg         spi_cs_n         // /CS  → GPIO_0[4]
);

    // =========================================================================
    // Parâmetros internos
    // =========================================================================

    // Nibble de controle fixo: A/~B=0, BUF=0, ~GA=1, ~SHDN=1
    localparam [3:0] CTRL = 4'b0011;

    // Número de bits no frame SPI
    localparam TOTAL_BITS = 16;

    // =========================================================================
    // Registradores internos
    // =========================================================================

    // Contador para divisão de clock (8 bits suporta CLK_DIV até 255)
    reg [7:0]  clk_cnt;

    // Pulso de "meio período SPI": togla spi_clk a cada ocorrência
    reg        spi_tick;

    // Registrador de deslocamento: guarda os 16 bits a enviar (MSB no topo)
    reg [15:0] shift_reg;

    // Quantos togglings de SCK já ocorreram:
    //   - toggle ímpar  (1,3,5,...) = borda de SUBIDA  → DAC captura
    //   - toggle par    (2,4,6,...) = borda de DESCIDA → driver coloca próximo bit
    // Precisamos de 2×16 = 32 togglings; usamos 6 bits (0..63)
    reg [5:0]  toggle_cnt;

    // Indica transmissão em andamento
    reg        tx_active;

    // =========================================================================
    // Divisor de clock → gera spi_tick a cada CLK_DIV ciclos de clk
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt  <= 8'd0;
            spi_tick <= 1'b0;
        end else begin
            if (clk_cnt == CLK_DIV - 1) begin
                clk_cnt  <= 8'd0;       // Reinicia contador
                spi_tick <= 1'b1;       // Emite tick
            end else begin
                clk_cnt  <= clk_cnt + 8'd1;
                spi_tick <= 1'b0;
            end
        end
    end

    // =========================================================================
    // FSM de transmissão SPI
    //
    // Sequência de eventos por bit (Figure 5-1):
    //   1. /CS cai + SDI recebe MSB         (antes do toggle 1)
    //   2. Toggle ímpar  → SCK sobe          → DAC captura SDI
    //   3. Toggle par    → SCK desce         → driver coloca próximo bit em SDI
    //   ... repete para os 16 bits ...
    //   4. Após toggle 32 (descida do SCK 15) → /CS sobe → Vout atualiza
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_clk   <= 1'b0;          // SCK idle LOW (CPOL=0)
            spi_mosi  <= 1'b0;          // SDI em nível baixo
            spi_cs_n  <= 1'b1;          // /CS desassertado
            busy      <= 1'b0;
            tx_active <= 1'b0;
            shift_reg <= 16'd0;
            toggle_cnt<= 6'd0;
        end

        // ── IDLE: aguarda start ───────────────────────────────────────────────
        else if (!tx_active) begin
            spi_clk  <= 1'b0;           // Mantém SCK em LOW (idle)
            spi_cs_n <= 1'b1;           // /CS desassertado

            if (start) begin
                // Monta frame: [15:12]=CTRL, [11:0]=dado
                shift_reg  <= {CTRL, data_in};

                toggle_cnt <= 6'd0;     // Zera contador de togglings
                tx_active  <= 1'b1;     // Entra em modo de transmissão
                busy       <= 1'b1;

                // /CS cai e SDI já recebe o MSB (bit 15) neste mesmo ciclo,
                // conforme Figure 5-1: SDI muda junto com /CS antes do SCK 0
                spi_cs_n  <= 1'b0;
                spi_mosi  <= CTRL[3];   // Bit 15 do frame = MSB do nibble de controle
                                        // CTRL[3]=0 → A/~B=0 (canal A)
            end
        end

        // ── ACTIVE: serializa 16 bits ─────────────────────────────────────────
        else begin
            if (spi_tick) begin

                toggle_cnt <= toggle_cnt + 6'd1; // Conta cada toggle de SCK

                // ── Borda de SUBIDA do SCK (togglings ímpares: 1,3,5,...,31) ──
                // O MCP4921 captura SDI nesta borda.
                // Não mexemos em SDI aqui — o bit já estava estável desde a
                // borda de descida anterior (ou desde /CS↓ para o bit 15).
                if (!spi_clk) begin
                    spi_clk <= 1'b1;    // SCK sobe → DAC captura o bit atual de SDI

                // ── Borda de DESCIDA do SCK (togglings pares: 2,4,6,...,32) ──
                // Aqui colocamos o próximo bit em SDI (setup para próxima subida).
                end else begin
                    spi_clk <= 1'b0;    // SCK desce

                    if (toggle_cnt == 6'd31) begin
                        // Esse é o toggle 32 (descida após captura do bit 0 = LSB).
                        // Frame completo enviado → finaliza transmissão.
                        spi_cs_n  <= 1'b1;  // /CS sobe → MCP4921 converte e atualiza Vout
                        spi_mosi  <= 1'b0;  // SDI limpo
                        tx_active <= 1'b0;  // Volta ao IDLE
                        busy      <= 1'b0;
                    end else begin
                        // Desloca o registrador à esquerda e apresenta o próximo bit.
                        // toggle_cnt é par (2,4,...,30) → já enviamos (toggle_cnt/2) bits.
                        // O próximo bit a apresentar é shift_reg[14] após o shift.
                        shift_reg <= shift_reg << 1;        // Descarta o bit já enviado
                        spi_mosi  <= shift_reg[14];         // Próximo MSB (após shift)
                                                            // shift_reg[14] = bit atual [15-1]
                    end
                end
            end
            // Enquanto spi_tick=0, todos os sinais permanecem estáveis
        end
    end

endmodule