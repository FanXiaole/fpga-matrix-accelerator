`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/10/11 00:05:01
// Design Name: 
// Module Name: uart_rx
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module uart_rx #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD_RATE = 115200
)(
    input wire clk,
    input wire rst_n,
    input wire rx,            
    output reg [7:0] rx_data,  
    output reg rx_done        
);
//完全是照搬提供的代码
    localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;

    reg [15:0] baud_cnt;
    reg [3:0] bit_idx;
    reg [9:0] rx_shift;
    reg rx_busy;
    reg rx_d1, rx_d2;

   
    always @(posedge clk) begin
        rx_d1 <= rx;
        rx_d2 <= rx_d1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud_cnt <= 0;
            bit_idx <= 0;
            rx_busy <= 0;
            rx_done <= 0;
            rx_data <= 8'b0;
        end else begin
            rx_done <= 0;
            if (!rx_busy) begin
                if (rx_d2 == 0) begin 
                    rx_busy <= 1;
                    baud_cnt <= BAUD_DIV / 2; 
                    bit_idx <= 0;
                end
            end else begin
                if (baud_cnt == BAUD_DIV - 1) begin
                    baud_cnt <= 0;
                    bit_idx <= bit_idx + 1;
                    case (bit_idx)
                        0: ; 
                        1,2,3,4,5,6,7,8: rx_shift[bit_idx-1] <= rx_d2;
                        9: begin
                            rx_busy <= 0;
                            rx_data <= rx_shift[7:0];
                            rx_done <= 1;
                        end
                    endcase
                end else begin  
                    baud_cnt <= baud_cnt + 1;
                end
            end
        end
    end
endmodule
