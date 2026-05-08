`timescale 1ns / 1ps

module matrix_generate #(
    parameter DATA_WIDTH = 16,//每个矩阵的每个元素的位宽
    parameter MAX_ROW = 5,//最大行数
    parameter MAX_COL = 5,//最大列数
    parameter TOTAL_BITS = MAX_ROW * MAX_COL * DATA_WIDTH//总位宽
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,//这个是generate功能的使能
    
    //用于控制生成范围，例如输入 9，表示生成 0~9
    input  wire [15:0] cfg_val_max,     
    //用户指令
    input  wire [2:0] in_dim_m,//用户要求生成得到矩阵行数
    input  wire [2:0] in_dim_n,//用户生成的矩阵的列数
    input  wire [1:0] in_count, // 1表示生成1个矩阵, 2表示生成2个矩阵

    //输出到 Storage
    output reg  done,//告诉top模块已经完成的信号
    output reg  [2:0] out_dim_m,    // 输出给 storage 的维度 M
    output reg  [2:0] out_dim_n,    // 输出给 storage 的维度 N
    output reg  [TOTAL_BITS-1:0] out_matrix_data, // 扁平化数据
    output reg  out_store_enable    // 写入触发信号，对应storage的in_en
);

    //1.实现了 LFSR 线性反馈移位寄存器来作为伪随机数生成器
    reg [15:0] lfsr_state;
    wire feedback;//反馈，即新生成的数字
    
    //这个数字是抽出了格子当中的第15，13，12，10号元素做异或，保证了65535以后才会重复
    assign feedback = lfsr_state[15] ^ lfsr_state[13] ^ lfsr_state[12] ^ lfsr_state[10];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            lfsr_state <= 16'hACE1; //给随机数的生成器初始了一个值
        else//时钟每跳动一次移动一次
            lfsr_state <= {lfsr_state[14:0], feedback};
    end

    wire [15:0] random_digit;
    assign random_digit = lfsr_state % 10; 
    //最后通过对10取余来实现生成的随机数是0 ~ 9

    
    //2. 状态机定义，定义出了以下五个状态
    localparam S_IDLE    = 0; //初始状态
    localparam S_FILL    = 1; // 逐个填充矩阵元素
    localparam S_STORE   = 2; // 将填充好的矩阵写入 Storage
    localparam S_CHECK   = 3; // 检查是否需要生成第 2 个
    localparam S_DONE    = 4; //完成状态

    reg [2:0] state;//当前的状态
    reg [2:0] r_cnt;//生成到了第几行
    reg [2:0] c_cnt;//生成到了第几列
    reg [1:0] generated_cnt; //已经生成并且存储了多少个矩阵，因为没做setting，所以最多2个


    //3. 最关键的生成随机矩阵并且存储起来
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            //复位所有寄存器
            state <= S_IDLE;
            done <= 0;
            out_store_enable <= 0;
            out_dim_m <= 0;
            out_dim_n <= 0;
            out_matrix_data <= 0;
            r_cnt <= 0;
            c_cnt <= 0;
            generated_cnt <= 0;
        end else begin
            // 默认脉冲拉低（防止持续处于写入状态）
            out_store_enable <= 0;
            //默认还未完成生成和写入
            done <= 0;

            case (state)
                S_IDLE: begin//从初始状态开始
                    if (start) begin
                        generated_cnt <= 0;//先清零已经产生的数量
                        // 锁存用户输入的维度，确保整个过程一致
                        out_dim_m <= in_dim_m;
                        out_dim_n <= in_dim_n;
                        
                        // 准备开始填充第一个矩阵，重置行列计数器
                        r_cnt <= 0;
                        c_cnt <= 0;
                        state <= S_FILL;
                    end
                end

                S_FILL: begin
                    //将当前随机数写入对应的扁平化位置
                    //使用对齐索引：Index = r * MAX_COL + c
                    //这里是一位一位生成的，一点一点填充矩阵，采用串入
                    out_matrix_data[(r_cnt * MAX_COL + c_cnt) * DATA_WIDTH +: DATA_WIDTH] <= random_digit;

                    //这个if判断用来更新行列计数
                    if (c_cnt == out_dim_n - 1) begin
                        c_cnt <= 0;
                        if (r_cnt == out_dim_m - 1) begin
                            // 填满了，准备存储
                            state <= S_STORE;
                        end else begin
                            r_cnt <= r_cnt + 1;
                        end
                    end else begin
                        c_cnt <= c_cnt + 1;
                    end
                end

                S_STORE: begin
                    // 发出写入信号
                    out_store_enable <= 1;
                    generated_cnt <= generated_cnt + 1;
                    state <= S_CHECK;
                end

                S_CHECK: begin
                    // 检查是否达到了用户要求的数量,这里对应的是按键按几下，最多是两个
                    if (generated_cnt < in_count) begin
                        // 还没够，重置计数器，生成下一个
                        r_cnt <= 0;
                        c_cnt <= 0;
                        // 这里 matrix_data 会在 S_FILL 过程中被新数据逐步覆盖
                        state <= S_FILL;
                    end else begin//如果满了则进入结束状态
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    done <= 1;
                    state <= S_IDLE;//重回初始状态
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule