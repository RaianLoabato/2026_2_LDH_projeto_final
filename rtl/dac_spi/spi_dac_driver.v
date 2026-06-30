
module spi_dac_driver #(
    parameter CLK_DIV = 25              // Divisor de clock -> SPI = 1 MHz @ 50 MHz
)(
    // -- Sinais de sistema ---------------------------------------------------
    input  wire        clk,             // Clock do sistema (50 MHz no DE10-Lite)
    input  wire        rst_n,           // Reset assincrono ativo-baixo

    // -- Interface com bloco upstream (FIR / ADC wrapper) --------------------
    input  wire [11:0] data_in,         // Amostra de 12 bits a converter
    input  wire        start,           // Pulso de 1 ciclo: inicia transmissao
    output reg         busy,            // '1' durante transmissao em curso
    output reg         done,            // Pulso de 1 ciclo: transmissao concluida

    // -- Pinos SPI -> GPIO do DE10-Lite ---------------------------------------
    output reg         spi_clk,         // SCK  -> GPIO_0[0]
    output reg         spi_mosi,        // SDI  -> GPIO_0[2]
    output reg         spi_cs_n         // /CS  -> GPIO_0[4]
);

    // Nibble de controle fixo: A/~B=0, BUF=0, ~GA=1, ~SHDN=1
    localparam [3:0] CTRL = 4'b0011;
    localparam TOTAL_BITS = 16;

    reg [7:0]  clk_cnt;     // Contador do divisor de clock
    reg        spi_tick;    // Pulso de "meio periodo SPI"
    reg [15:0] shift_reg;   // Registrador de deslocamento (16 bits do frame)
    reg [5:0]  toggle_cnt;  // Conta togglings de SCK (0..31)
    reg        tx_active;   // '1' enquanto a transmissao esta em curso

    // Divisor de clock -> gera spi_tick a cada CLK_DIV ciclos de clk
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt  <= 8'd0;
            spi_tick <= 1'b0;
        end else begin
            if (clk_cnt == CLK_DIV - 1) begin
                clk_cnt  <= 8'd0;
                spi_tick <= 1'b1;
            end else begin
                clk_cnt  <= clk_cnt + 8'd1;
                spi_tick <= 1'b0;
            end
        end
    end

    // FSM de transmissao SPI (Figure 5-1 do datasheet MCP4921)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_clk    <= 1'b0;      // SCK idle LOW (CPOL=0)
            spi_mosi   <= 1'b0;
            spi_cs_n   <= 1'b1;      // /CS desassertado
            busy       <= 1'b0;
            done       <= 1'b0;      // DN em repouso = 0 (sem pulso ativo)
            tx_active  <= 1'b0;
            shift_reg  <= 16'd0;
            toggle_cnt <= 6'd0;
        end else begin
            // done eh um PULSO de 1 ciclo: volta para 0 por padrao a cada borda
            done <= 1'b0;

            // ---- IDLE: aguarda start --------------------------------------
            if (!tx_active) begin
                spi_clk  <= 1'b0;
                spi_cs_n <= 1'b1;

                if (start) begin
                    shift_reg  <= {CTRL, data_in};  // Monta o frame de 16 bits
                    toggle_cnt <= 6'd0;
                    tx_active  <= 1'b1;
                    busy       <= 1'b1;

                    spi_cs_n  <= 1'b0;              // /CS cai
                    spi_mosi  <= CTRL[3];           // Bit 15 (MSB) ja em SDI
                end
            end

            // ---- ACTIVE: serializa os 16 bits ------------------------------
            else if (spi_tick) begin
                toggle_cnt <= toggle_cnt + 6'd1;

                if (!spi_clk) begin
                    // Borda de SUBIDA -> DAC captura o bit atual de SDI
                    spi_clk <= 1'b1;
                end else begin
                    // Borda de DESCIDA -> prepara proximo bit
                    spi_clk <= 1'b0;

                    if (toggle_cnt == 6'd31) begin
                        // Ultimo bit enviado -> finaliza
                        spi_cs_n  <= 1'b1;   // /CS sobe -> DAC converte
                        spi_mosi  <= 1'b0;
                        tx_active <= 1'b0;
                        busy      <= 1'b0;
                        done      <= 1'b1;   // pulso DN: transmissao concluida
                    end else begin
                        shift_reg <= shift_reg << 1;
                        spi_mosi  <= shift_reg[14];
                    end
                end
            end
        end
    end

endmodule