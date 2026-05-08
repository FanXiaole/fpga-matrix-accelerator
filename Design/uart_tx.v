`timescale 1ns / 1ps
//与提供的代码的逻辑类似，功能相同，只是使用的是状态机实现的
module uart_tx #(
    parameter CLK_FREQ = 100_000_000,   // 系统时钟频率
    parameter BAUD_RATE = 115200        // 目标波特率
)(
    input wire clk,
    input wire rst_n,
    input wire start,                   // 发送开始信号 (脉冲)
    input wire [7:0] data,              // 待发送的 8 位数据
    output reg tx,                      // UART TX 输出引脚
    output reg busy,                    // 忙信号：高电平表示正在发送
    output reg done                     // 完成信号：发送结束时产生一个脉冲
);

    // 计算波特率分频系数
    localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;

    reg [15:0] baud_cnt;    // 波特率计数器
    reg [3:0] bit_idx;      // 当前发送的位索引 (0-7)
    reg [8:0] shift_reg;    // 移位寄存器：包含起始位 + 8位数据

    // 状态机状态定义
    localparam S_IDLE  = 0; // 空闲状态
    localparam S_START = 1; // 发送起始位
    localparam S_DATA  = 2; // 发送数据位
    localparam S_STOP  = 3; // 发送停止位
    
    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx <= 1'b1;         // 空闲时 TX 为高电平
            busy <= 1'b0;
            done <= 1'b0;
            baud_cnt <= 0;
            bit_idx <= 0;
            state <= S_IDLE;
            shift_reg <= 0;
        end else begin
            done <= 1'b0; // 默认拉低完成信号 (脉冲)
            
            case (state)
                S_IDLE: begin
                    tx <= 1'b1; // 保持高电平
                    if (start) begin
                        busy <= 1'b1;
                        // 加载数据：数据位 + 起始位(0) 在最低位
                        // 移位时向右移，先发低位 (LSB First)
                        // 这里 shift_reg[0] 将是起始位 0
                        shift_reg <= {data, 1'b0}; 
                        state <= S_START;
                        baud_cnt <= 0;
                    end else begin
                        busy <= 1'b0;
                    end
                end

                //九位，最低位是0，作为起始位让电脑开始读数据
                //接着开始填入1，这样在结束的时候就能平滑过渡到1的初始状态
                S_START: begin
                    tx <= shift_reg[0]; // 发送起始位 (0)
                    if (baud_cnt == BAUD_DIV - 1) begin
                        baud_cnt <= 0;
                        bit_idx <= 0;
                        // 移位：高位补 1 (为停止位做准备)，右移
                        shift_reg <= {1'b1, shift_reg[8:1]}; 
                        state <= S_DATA;
                    end else begin
                        baud_cnt <= baud_cnt + 1;
                    end
                end

                S_DATA: begin
                    tx <= shift_reg[0]; // 发送当前最低位数据
                    if (baud_cnt == BAUD_DIV - 1) begin
                        baud_cnt <= 0;
                        shift_reg <= {1'b1, shift_reg[8:1]}; // 继续移位
                        if (bit_idx == 7) begin
                            state <= S_STOP; // 8位数据发完，进入停止位
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1;
                    end
                end

                S_STOP: begin
                    tx <= 1'b1; // 发送停止位 (1)
                    if (baud_cnt == BAUD_DIV - 1) begin
                        baud_cnt <= 0;
                        busy <= 1'b0;
                        done <= 1'b1; // 发送完成
                        state <= S_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt + 1;
                    end
                end
            endcase
        end
    end
endmodule
