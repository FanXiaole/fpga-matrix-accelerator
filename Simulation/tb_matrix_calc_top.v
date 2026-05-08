`timescale 1ns / 1ps

module tb_matrix_calc_top();

    // Parameters
    parameter CLK_PERIOD = 10; // 100MHz
    parameter BAUD_RATE = 115200;
    parameter BIT_PERIOD = 1000000000 / BAUD_RATE; // ns per bit

    // Inputs
    reg clk;
    reg rst_n;
    reg UART_rx;
    reg [7:0] SW;
    reg BTN_start;

    // Outputs
    wire UART_tx;
    wire [7:0] LED;
    wire [7:0] SEG;
    wire [7:0] AN;

    // Instantiate the Unit Under Test (UUT)
    matrix_calc_top #(
        .CLK_FREQ(100_000_000),
        .BAUD_RATE(BAUD_RATE)
    ) uut (
        .clk(clk), 
        .rst_n(rst_n), 
        .UART_rx(UART_rx), 
        .UART_tx(UART_tx), 
        .SW(SW), 
        .BTN_start(BTN_start), 
        .LED(LED), 
        .SEG(SEG), 
        .AN(AN)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // UART Send Task (Simulates PC sending data to FPGA)
    task uart_send_byte;
        input [7:0] data;
        integer i;
        begin
            // Start bit
            UART_rx = 0;
            #(BIT_PERIOD);
            
            // Data bits
            for (i = 0; i < 8; i = i + 1) begin
                UART_rx = data[i];
                #(BIT_PERIOD);
            end
            
            // Stop bit
            UART_rx = 1;
            #(BIT_PERIOD);
        end
    endtask

    initial begin
        // Initialize Inputs
        rst_n = 0;
        UART_rx = 1;
        SW = 0;
        BTN_start = 0;

        // Wait 100 ns for global reset to finish
        #100;
        rst_n = 1;
        #100;

        // -------------------------------------------------
        // Test Case 1: Input Mode (SW = 000)
        // -------------------------------------------------
        $display("Starting Test Case 1: Input Mode");
        SW = 3'b000; // Input Mode
        
        // Simulate sending a matrix element (e.g., value 5) via UART
        // Note: You need to match the protocol expected by matrix_input.v
        // Assuming it expects raw bytes or ASCII. Here is a raw byte example:
        uart_send_byte(8'd5); 
        
        #1000;
        BTN_start = 1; // Latch data
        #20;
        BTN_start = 0;
        #100;

        // -------------------------------------------------
        // Test Case 2: Calculation Mode (SW = 011) - Addition
        // -------------------------------------------------
        $display("Starting Test Case 2: Calculation (Add)");
        SW = 8'b00010011; // [7:3]=00010 (OpType=1 Add), [2:0]=011 (Calc Mode)
        
        #100;
        BTN_start = 1; // Start Calculation
        #20;
        BTN_start = 0;

        // Wait for calculation to complete (monitor LED or internal done signal)
        #5000;

        $display("Test Completed");
        $stop;
    end
      
endmodule
