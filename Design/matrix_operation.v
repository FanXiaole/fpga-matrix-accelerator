`timescale 1ns / 1ps

module matrix_operation #(
    parameter DATA_WIDTH = 16,
    parameter MAX_ROW    = 5,
    parameter MAX_COL    = 5,
    parameter TOTAL_BITS = MAX_ROW * MAX_COL * DATA_WIDTH,

    // 卷积运算的固定尺寸参数 (Bonus功能)
    parameter CONV_IN_H  = 10, // 输入图像高度
    parameter CONV_IN_W  = 12, // 输入图像宽度
    parameter CONV_K     = 3,  // 卷积核大小 (3x3)
    parameter CONV_OUT_H = CONV_IN_H - CONV_K + 1, // 输出高度: 8
    parameter CONV_OUT_W = CONV_IN_W - CONV_K + 1  // 输出宽度: 10
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    // 操作类型选择:
    // 0: 转置 (Transpose)
    // 1: 加法 (Add)
    // 2: 标量乘法 (Scalar Multiply)
    // 3: 矩阵乘法 (Matrix Multiply)
    // 4: 卷积 (Convolution - Bonus)
    input  wire [2:0] op_type, 

    // --- 存储模块输入的操作数 ---
    input  wire [TOTAL_BITS-1:0] mat_A_data, // 矩阵A数据
    input  wire [2:0]            mat_A_row,  // 矩阵A行数
    input  wire [2:0]            mat_A_col,  // 矩阵A列数
    input  wire [TOTAL_BITS-1:0] mat_B_data, // 矩阵B数据
    input  wire [2:0]            mat_B_row,  // 矩阵B行数
    input  wire [2:0]            mat_B_col,  // 矩阵B列数
    input  wire [15:0]           scalar_val, // 标量值 (用于操作2)

    // --- 普通运算结果输出 (用于写回存储) ---
    output reg                   done,         // 运算完成信号
    output reg  [2:0]            res_row,      // 结果矩阵行数
    output reg  [2:0]            res_col,      // 结果矩阵列数
    output reg  [TOTAL_BITS-1:0] res_data,     // 结果矩阵数据
    output reg                   res_store_en, // 结果存储使能

    // --- Bonus 周期计数器 (统计卷积运算周期数) ---
    output reg  [31:0]           bonus_cycle_cnt,

    // ============================================================
    // 错误/有效性标志 (如果外部已检查可忽略)
    // ============================================================
    output reg                   op_invalid,    // 操作无效标志
    output reg  [3:0]            op_error_code, // 错误代码

    // ============================================================
    // 卷积输出接口 (8x10) - 完整Bonus功能所需
    // 流式输出: 每计算出一个像素点，产生一个脉冲
    // ============================================================
    output reg                   conv_out_valid, // 输出有效
    output reg  [3:0]            conv_out_r,     // 当前输出像素行索引 (0..7)
    output reg  [3:0]            conv_out_c,     // 当前输出像素列索引 (0..9)
    output reg  signed [15:0]    conv_out_val,   // 当前输出像素值
    output reg                   conv_out_last,  // 最后一个像素标志 (7,9)
    output reg  [3:0]            conv_out_rows,  // 输出总行数 (8)
    output reg  [3:0]            conv_out_cols,  // 输出总列数 (10)

    // 可选: 扁平化的完整卷积结果矩阵 (行优先, 跨度=CONV_OUT_W)
    output reg  [DATA_WIDTH*CONV_OUT_H*CONV_OUT_W-1:0] conv_matrix_flat
);

    // ============================================================
    // 0) 启动脉冲检测与输入锁存 (避免计算中途输入变化)
    // ============================================================
    reg start_d;
    wire start_pulse = start & ~start_d; // 上升沿检测

    reg [2:0] op_latched;
    reg [2:0] A_row_l, A_col_l, B_row_l, B_col_l;
    reg signed [15:0] scalar_l;
    reg [TOTAL_BITS-1:0] mat_A_data_scalar_l;   // 仅用于 op2 标量乘法的A矩阵锁存


    // ============================================================
    // 1) 状态机定义
    // ============================================================
    localparam S_IDLE = 2'd0; // 空闲
    localparam S_CALC = 2'd1; // 计算中
    localparam S_DONE = 2'd2; // 完成

    reg [1:0] state;

    // 索引计数器
    reg [3:0] r_idx, c_idx, k_idx; // 足够用于卷积 (r最大7, c最大9, k最大8)

    // 累加器
    reg signed [63:0] acc;          // 安全累加器 (防止溢出)
    
    reg signed [63:0] acc_next;


    // 乘法操作数与结果
    reg  signed [15:0] mult_op1, mult_op2;
    wire signed [31:0] prod_comb;
    
    // 卷积核索引映射
    reg [1:0] kr, kc;

    // ============================================================
    // 2) 辅助函数: 获取矩阵元素 (存储格式为 5x5 扁平化)
    // ============================================================
    // 形象解释：
    // 想象 mat_A_data 是一个长条形的“磁带”，里面按顺序录制了矩阵的每一行。
    // 比如 5x5 矩阵，磁带上前5段是第0行，接下来的5段是第1行...
    // 当我们需要第 r 行、第 c 列的数据时，不能直接告诉磁带“给我(r,c)”，
    // 必须算出它在磁带上的具体位置（索引）。
    // 公式：位置 = (行号 r * 每行长度 MAX_COL) + 列号 c
    // 这里的 +: DATA_WIDTH 语法就是从算出的位置开始，剪下 DATA_WIDTH 长度的一段数据。
    function signed [15:0] get_A;
        input [2:0] r, c;
        begin
            get_A = mat_A_data[(r * MAX_COL + c) * DATA_WIDTH +: DATA_WIDTH];
        end
    endfunction

    function signed [15:0] get_B;
        input [2:0] r, c;
        begin
            get_B = mat_B_data[(r * MAX_COL + c) * DATA_WIDTH +: DATA_WIDTH];
        end
    endfunction

    // ============================================================
    // 3) Bonus ROM 图像 (10x12), 像素值 0..9
    // ============================================================
    // 形象解释：
    // 这是一个“内置测试图库”。
    // 就像游戏里的“预设关卡”一样，为了在答辩时稳定展示卷积（滤镜）效果，
    // 我们没有让用户手动输入这 120 个像素点（太慢且容易错），
    // 而是直接把一张 10x12 的“数字图片”写死在芯片里。
    // 卷积核（矩阵A）就像一个放大镜，在这张固定的图片上滑动计算。
    reg [3:0] rom_image [0:CONV_IN_H*CONV_IN_W-1];

    initial begin
        // Row 0
        rom_image[0]=3;  rom_image[1]=7;  rom_image[2]=2;  rom_image[3]=9;
        rom_image[4]=0;  rom_image[5]=5;  rom_image[6]=1;  rom_image[7]=8;
        rom_image[8]=4;  rom_image[9]=6;  rom_image[10]=3; rom_image[11]=2;
        // Row 1
        rom_image[12]=8; rom_image[13]=1; rom_image[14]=6; rom_image[15]=4;
        rom_image[16]=7; rom_image[17]=3; rom_image[18]=9; rom_image[19]=0;
        rom_image[20]=5; rom_image[21]=2; rom_image[22]=8; rom_image[23]=1;
        // Row 2
        rom_image[24]=4; rom_image[25]=9; rom_image[26]=0; rom_image[27]=2;
        rom_image[28]=6; rom_image[29]=8; rom_image[30]=3; rom_image[31]=5;
        rom_image[32]=7; rom_image[33]=1; rom_image[34]=4; rom_image[35]=9;
        // Row 3
        rom_image[36]=7; rom_image[37]=3; rom_image[38]=8; rom_image[39]=5;
        rom_image[40]=1; rom_image[41]=4; rom_image[42]=9; rom_image[43]=2;
        rom_image[44]=0; rom_image[45]=6; rom_image[46]=7; rom_image[47]=3;
        // Row 4
        rom_image[48]=2; rom_image[49]=6; rom_image[50]=4; rom_image[51]=0;
        rom_image[52]=8; rom_image[53]=7; rom_image[54]=5; rom_image[55]=3;
        rom_image[56]=1; rom_image[57]=9; rom_image[58]=2; rom_image[59]=4;
        // Row 5
        rom_image[60]=9; rom_image[61]=0; rom_image[62]=7; rom_image[63]=3;
        rom_image[64]=5; rom_image[65]=2; rom_image[66]=8; rom_image[67]=6;
        rom_image[68]=4; rom_image[69]=1; rom_image[70]=9; rom_image[71]=0;
        // Row 6
        rom_image[72]=5; rom_image[73]=8; rom_image[74]=1; rom_image[75]=6;
        rom_image[76]=4; rom_image[77]=9; rom_image[78]=2; rom_image[79]=7;
        rom_image[80]=3; rom_image[81]=0; rom_image[82]=5; rom_image[83]=8;
        // Row 7
        rom_image[84]=1; rom_image[85]=4; rom_image[86]=9; rom_image[87]=2;
        rom_image[88]=7; rom_image[89]=0; rom_image[90]=6; rom_image[91]=8;
        rom_image[92]=5; rom_image[93]=3; rom_image[94]=1; rom_image[95]=4;
        // Row 8
        rom_image[96]=6; rom_image[97]=2; rom_image[98]=5; rom_image[99]=8;
        rom_image[100]=3; rom_image[101]=1; rom_image[102]=7; rom_image[103]=4;
        rom_image[104]=9; rom_image[105]=0; rom_image[106]=6; rom_image[107]=2;
        // Row 9
        rom_image[108]=0; rom_image[109]=7; rom_image[110]=3; rom_image[111]=9;
        rom_image[112]=5; rom_image[113]=6; rom_image[114]=4; rom_image[115]=1;
        rom_image[116]=8; rom_image[117]=2; rom_image[118]=0; rom_image[119]=7;
    end

    function signed [15:0] get_rom_pixel;
        input [3:0] r, c;
        begin
            // 将4位像素值零扩展为16位有符号数
            get_rom_pixel = {12'd0, rom_image[r * CONV_IN_W + c]};
        end
    endfunction

    // ============================================================
    // 4) 维度有效性检查 (在启动时锁存)
    // error_code:
    //   1: 加法维度不匹配
    //   2: 矩阵乘法维度不匹配
    //   3: 卷积核必须是 3x3
    // ============================================================
    wire add_ok    = (A_row_l == B_row_l) && (A_col_l == B_col_l);
    wire matmul_ok = (A_col_l == B_row_l);
    wire conv_ok   = (A_row_l == 3) && (A_col_l == 3);

    // ============================================================
    // 5) 主时序逻辑
    // ============================================================
    // 形象解释：
    // 这是整个模块的“大脑”和“指挥官”。
    // 它是一个状态机（FSM），像一个严格的厨师：
    // 1. S_IDLE (备菜): 等待订单 (start)，一旦来了，就把所有食材 (输入数据) 锁进柜子 (寄存器)，防止中途变质 (变化)。
    //    同时检查菜谱 (维度检查)，如果不对直接退单 (报错)。
    // 2. S_CALC (烹饪): 根据不同的菜谱 (op_type)，一步步切菜、下锅 (计算)。
    //    比如矩阵乘法，就是一层层循环地切 (r, c, k 循环)。
    // 3. S_DONE (上菜): 做好了，按铃 (done)，把菜端出去 (res_data)。
    integer idx;


      always @(*) begin
        // 这里的逻辑是“纯组合逻辑”，就像一个没有记忆的计算器。
        // 只要输入变了，输出立马变。我们在这里准备乘法器的两个输入数。
        mult_op1 = 16'sd0;
        mult_op2 = 16'sd0;
        // 仅在计算状态为 Op2 或 Op3 时准备操作数
        if (state == S_CALC) begin
            if (op_latched == 3'd2) begin      // 标量乘法
                    // 标量乘法：矩阵元素 x 标量值
                    mult_op1 = mat_A_data_scalar_l[(r_idx * MAX_COL + c_idx) * DATA_WIDTH +: DATA_WIDTH];
                    mult_op2 = scalar_l;
            end else if (op_latched == 3'd3) begin // 矩阵乘法
                // 矩阵乘法：A的行元素 x B的列元素
                mult_op1 = get_A(r_idx[2:0], k_idx[2:0]);
                mult_op2 = get_B(k_idx[2:0], c_idx[2:0]);
            end
        end
    end

    // 硬件乘法器：这里会综合成 DSP 单元或者逻辑乘法器
    assign prod_comb = mult_op1 * mult_op2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_d         <= 1'b0;

            state           <= S_IDLE;
            done            <= 1'b0;
            res_store_en    <= 1'b0;

            mat_A_data_scalar_l <= {TOTAL_BITS{1'b0}};

            res_row         <= 3'd0;
            res_col         <= 3'd0;
            res_data        <= {TOTAL_BITS{1'b0}};

            op_latched      <= 3'd0;
            A_row_l         <= 3'd0; A_col_l <= 3'd0;
            B_row_l         <= 3'd0; B_col_l <= 3'd0;
            scalar_l        <= 16'sd0;

            r_idx           <= 4'd0; c_idx <= 4'd0; k_idx <= 4'd0;
            acc             <= 64'sd0;

            bonus_cycle_cnt <= 32'd0;

            op_invalid      <= 1'b0;
            op_error_code   <= 4'd0;

            conv_out_valid  <= 1'b0;
            conv_out_r      <= 4'd0;
            conv_out_c      <= 4'd0;
            conv_out_val    <= 16'sd0;
            conv_out_last   <= 1'b0;
            conv_out_rows   <= CONV_OUT_H[3:0];
            conv_out_cols   <= CONV_OUT_W[3:0];
            conv_matrix_flat<= {(DATA_WIDTH*CONV_OUT_H*CONV_OUT_W){1'b0}};

            kr              <= 2'd0;
            kc              <= 2'd0;
        end else begin
            // 默认脉冲拉低
            start_d        <= start;
            done           <= 1'b0;
            res_store_en   <= 1'b0;

            conv_out_valid <= 1'b0;
            conv_out_last  <= 1'b0;

            // 保持固定的卷积输出维度
            conv_out_rows  <= CONV_OUT_H[3:0];
            conv_out_cols  <= CONV_OUT_W[3:0];

            case (state)
                // ------------------------------------------------
                // IDLE: 等待启动脉冲，锁存所有输入
                // ------------------------------------------------
                // 详细注释：
                // 这是状态机的初始状态。
                // 只要 start_pulse 没来，就一直在这里转圈。
                // 一旦 start_pulse 来了：
                // 1. 锁存 (Latch): 把所有输入信号存入内部寄存器 (如 A_row_l)。
                //    这是为了保证计算过程中，即使外部输入变了，内部计算用的数还是原来的，确保稳定。
                // 2. 预设结果维度: 根据操作类型，提前算好结果矩阵是几行几列。
                // 3. 维度检查: 比如加法要求两个矩阵一样大，乘法要求 A列=B行。
                //    如果检查不通过，直接跳到 DONE 状态并报错，不进行计算。
                S_IDLE: begin
                    if (start_pulse) begin
                        op_latched    <= op_type;

                        A_row_l       <= mat_A_row;
                        A_col_l       <= mat_A_col;
                        B_row_l       <= mat_B_row;
                        B_col_l       <= mat_B_col;
                        scalar_l      <= scalar_val;

                        if (op_type == 3'd2) begin
                            mat_A_data_scalar_l <= mat_A_data; // 只对标量乘法锁存A，避免中途被外部读口切换影响
                        end


                        r_idx         <= 4'd0;
                        c_idx         <= 4'd0;
                        k_idx         <= 4'd0;
                        acc           <= 64'sd0;

                        bonus_cycle_cnt <= 32'd0;
                        res_data        <= {TOTAL_BITS{1'b0}};
                        conv_matrix_flat<= {(DATA_WIDTH*CONV_OUT_H*CONV_OUT_W){1'b0}};

                        op_invalid    <= 1'b0;
                        op_error_code <= 4'd0;

                        // 设置结果维度 (仅对 Op 0..3 有意义)
                        case (op_type)
                            3'd0: begin res_row <= mat_A_col; res_col <= mat_A_row; end // 转置
                            3'd1: begin res_row <= mat_A_row; res_col <= mat_A_col; end // 加法
                            3'd2: begin res_row <= mat_A_row; res_col <= mat_A_col; end // 标量乘法
                            3'd3: begin res_row <= mat_A_row; res_col <= mat_B_col; end // 矩阵乘法
                            default: begin res_row <= 3'd0;   res_col <= 3'd0;   end    // 卷积或其他
                        endcase

                        // 有效性检查 (锁存的维度在下一个周期可用，但也可以用当前输入快速检查)
                        if (op_type == 3'd1) begin
                            if (!((mat_A_row == mat_B_row) && (mat_A_col == mat_B_col))) begin
                                op_invalid    <= 1'b1;
                                op_error_code <= 4'd1;
                                state         <= S_DONE; // 立即结束
                            end else begin
                                state <= S_CALC;
                            end
                        end else if (op_type == 3'd3) begin
                            if (!(mat_A_col == mat_B_row)) begin
                                op_invalid    <= 1'b1;
                                op_error_code <= 4'd2;
                                state         <= S_DONE;
                            end else begin
                                state <= S_CALC;
                            end
                        end else if (op_type == 3'd4) begin
                            // 卷积期望 A 是 3x3 的核
                            if (!((mat_A_row == 3) && (mat_A_col == 3))) begin
                                op_invalid    <= 1'b1;
                                op_error_code <= 4'd3;
                                state         <= S_DONE;
                            end else begin
                                state <= S_CALC;
                            end
                        end else begin
                            state <= S_CALC;
                        end
                    end
                end

                // ------------------------------------------------
                // CALC: 每个周期执行一个微步
                // ------------------------------------------------
                // 详细注释：
                // 这是最忙碌的状态。每个时钟周期，它都会根据 op_latched (操作类型) 做一点点计算。
                // 就像流水线一样，每次只处理一个元素或一个步骤。
                // 核心逻辑是使用 r_idx (行), c_idx (列) 遍历整个结果矩阵。
                S_CALC: begin
                    // Op 4 计数器保持不变
                    if (op_latched == 3'd4)
                        bonus_cycle_cnt <= bonus_cycle_cnt + 1;

                    // Op 0 (转置) ... 保持原样 ...
                    if (op_latched == 3'd0) begin
                        // 转置就是“行列互换”。
                        // 我们读取 A 的 (c, r) 位置，写入结果的 (r, c) 位置。
                        res_data[(r_idx * MAX_COL + c_idx) * DATA_WIDTH +: DATA_WIDTH]
                            <= get_A(c_idx[2:0], r_idx[2:0]);
                        // ... 坐标跳转逻辑保持原样 ...
                        if (c_idx == (A_row_l - 1)) begin
                            c_idx <= 4'd0;
                            if (r_idx == (A_col_l - 1)) state <= S_DONE;
                            else r_idx <= r_idx + 1;
                        end else begin
                            c_idx <= c_idx + 1;
                        end
                    end

                    // Op 1 (加法) ... 保持原样 ...
                    else if (op_latched == 3'd1) begin
                        // 加法最简单：对应位置相加。
                        res_data[(r_idx * MAX_COL + c_idx) * DATA_WIDTH +: DATA_WIDTH]
                            <= (get_A(r_idx[2:0], c_idx[2:0]) + get_B(r_idx[2:0], c_idx[2:0]));
                        // ... 坐标跳转逻辑保持原样 ...
                        if (c_idx == (A_col_l - 1)) begin
                            c_idx <= 4'd0;
                            if (r_idx == (A_row_l - 1)) state <= S_DONE;
                            else r_idx <= r_idx + 1;
                        end else begin
                            c_idx <= c_idx + 1;
                        end
                    end

                    // ============================================================
                    // 【修改 3】: 修复 Op 2 和 Op 3 的逻辑 (无饱和，直接截断)
                    // ============================================================
                    
                    // -------- op 2: 标量乘法 --------
                    else if (op_latched == 3'd2) begin
                        // 这里的 prod_comb 已经在上面的组合逻辑里算好了 (A[r][c] * scalar)。
                        // 我们直接取低16位结果存进去。
                        res_data[(r_idx * MAX_COL + c_idx) * DATA_WIDTH +: DATA_WIDTH]
                            <= prod_comb[15:0];

                        // 坐标更新逻辑
                        if (c_idx == (A_col_l - 1)) begin
                            c_idx <= 4'd0;
                            if (r_idx == (A_row_l - 1)) begin
                                state <= S_DONE;
                            end else begin
                                r_idx <= r_idx + 1;
                            end
                        end else begin
                            c_idx <= c_idx + 1;
                        end
                    end

                    // -------- op 3: 矩阵乘法 --------
                    else if (op_latched == 3'd3) begin
                        // 矩阵乘法核心：行乘列，求和。
                        // k_idx 是第三层循环，负责遍历 A 的行和 B 的列。
                        // acc 是累加器，就像购物车，把算出来的乘积一个个扔进去加起来。
                        if (k_idx == 0)
                            acc <= {{32{prod_comb[31]}}, prod_comb}; // 第一个数，直接存入 (注意符号扩展)
                        else
                            acc <= acc + {{32{prod_comb[31]}}, prod_comb}; // 后面的数，累加

                        // 结果写回逻辑
                        if (k_idx == (A_col_l - 1)) begin
                            // 这一行算完了 (k循环结束)！
                            // Look-ahead 写入：因为时序逻辑慢一拍，我们把 (当前acc + 最后一个乘积) 写入结果。
                            if (k_idx == 0) begin
                                // 特殊情况：如果维度是1，直接写乘积
                                res_data[(r_idx * MAX_COL + c_idx) * DATA_WIDTH +: DATA_WIDTH] 
                                    <= prod_comb[15:0];
                            end else begin
                                // 正常情况：累加器 + 当前乘积
                                res_data[(r_idx * MAX_COL + c_idx) * DATA_WIDTH +: DATA_WIDTH] 
                                    <= acc[15:0] + prod_comb[15:0];
                            end

                            // 重置 k 和 acc，准备算下一个格子的值
                            k_idx <= 4'd0;
                            acc <= 64'sd0;

                            // 坐标更新逻辑 (r, c)
                            if (c_idx == (B_col_l - 1)) begin
                                c_idx <= 4'd0;
                                if (r_idx == (A_row_l - 1)) begin
                                    state <= S_DONE;
                                end else begin
                                    r_idx <= r_idx + 1;
                                end
                            end else begin
                                c_idx <= c_idx + 1;
                            end
                        end else begin
                            k_idx <= k_idx + 1; // k 还没跑完，继续跑
                        end
                    end

                    // -------- op 4: 卷积 (Bonus) --------
                    else if (op_latched == 3'd4) begin
                        // 卷积就是拿一个 3x3 的小窗口 (Kernel) 在大图上滑动。
                        // k_idx 从 0 到 8，代表 3x3 窗口里的 9 个格子。
                        // 映射 k_idx (0..8) -> (kr,kc) 无需除法
                        case (k_idx)
                            4'd0: begin kr <= 2'd0; kc <= 2'd0; end
                            4'd1: begin kr <= 2'd0; kc <= 2'd1; end
                            4'd2: begin kr <= 2'd0; kc <= 2'd2; end
                            4'd3: begin kr <= 2'd1; kc <= 2'd0; end
                            4'd4: begin kr <= 2'd1; kc <= 2'd1; end
                            4'd5: begin kr <= 2'd1; kc <= 2'd2; end
                            4'd6: begin kr <= 2'd2; kc <= 2'd0; end
                            4'd7: begin kr <= 2'd2; kc <= 2'd1; end
                            default: begin kr <= 2'd2; kc <= 2'd2; end // 8
                        endcase

                        // 注意: kr/kc 是非阻塞更新，所以直接使用 "当前 k_idx" 映射进行算术运算:
                        // 我们通过第二个 case 组合逻辑到临时变量。
                        begin : CONV_COMB
                            reg [1:0] tkr, tkc;
                            reg signed [15:0] kval, pval;
                            reg signed [31:0] tprod;
                            reg signed [63:0] tacc_next;
                            integer out_index;

                            case (k_idx)
                                4'd0: begin tkr=0; tkc=0; end
                                4'd1: begin tkr=0; tkc=1; end
                                4'd2: begin tkr=0; tkc=2; end
                                4'd3: begin tkr=1; tkc=0; end
                                4'd4: begin tkr=1; tkc=1; end
                                4'd5: begin tkr=1; tkc=2; end
                                4'd6: begin tkr=2; tkc=0; end
                                4'd7: begin tkr=2; tkc=1; end
                                default: begin tkr=2; tkc=2; end
                            endcase

                            // 从 A 获取卷积核 (3x3 位于 5x5 存储的左上角)
                            kval = get_A({1'b0,tkr}, {1'b0,tkc});
                            // 从 ROM 图像获取像素 (r+kr, c+kc)
                            pval = get_rom_pixel(r_idx + tkr, c_idx + tkc);

                            tprod     = $signed(kval) * $signed(pval);
                            tacc_next = (k_idx == 0) ? $signed(tprod) : (acc + $signed(tprod));

                            acc <= tacc_next;

                            if (k_idx == 4'd8) begin
                                // 发送该像素的流式输出
                                conv_out_valid <= 1'b1;
                                conv_out_r     <= r_idx;
                                conv_out_c     <= c_idx;
                                conv_out_val   <= tacc_next[15:0];
                                conv_out_last  <= (r_idx == (CONV_OUT_H-1)) && (c_idx == (CONV_OUT_W-1));

                                // 同时打包到 conv_matrix_flat (行优先)
                                out_index = (r_idx * CONV_OUT_W + c_idx);
                                conv_matrix_flat[out_index*DATA_WIDTH +: DATA_WIDTH] <= tacc_next[15:0];

                                // 移动到下一个输出像素
                                k_idx <= 4'd0;
                                acc   <= 64'sd0;

                                if (c_idx == (CONV_OUT_W-1)) begin
                                    c_idx <= 4'd0;
                                    if (r_idx == (CONV_OUT_H-1)) begin
                                        state <= S_DONE;
                                    end else begin
                                        r_idx <= r_idx + 1;
                                    end
                                end else begin
                                    c_idx <= c_idx + 1;
                                end
                            end else begin
                                k_idx <= k_idx + 1;
                            end
                        end
                    end

                    // -------- 默认: 不支持的操作 -> 结束 --------
                    else begin
                        state <= S_DONE;
                    end
                end

                // ------------------------------------------------
                // DONE: 1个周期的脉冲，仅对普通操作使能存储
                // ------------------------------------------------
                S_DONE: begin
                    // 任务完成！举起小旗子 (done信号)
                    done <= 1'b1;

                    // 如果是普通运算，告诉存储模块：“可以把结果存起来了”。
                    // 卷积因为是流式输出，不需要存回原来的矩阵存储区。
                    if (!op_invalid && (op_latched != 3'd4))
                        res_store_en <= 1'b1;
                    else
                        res_store_en <= 1'b0;

                    // 回到空闲状态，等待下一次 start
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
