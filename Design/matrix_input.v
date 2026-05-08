`timescale 1ns / 1ps

module matrix_input #(
    parameter MAX_M = 5,           // 最大行数
    parameter MAX_N = 5,           // 最大列数
    parameter DATA_WIDTH = 16,     // 数据位宽
    parameter TOTAL_BITS = MAX_M * MAX_N * DATA_WIDTH // 总数据位数
)(
    input  wire clk,
    input  wire rst_n,
    input  wire UART_rx,           // UART接收引脚
    input  wire start,             // 开始接收信号

    output reg  done,              // 接收完成信号
    output reg  [2:0] out_dim_m,   // 输出矩阵行数
    output reg  [2:0] out_dim_n,   // 输出矩阵列数
    output reg  [TOTAL_BITS-1:0] out_matrix_data, // 输出矩阵数据（扁平化）
    output reg  out_store_enable   // 存储使能信号
);

    wire [7:0] rx_byte;
    wire       rx_done_tick;


    reg [1:0] state;
    localparam S_IDLE       = 2'd0; // 等待开始信号
    localparam S_PARSE      = 2'd1; // 解析接收到的字符流
    localparam S_FINISH     = 2'd2; // 完成接收，输出数据

    // ASCII 码常量定义
    localparam ASCII_0     = 8'h30;
    localparam ASCII_9     = 8'h39;
    localparam ASCII_MINUS = 8'h2D;
    localparam ASCII_SPACE = 8'h20;
    localparam ASCII_CR    = 8'h0D; // 回车
    localparam ASCII_LF    = 8'h0A; // 换行

    reg signed [15:0] current_val; // 当前解析的数值
    reg        is_negative;        // 负数标志位
    reg        has_digits;         // 是否接收到数字
    
    reg [7:0]  parse_cnt;          // 解析计数器：0->M, 1->N, 2+->Data
    reg [7:0]  total_elements_expected; // 预期接收的总元素个数 (M * N)

    reg [2:0]  curr_row;           // 当前写入的行索引
    reg [2:0]  curr_col;           // 当前写入的列索引

    // Timeout counter
    reg [23:0] timeout_cnt;        // 超时计数器
    reg        first_byte_rcvd;    // 是否接收到第一个字节
    localparam TIMEOUT_VAL = 24'd10_000_000; // 0.1s at 100MHz

    wire is_delimiter;
    wire signed [15:0] final_val;

    
    assign is_delimiter = (rx_byte == ASCII_SPACE) || (rx_byte == ASCII_LF) || (rx_byte == ASCII_CR);
    // 一个数据的输入结束了
    assign final_val = is_negative ? -current_val : current_val;
    // -表示取补码
    // 实例化UART接收模块
    uart_rx #(
        .CLK_FREQ(100_000_000), 
        .BAUD_RATE(115200)
    ) u_uart (
        .clk(clk),
        .rst_n(rst_n),
        .rx(UART_rx),
        .rx_data(rx_byte),
        .rx_done(rx_done_tick)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            out_dim_m <= 0;
            out_dim_n <= 0;
            out_matrix_data <= 0;
            out_store_enable <= 0;
            done <= 0;
            
            current_val <= 0;
            is_negative <= 0;
            has_digits <= 0;
            parse_cnt <= 0;
            total_elements_expected <= 0;
            curr_row <= 0;
            curr_col <= 0;
            timeout_cnt <= 0;
            first_byte_rcvd <= 0;
        end else begin
            out_store_enable <= 0;
            done <= 0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_PARSE;
                        parse_cnt <= 0;
                        current_val <= 0;
                        is_negative <= 0;
                        has_digits <= 0;
                        curr_row <= 0;
                        curr_col <= 0;
                        out_matrix_data <= 0; // 清空数据，准备新输入
                        timeout_cnt <= 0;
                        first_byte_rcvd <= 0;
                        
                        // 重置维度，避免在提前超时时使用旧值
                        out_dim_m <= 0;
                        out_dim_n <= 0;
                        total_elements_expected <= 0;
                    end
                end

                S_PARSE: begin
                    if (rx_done_tick) begin
                        first_byte_rcvd <= 1;
                        timeout_cnt <= 0; // 重置计时器
                        // 处理数字字符 '0'-'9'，累加数值
                        if (rx_byte >= ASCII_0 && rx_byte <= ASCII_9) begin
                            current_val <= current_val * 10 + (rx_byte - ASCII_0);
                            has_digits <= 1;
                        end 
                        // 处理负号 '-'
                        else if (rx_byte == ASCII_MINUS) begin
                            is_negative <= 1;
                        end
                        // 处理分隔符 (空格/换行)，意味着一个数值解析结束
                        else if (is_delimiter && has_digits) begin
                            
                            // 第1个数值：矩阵行数 M
                            if (parse_cnt == 0) begin
                                out_dim_m <= final_val[2:0];
                            end 
                            // 第2个数值：矩阵列数 N
                            else if (parse_cnt == 1) begin
                                out_dim_n <= final_val[2:0];
                                total_elements_expected <= final_val[2:0] * out_dim_m; // 计算总元素个数
                            end 
                            // 后续数值：矩阵元素数据
                            else begin
                                // 计算扁平化存储的索引位置并写入数据
                                // 索引 = (行 * 最大列数 + 列) * 数据位宽
                                out_matrix_data[(curr_row * MAX_N + curr_col) * DATA_WIDTH +: DATA_WIDTH] <= final_val;
                            
                                if (curr_col == out_dim_n - 1) begin
                                    curr_col <= 0;
                                    curr_row <= curr_row + 1;
                                end else begin
                                    curr_col <= curr_col + 1;
                                end
                            end

                            parse_cnt <= parse_cnt + 1;
                            current_val <= 0;
                            is_negative <= 0;
                            has_digits <= 0;
                            
                            // 检查是否接收完所有预期的数据
                            if (parse_cnt >= 2 && (parse_cnt - 1) == total_elements_expected) begin
                                state <= S_FINISH;
                            end
                        end
                    end else begin
                        // 超时检查
                        if (first_byte_rcvd) begin
                            if (timeout_cnt < TIMEOUT_VAL) begin
                                timeout_cnt <= timeout_cnt + 1;
                            end else begin
                                state <= S_FINISH; // 超时：结束接收，剩余数据保持为0
                            end
                        end
                    end
                end

                S_FINISH: begin
                    out_store_enable <= 1; 
                    done <= 1;             
                    state <= S_IDLE;       
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule