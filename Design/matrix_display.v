`timescale 1ns / 1ps

module matrix_display #(
    parameter DATA_WIDTH = 16,          // 矩阵元素位宽：16位
    parameter MAX_ROW = 5,              // 最大行数：5行
    parameter MAX_COL = 5,              // 最大列数：5列
    parameter MAX_MATRIX_NUM = 16,      // 最大存储矩阵数量：16个
    parameter CLK_FREQ = 100_000_000,   // 系统时钟频率：100MHz
    parameter BAUD_RATE = 115200,       // UART波特率：115200
    parameter MAX_DISP_BITS = 1280      // 显示数据最大位宽，这里预留了8行10列，但是没有做setting，实际最多5行5列
)(
    input wire clk,                     // 系统时钟
    input wire rst_n,                   // 系统复位 (低电平有效)
    input wire start,                   // 开始信号 (高电平脉冲)
    

    //00: 计算显示模式，打印输入的矩阵数据，对应计算模块当中的显示
    //01: 总的显示模式，打印出现在storage里面储存了多少各种类型的矩阵
    //10: 计算模式里面打印出在storage里面转化好的相对id供用户选择
    //11: 没有用到这个空闲位，后面如果要加新功能可以加
    input wire [1:0] mode_select,             
    
    //用于计算显示模式
    input wire [MAX_DISP_BITS - 1:0] matrix_data, // 扁平化的矩阵数据输入
    input wire [3:0] row_num,           // 当前矩阵行数
    input wire [3:0] col_num,           // 当前矩阵列数
    input wire [3:0] data_stride,       //默认为5，因为在底层的存储板块都是按照5行5列储存的
    
    //用于统计模式
    //问storage我所需要display的行列的矩阵有多少个
    output reg [2:0] query_row,
    output reg [2:0] query_col,
    //符合当前查询尺寸的矩阵数量，由storage反馈过来
    input  wire [3:0] query_match_count, 

    //用于列表模式
    input wire [MAX_MATRIX_NUM-1:0] match_mask, //对应16个格子，1代表这个格子里面有矩阵
    output reg [3:0] read_id_req,               //请求读取的矩阵ID

    //状态输出
    output wire tx,     // UART 发送引脚
    output reg busy,    // 忙信号，高电平表示正在处理
    output reg done     // 完成信号，处理结束时产生一个脉冲
);

    // 1. UART 发送模块实例化
    reg [7:0] tx_data;  // 待发送的字节数据，一位一位串地发送
    reg tx_start;       // 发送开始信号
    wire tx_busy;       // UART 发送忙信号
    wire tx_done;       // UART 发送完成信号

    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uart_tx (
        .clk(clk),
        .rst_n(rst_n),
        .start(tx_start),
        .data(tx_data),
        .tx(tx),
        .busy(tx_busy),
        .done(tx_done)
    );


    // 2. 状态机定义
    localparam S_IDLE           = 0; // 空闲状态，等待 start 信号
    
    //通用状态：数值转换与发送 所有功能都会用到这个状态
    localparam S_CONVERT_BCD    = 1; // 将二进制数值转换为BCD码 (用于显示十进制)
    localparam S_SEND_SIGN      = 2; // 如果是负数，发送负号 '-'
    localparam S_WAIT_SIGN      = 3; // 等待负号发送完成
    localparam S_SEND_DIGITS    = 4; // 发送数字字符 (例如 '1', '2')
    localparam S_WAIT_DIGITS    = 5; // 等待数字发送完成
    
    //模式00：计算模式下的打印矩阵的模式 
    localparam S_DATA_FETCH     = 10; // 获取当前矩阵元素的值
    localparam S_DATA_DELIM     = 11; // 准备发送分隔符 (空格或回车)
    localparam S_DATA_WAIT_DELIM= 12; // 等待分隔符发送完成
    localparam S_DATA_LF        = 13; // 发送换行符 (行末)
    localparam S_DATA_WAIT_LF   = 14; // 等待换行符发送完成
    localparam S_DATA_NEXT      = 15; // 跳转到下一个元素
    
    //模式01：总的display模式来答应现在有多少各种类型的矩阵
    localparam S_SUM_SCAN_INIT  = 20; // 初始化扫描计数器
    localparam S_SUM_SCAN_ACC   = 21; // 累加当前尺寸的矩阵数量
    localparam S_SUM_SCAN_NEXT  = 22; // 切换到下一个尺寸 (行/列增加)
    localparam S_SUM_PRINT_TOTAL= 23; // 打印总数数值
    localparam S_SUM_SPACE_1    = 24; // 打印空格
    localparam S_SUM_RES_INIT   = 25; // (未使用)
    localparam S_SUM_RES_CHECK  = 26; // 检查当前尺寸是否有矩阵，准备打印详情
    localparam S_SUM_PRINT_M    = 27; // 打印行数 M
    localparam S_SUM_X1         = 28; // 打印乘号 '*'
    localparam S_SUM_PRINT_N    = 29; // 打印列数 N
    localparam S_SUM_X2         = 30; // 打印乘号 '*'
    localparam S_SUM_PRINT_CNT  = 31; // 打印该尺寸的数量
    localparam S_SUM_SPACE_2    = 32; // 打印空格
    localparam S_SUM_RES_NEXT   = 33; // 跳转到下一个尺寸详情

    //模式02：计算模式下面打印出来自storage的相对id
    localparam S_LIST_INIT      = 50; // 初始化列表扫描
    localparam S_LIST_CHECK     = 51; // 检查当前ID是否有效
    localparam S_LIST_PRINT_ID  = 52; // 打印矩阵ID
    localparam S_LIST_ID_LF     = 53; // 打印换行符
    localparam S_LIST_WAIT_DATA = 54; // 等待数据准备好 (用于后续可能的显示)
    localparam S_LIST_NEXT      = 55; // 跳转到下一个ID

    localparam S_DONE           = 40; // 完成状态

    reg [6:0] state;                   // 当前状态
    reg [6:0] return_state;
    //这个状态非常巧妙，能够减少消耗，它是标定了进入二进制到十进制的转化以后需要干什么，
    //由于这个二进制到十进制的转化在三个模式里面都需要经常使用，这个东西就像书签一样，
    //让你从某个模式出来做转化以后还能无缝衔接地继续这个模式
    reg [6:0] matrix_print_done_state;
    //这个状态和上面的那个状态很像，也起到书签的作用，主要用于计算模式下面要打印出多个矩阵
    //要反复从打印相对id的模式和打印矩阵的模式之间切换，所以这个是一个总的书签


    //3. 内部寄存器定义
    
    //矩阵遍历计数器，用来索引现在走到哪儿了
    reg [3:0] r_cnt; // 当前行索引
    reg [3:0] c_cnt; // 当前列索引
    
    //总的显示模式计数器
    reg [4:0] total_matrix_count; // 所有矩阵的总数
    
    //打印计算模式下的id的计数器
    reg [4:0] curr_scan_id;       // 当前扫描的物理ID (0-15)
    reg [4:0] relative_id_counter;// 相对ID计数器 (用于显示给用户 1, 2, 3...)

    //数值显示相关寄存器
    reg [15:0] current_val;     // 当前要显示的数值 (绝对值),即每一个格子里面储存的16bits数字
    reg is_negative;            // 当前数值是否为负，其实没用到，没做setting，不会出现负数
    reg [3:0] bcd_digits [0:4]; // 存储转换后的BCD码 (最大支持5位十进制数)，每格子4位，对应一个十进制数
    reg [2:0] digit_idx;        // 当前发送的数字索引，即stack的指针

    // 数据读取逻辑，即找到接下来要读的地方
    wire [7:0] current_read_addr;
    wire [15:0] raw_val;

    // 根据行、列和跨度计算读取地址
    assign current_read_addr = (r_cnt * data_stride) + c_cnt;
    // 从扁平化输入中提取当前元素
    assign raw_val = matrix_data[current_read_addr * DATA_WIDTH +: DATA_WIDTH];


    // 4. 主状态机逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位所有状态和寄存器
            state <= S_IDLE;
            busy <= 0;
            done <= 0;
            tx_start <= 0;
            tx_data <= 0;
            
            r_cnt <= 0;
            c_cnt <= 0;
            query_row <= 0;
            query_col <= 0;
            total_matrix_count <= 0;
            curr_scan_id <= 0;
            relative_id_counter <= 0;
            read_id_req <= 0;
            
            current_val <= 0;
            is_negative <= 0;
            digit_idx <= 0;
            return_state <= S_IDLE;
            matrix_print_done_state <= S_DONE;
        end else begin
            tx_start <= 0; // 默认拉低发送信号

            case (state)
                // --- 空闲状态 ---
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        busy <= 1; // 标记为忙
                        if (mode_select == 2'b01) begin
                            // 进入统计模式
                            state <= S_SUM_SCAN_INIT;
                        end else if (mode_select == 2'b10) begin
                            // 进入列表模式
                            state <= S_LIST_INIT;
                        end else begin
                            // 进入普通显示模式
                            r_cnt <= 0;
                            c_cnt <= 0;
                            matrix_print_done_state <= S_DONE; // 打印完后直接结束
                            state <= S_DATA_FETCH;
                        end
                    end else begin
                        busy <= 0; // 空闲
                    end
                end

                // ============================================================
                // 模式00，计算模式下面的打印出矩阵
                // ============================================================
                S_DATA_FETCH: begin
                    // 获取当前元素值并处理符号位
                    if (raw_val[15]) begin 
                        is_negative <= 1;
                        current_val <= ~raw_val + 1; // 负数取反加一得到绝对值
                    end else begin
                        is_negative <= 0;
                        current_val <= raw_val;
                    end
                    digit_idx <= 0;
                    return_state <= S_DATA_DELIM; //先规定好了在跳转之后回到哪里，即显示完数字后去发送分隔符
                    state <= S_CONVERT_BCD;       // 跳转到BCD转换
                end

                S_DATA_DELIM: begin
                    if (!tx_busy) begin
                        // 如果是列的最后一个元素，发送回车，否则发送空格
                        if (c_cnt == col_num - 1) begin
                            tx_data <= 8'h0D; // 回车,注意这里的回车只是起到把光标移动到行首的作用，要搭配LF才能换行
                            state <= S_DATA_WAIT_DELIM;
                        end else begin
                            tx_data <= 8'h20; //空格
                            state <= S_DATA_WAIT_DELIM;
                        end
                        tx_start <= 1;
                    end
                end

                S_DATA_WAIT_DELIM: begin
                    if (tx_done) begin
                        if (c_cnt == col_num - 1) 
                            state <= S_DATA_LF; // 行末需要补LF，这样才能换行
                        else 
                            state <= S_DATA_NEXT; // 继续下一个元素
                    end
                end

                S_DATA_LF: begin
                    if (!tx_busy) begin
                        tx_data <= 8'h0A; // LF
                        tx_start <= 1;
                        state <= S_DATA_WAIT_LF;
                    end
                end

                S_DATA_WAIT_LF: begin
                    if (tx_done) state <= S_DATA_NEXT;
                end

                S_DATA_NEXT: begin
                    // 坐标更新逻辑，双循环，串联的一个格子一个格子地打印出来
                    if (c_cnt == col_num - 1) begin
                        c_cnt <= 0;
                        if (r_cnt == row_num - 1) begin
                            state <= matrix_print_done_state; // 矩阵打印完成
                        end else begin
                            r_cnt <= r_cnt + 1;
                            state <= S_DATA_FETCH;
                        end
                    end else begin
                        c_cnt <= c_cnt + 1;
                        state <= S_DATA_FETCH;
                    end
                end

                // ============================================================
                // 模式01：总的display功能，打印出来现在storage里面储存了多少各种类型的矩阵
                // ============================================================
                
                // --- 第一阶段：扫描所有尺寸并计算总数 ---
                S_SUM_SCAN_INIT: begin
                    total_matrix_count <= 0;
                    query_row <= 1; // 从 1x1 开始扫描
                    query_col <= 1;
                    state <= S_SUM_SCAN_ACC;
                end

                S_SUM_SCAN_ACC: begin
                    // 累加当前尺寸的矩阵数量
                    total_matrix_count <= total_matrix_count + query_match_count;
                    state <= S_SUM_SCAN_NEXT;
                end

                S_SUM_SCAN_NEXT: begin
                    //双层循环，从1*1，1*2一直到5*5
                    // 遍历所有可能的尺寸 (MAX_ROW x MAX_COL)
                    if (query_col == MAX_COL) begin
                        query_col <= 1;
                        if (query_row == MAX_ROW) begin
                            // 扫描完成，开始打印总数
                            state <= S_SUM_PRINT_TOTAL;
                        end else begin
                            query_row <= query_row + 1;
                            state <= S_SUM_SCAN_ACC;
                        end
                    end else begin
                        query_col <= query_col + 1;
                        state <= S_SUM_SCAN_ACC;
                    end
                end

                // --- 第二阶段：打印总数 ---
                S_SUM_PRINT_TOTAL: begin
                    current_val <= {11'b0, total_matrix_count};
                    is_negative <= 0;
                    digit_idx <= 0;
                    return_state <= S_SUM_SPACE_1;
                    state <= S_CONVERT_BCD;
                end

                S_SUM_SPACE_1: begin
                    if (!tx_busy) begin
                        tx_data <= 8'h20; // 打印空格
                        tx_start <= 1;
                        // 重置查询坐标，准备打印详细列表
                        query_row <= 1;
                        query_col <= 1;
                        state <= S_SUM_RES_CHECK; 
                    end else begin
                        // 等待 UART 空闲
                    end
                    
                    if (tx_start) begin
                        state <= S_SUM_RES_CHECK;
                    end
                end

                // --- 第三阶段：打印详细列表 (M*N*Count) ---
                S_SUM_RES_CHECK: begin
                    if (tx_done || (!tx_busy && !tx_start)) begin
                        if (query_match_count > 0) begin
                            // 如果该尺寸有矩阵，则打印 "M*N*Count "
                            state <= S_SUM_PRINT_M;
                        end else begin
                            state <= S_SUM_RES_NEXT;
                        end
                    end
                end
                //打印M
                S_SUM_PRINT_M: begin
                    current_val <= {13'b0, query_row}; // 打印行数
                    is_negative <= 0;
                    digit_idx <= 0;
                    return_state <= S_SUM_X1;
                    state <= S_CONVERT_BCD;
                end
                //打印*
                S_SUM_X1: begin
                    if (!tx_busy) begin
                        tx_data <= 8'h2A; // '*'
                        tx_start <= 1;
                        state <= S_SUM_PRINT_N;
                    end
                end
                //打印N
                S_SUM_PRINT_N: begin
                    if (tx_done) begin
                        current_val <= {13'b0, query_col}; // 打印列数
                        is_negative <= 0;
                        digit_idx <= 0;
                        return_state <= S_SUM_X2;
                        state <= S_CONVERT_BCD;
                    end
                end
                //打印*
                S_SUM_X2: begin
                    if (!tx_busy) begin
                        tx_data <= 8'h2A; // '*'
                        tx_start <= 1;
                        state <= S_SUM_PRINT_CNT;
                    end
                end
                //打印个数
                S_SUM_PRINT_CNT: begin
                    if (tx_done) begin
                        current_val <= {12'b0, query_match_count}; // 打印数量
                        is_negative <= 0;
                        digit_idx <= 0;
                        return_state <= S_SUM_SPACE_2;
                        state <= S_CONVERT_BCD;
                    end
                end
                //打印空格
                S_SUM_SPACE_2: begin
                    if (!tx_busy) begin
                        tx_data <= 8'h20; // Space
                        tx_start <= 1;
                        state <= S_SUM_RES_NEXT;
                    end
                end

                S_SUM_RES_NEXT: begin
                    if (tx_done || (!tx_busy && !tx_start)) begin
                        // 遍历下一个尺寸
                        if (query_col == MAX_COL) begin
                            query_col <= 1;
                            if (query_row == MAX_ROW) begin
                                state <= S_DONE; // 全部打印完成
                            end else begin
                                query_row <= query_row + 1;
                                state <= S_SUM_RES_CHECK;
                            end
                        end else begin
                            query_col <= query_col + 1;
                            state <= S_SUM_RES_CHECK;
                        end
                    end
                end

                // ============================================================
                // 模式10：计算模式下面打印相对id的模式
                // ============================================================
                S_LIST_INIT: begin
                    // 初始化列表扫描
                    query_row <= row_num; // (此处可能未使用，仅作初始化)
                    query_col <= col_num;
                    relative_id_counter <= 1; // 用户看到的ID从1开始
                    curr_scan_id <= 0;        // 物理ID从0开始
                    state <= S_LIST_CHECK;
                end

                S_LIST_CHECK: begin
                    // 检查当前物理ID是否有效 (match_mask对应位为1)
                    //这个点在storage里面有做标记，是1则这个地方有要的类型的矩阵，0则是没有
                    if (match_mask[curr_scan_id]) begin
                        state <= S_LIST_PRINT_ID;
                    end else begin
                        state <= S_LIST_NEXT;
                    end
                end

                S_LIST_PRINT_ID: begin
                    // 打印相对ID
                    current_val <= {11'b0, relative_id_counter}; 
                    is_negative <= 0;
                    digit_idx <= 0;
                    return_state <= S_LIST_ID_LF;
                    state <= S_CONVERT_BCD;
                end

                S_LIST_ID_LF: begin
                    if (!tx_busy) begin
                        tx_data <= 8'h0A; // LF (ID后换行)
                        tx_start <= 1;
                        state <= S_LIST_WAIT_DATA;
                    end
                end

                S_LIST_WAIT_DATA: begin
                    if (tx_done) begin
                        // 请求读取该ID的数据 (虽然列表模式可能只显示ID，但这里保留了读取数据的逻辑)
                        read_id_req <= curr_scan_id[3:0];
                        relative_id_counter <= relative_id_counter + 1;
                        
                        // 准备进入数据打印模式 (如果需要打印矩阵内容的话)
                        // 这里逻辑是：打印完ID后，去打印该矩阵的内容
                        r_cnt <= 0;
                        c_cnt <= 0;
                        matrix_print_done_state <= S_LIST_NEXT; // 打印完内容后回到列表扫描
                        
                        state <= S_DATA_FETCH; 
                    end
                end

                S_LIST_NEXT: begin
                    // 检查是否扫描完所有存储位置
                    if (curr_scan_id == MAX_MATRIX_NUM - 1) begin
                        state <= S_DONE;
                    end else begin
                        curr_scan_id <= curr_scan_id + 1;
                        state <= S_LIST_CHECK;
                    end
                end

                // ============================================================
                // 通用子程序：BCD转换与数值发送
                // ============================================================
                //实现拆分的逻辑：每次用%10现在的值提取个位，然后右移一位来更新个位
                S_CONVERT_BCD: begin
                    // 将二进制数值转换为BCD码 (逐位提取)
                    if (current_val == 0 && digit_idx == 0) begin
                        bcd_digits[0] <= 0; // 数值为0的情况
                        digit_idx <= 0; 
                        state <= S_SEND_SIGN;
                    end
                    else if (current_val > 0) begin
                        bcd_digits[digit_idx] <= current_val % 10; // 取个位
                        current_val <= current_val / 10;           // 右移一位
                        digit_idx <= digit_idx + 1;
                    end 
                    else begin
                        // 转换完成，调整索引指向最高位
                        if (digit_idx > 0) digit_idx <= digit_idx - 1; 
                        state <= S_SEND_SIGN;
                    end
                end

                //没有用到，没有做setting，不会出现负数
                S_SEND_SIGN: begin
                    if (is_negative) begin
                        if (!tx_busy) begin
                            tx_data <= 8'h2D; // '-'
                            tx_start <= 1;
                            state <= S_WAIT_SIGN;
                        end
                    end else begin
                        state <= S_SEND_DIGITS;
                    end
                end

                S_WAIT_SIGN: begin
                    if (tx_done) state <= S_SEND_DIGITS;
                end

                //这里的逻辑很像stack，进入的时候是从LSB开始的，十进制最低位的4bits先进去，直到最高位
                //出来的时候指针先指着最高位出来，在一步一步往下移动到最低位置
                S_SEND_DIGITS: begin
                    if (!tx_busy) begin
                        tx_data <= {4'b0011, bcd_digits[digit_idx]}; // 转换为ASCII码 ('0'-'9')
                        //在bcd码前面补上0011就是ASCII码
                        tx_start <= 1;
                        state <= S_WAIT_DIGITS;
                    end
                end

                S_WAIT_DIGITS: begin
                    if (tx_done) begin
                        if (digit_idx == 0) begin
                            state <= return_state; // 所有位发送完毕，返回调用者
                        end else begin
                            digit_idx <= digit_idx - 1; // 发送下一位
                            state <= S_SEND_DIGITS;
                        end
                    end
                end

                // --- 完成状态 ---
                S_DONE: begin
                    busy <= 0;
                    done <= 1; // 产生完成脉冲
                    state <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
