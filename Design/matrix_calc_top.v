`timescale 1ns / 1ps
//               _oo0oo_
//              o8888888o
//              88" . "88
//              (| -_- |)
//              0\  =  /0
//            ___/`---'\___
//          .' \\|     |// '.
//         / \\|||  :  |||// \
//        / _||||| -:- |||||- \
//       |   | \\\  -  /// |   |
//       | \_|  ''\---/''  |_/ |
//       \  .-\__  '-'  ___/-. /
//     ___'. .'  /--.--\  `. .'___
//  ."" '<  `.___\_<|>_/___.' >' "".
// | | :  `- \`.;`\ _ /`;.`/ - ` : | |
// \  \ `_.   \_ __\ /__ _/   .-` /  /
//====`-.____`.___ \_____/___.-`___.-'=====
//              `=---='
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//         佛祖保佑       永无BUG


module matrix_calc_top #(
    parameter DATA_WIDTH = 16,
    parameter MAX_ROW    = 5,
    parameter MAX_COL    = 5,
    parameter CLK_FREQ   = 100_000_000, 
    parameter BAUD_RATE  = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       UART_rx,
    output wire       UART_tx,
    
    // SW 开关定义 (模式选择):
    // [2:0] 模式选择: 
    //       000: Input (输入), 001: Gen (生成), 010: Display (显示), 011: Calc (计算)
    // [7:3] 参数设置/操作类型:
    //       Calc模式: [6:4] OpType
   
    input  wire [7:0] SW, 
    input  wire [3:0] small_SW, // 用于标量乘法的标量值
    input  wire       BTN_start,
    output wire [7:0] LED,
    output wire [7:0] SEG, 
    output wire [7:0] AN
);

    // ============================================================
    // 1. 按键消抖模块
    // ============================================================
    wire btn_posedge;
    key_filter #(.CLK_FREQ(CLK_FREQ)) u_btn (.clk(clk), .rst_n(rst_n), .key_in(BTN_start), .key_flag(btn_posedge));

    // ============================================================
    // 2. 内部信号定义 & 状态标志
    // ============================================================
    localparam TOTAL_BITS = MAX_ROW * MAX_COL * DATA_WIDTH;

    wire input_done, gen_done, calc_done, display_done, setting_done, display_busy;
    wire input_store_en, gen_store_en, calc_store_en;
    
    wire [2:0] input_m, input_n, gen_m, gen_n, calc_m, calc_n;
    wire [TOTAL_BITS-1:0] input_data, gen_data, calc_data;
    wire [31:0] bonus_cycles; 
    wire [1279:0] conv_matrix_flat; 

  
    wire [3:0] cfg_max_count;
    wire [3:0] cfg_countdown;

    // Storage 写接口信号
    reg  storage_wr_en;      
    reg  [2:0] storage_wr_m, storage_wr_n; 
    reg  [TOTAL_BITS-1:0] storage_wr_data; 
    wire [TOTAL_BITS-1:0] read_data_1, read_data_2;
    wire [2:0] read_m_1, read_n_1, read_m_2, read_n_2;

    // Settings 信号解包
    wire [3:0] set_sel = SW[7:4];
    wire [3:0] set_val = SW[3:0];

    // ============================================================
    // 3. MUX: Storage 写数据选择
    // ============================================================
    always @(*) begin
        storage_wr_en = 0; storage_wr_m = 0; storage_wr_n = 0; storage_wr_data = 0;
        case (SW[2:0])
            3'b000: begin // Input 模式
                storage_wr_en = input_store_en; storage_wr_m = input_m; storage_wr_n = input_n; storage_wr_data = input_data;
            end
            3'b001: begin // Gen 模式
                storage_wr_en = gen_store_en; storage_wr_m = gen_m; storage_wr_n = gen_n; storage_wr_data = gen_data;
            end
            3'b011: begin // Calc 模式
                storage_wr_en = 0; storage_wr_m = calc_m; storage_wr_n = calc_n; storage_wr_data = calc_data;
            end
            default: ;
        endcase
    end

    // ============================================================
    // 4. 各功能子模块实例化
    // ============================================================

    matrix_settings u_settings (
        .clk(clk), .rst_n(rst_n),
        .start(SW[2:0] == 3'b100 && btn_posedge),
        .param_sel(set_sel), .val_in(set_val),
        .cfg_max_spec_count(cfg_max_count), .cfg_countdown_sec(cfg_countdown),
        .done(setting_done)
    );

    matrix_input #(.MAX_M(MAX_ROW), .MAX_N(MAX_COL)) u_input (
        .clk(clk), .rst_n(rst_n), .UART_rx(UART_rx),
        .start(SW[2:0] == 3'b000 && btn_posedge),
        .done(input_done), .out_dim_m(input_m), .out_dim_n(input_n), .out_matrix_data(input_data), .out_store_enable(input_store_en)
    );

    // Gen Mode 寄存器
    reg [2:0] reg_gen_m;
    reg [2:0] reg_gen_n;
    reg [1:0] reg_gen_count;

    matrix_generate #(.MAX_ROW(MAX_ROW), .MAX_COL(MAX_COL)) u_gen (
        .clk(clk), .rst_n(rst_n),
        .start(SW[2:0] == 3'b001 && btn_posedge),
        .cfg_val_max(16'd9), .in_dim_m(reg_gen_m), .in_dim_n(reg_gen_n), .in_count(reg_gen_count),
        .done(gen_done), .out_dim_m(gen_m), .out_dim_n(gen_n), .out_matrix_data(gen_data), .out_store_enable(gen_store_en)
    );

    // --- Display & Calc 控制信号 ---
    reg fsm_disp_start;
    reg [1:0] fsm_disp_mode; 
    reg [2:0] fsm_query_row, fsm_query_col;
    reg [3:0] fsm_read_id;
    reg [3:0] reg_id_a, reg_id_b;
    reg [2:0] reg_op;
    reg calc_start_reg;
    
    wire [3:0] disp_read_id_req;
    wire [3:0] query_match_count;
    wire [15:0] match_mask;

    // MUX for Display (显示模块的多路选择器)
    wire [1:0] final_disp_mode;
    wire final_disp_start;
    wire [2:0] final_query_row, final_query_col;
    
    // SW=010 (Display)
    // SW=011 (Calc)
    assign final_disp_mode  = (SW[2:0] == 3'b010) ? 2'b01 : fsm_disp_mode;
    assign final_disp_start = (SW[2:0] == 3'b010) ? btn_posedge : fsm_disp_start;
   
    wire [3:0] storage_id_1_mux;

    assign storage_id_1_mux = (fsm_disp_mode == 2'b10) ? disp_read_id_req : 
                              (calc_start_reg ? reg_id_a : fsm_read_id);
    
    // 显示数据源选择：计算结果
    wire [TOTAL_BITS-1:0] disp_data_in_mux;
    assign disp_data_in_mux = (op_state == S_OP_SHOW_RES) ? calc_data : read_data_1;

    wire [1279:0] disp_data_padded;
    // 卷积结果
    assign disp_data_padded = (op_state == S_OP_SHOW_RES && reg_op == OP_CONV) ? 
                              conv_matrix_flat : 
                              {{(1280-TOTAL_BITS){1'b0}}, disp_data_in_mux};
    
    wire [3:0] disp_stride;  // 数据行跨度
    assign disp_stride = (op_state == S_OP_SHOW_RES && reg_op == OP_CONV) ? 4'd10 : 4'd5;

    wire [3:0] disp_row_num, disp_col_num;
    assign disp_row_num = (op_state == S_OP_SHOW_RES && reg_op == OP_CONV) ? 4'd8 : 
                          ((op_state == S_OP_SHOW_RES) ? {1'b0, calc_m} : 
                           (fsm_disp_mode == 2'b10) ? {1'b0, fsm_query_row} : {1'b0, read_m_1});
    assign disp_col_num = (op_state == S_OP_SHOW_RES && reg_op == OP_CONV) ? 4'd10 : 
                          ((op_state == S_OP_SHOW_RES) ? {1'b0, calc_n} : 
                           (fsm_disp_mode == 2'b10) ? {1'b0, fsm_query_col} : {1'b0, read_n_1});

    // 转换信号 
    wire [3:0] trans_rel_id;
    wire [3:0] trans_phy_id;
    assign trans_rel_id = uart_val[3:0];

    matrix_storage #(.MAX_ROW(MAX_ROW), .MAX_COL(MAX_COL)) u_storage (
        .clk(clk), .rst_n(rst_n), 
        .max_num_of_one_type(cfg_max_count), 
        .in_en(storage_wr_en), .in_row(storage_wr_m), .in_col(storage_wr_n), .in_matrix(storage_wr_data),
        .out_row(final_query_row), .out_col(final_query_col),
        .id_isMatch(match_mask), .match_num(query_match_count),
        .id_1(storage_id_1_mux), 
        .matrix_1(read_data_1), .out_row_1(read_m_1), .out_col_1(read_n_1),
        .id_2(reg_id_b), 
        .matrix_2(read_data_2), .out_row_2(read_m_2), .out_col_2(read_n_2),
        .relative_id_in(trans_rel_id),
        .physical_id_out(trans_phy_id)
    );

    matrix_display #(.MAX_ROW(MAX_ROW), .MAX_COL(MAX_COL), .CLK_FREQ(CLK_FREQ)) u_display (
        .clk(clk), .rst_n(rst_n),
        .start(final_disp_start),
        .mode_select(final_disp_mode),
        .matrix_data(disp_data_padded), // Use padded data
        .row_num(disp_row_num), 
        .col_num(disp_col_num),
        .data_stride(disp_stride), // New port
        .query_row(final_query_row), .query_col(final_query_col),
        .query_match_count(query_match_count),
        .match_mask(match_mask),
        .read_id_req(disp_read_id_req),
        .tx(UART_tx), .busy(display_busy), .done(display_done)
    );

    // ============================================================
    // 5. 核心控制逻辑 (FSM & 校验)
    // ============================================================
    
    // --- UART 命令解析器 ---
    wire [7:0] cmd_rx_data;
    wire cmd_rx_done;
    
    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) u_cmd_rx (
        .clk(clk), .rst_n(rst_n), .rx(UART_rx), .rx_data(cmd_rx_data), .rx_done(cmd_rx_done)
    );

    reg [15:0] uart_acc;
    reg uart_acc_valid;
    reg uart_val_valid;
    reg [15:0] uart_val;
    reg valid; // FSM 校验标志
    //实现数据读取
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_acc <= 0;
            uart_acc_valid <= 0;
            uart_val_valid <= 0;
            uart_val <= 0;
        end else begin
            uart_val_valid <= 0;
            if (cmd_rx_done) begin
                if (cmd_rx_data >= "0" && cmd_rx_data <= "9") begin
                    uart_acc <= uart_acc * 10 + (cmd_rx_data - "0");
                    uart_acc_valid <= 1;
                end else if (cmd_rx_data == 8'h0D || cmd_rx_data == 8'h0A || cmd_rx_data == 8'h20) begin
                    if (uart_acc_valid) begin
                        uart_val <= uart_acc;
                        uart_val_valid <= 1;
                        uart_acc <= 0;
                        uart_acc_valid <= 0;
                    end
                end
            end
        end
    end

    // ============================================================
    // Gen 模式参数接收逻辑
    // ============================================================
    reg [1:0] gen_input_step; // 分三步读取m n count

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_gen_m <= 3'd3; // 默认值
            reg_gen_n <= 3'd3;
            reg_gen_count <= 2'd1;
            gen_input_step <= 0;
        end else begin
            if (SW[2:0] == 3'b001) begin // Gen 模式
                if (uart_val_valid) begin
                    case (gen_input_step)
                        0: begin
                             reg_gen_m <= uart_val[2:0];
                             gen_input_step <= 1;
                        end
                        1: begin
                             reg_gen_n <= uart_val[2:0];
                             gen_input_step <= 2;
                        end
                        2: begin
                             reg_gen_count <= uart_val[1:0];
                             gen_input_step <= 0; 
                        end
                    endcase
                end
                // 如果按下按钮（开始生成），重置步骤
                if (btn_posedge) begin
                    gen_input_step <= 0; 
                end
            end else begin
                gen_input_step <= 0; 
            end
        end
    end

    // 操作类型定义
    localparam OP_TRANS = 3'd0; // T (转置)
    localparam OP_ADD   = 3'd1; // A (加法)
    localparam OP_SCAL  = 3'd2; // b (标量乘法)
    localparam OP_MULT  = 3'd3; // C (矩阵乘法)
    localparam OP_CONV  = 3'd4; // J (卷积)

    // 操作模式 FSM 状态定义
    localparam S_OP_IDLE        = 0;
    localparam S_OP_SEL_OP      = 1; // 先选择操作类型
    
    localparam S_OP_A_M         = 2;
    localparam S_OP_A_N         = 3;
    localparam S_OP_A_LIST      = 4; 
    localparam S_OP_A_LIST_WAIT = 5;
    localparam S_OP_A_ID        = 6;
    localparam S_OP_A_SHOW      = 7; 
    localparam S_OP_A_SHOW_WAIT = 8;
    
    localparam S_OP_B_M         = 9;
    localparam S_OP_B_N         = 10;
    localparam S_OP_B_LIST      = 11;
    localparam S_OP_B_LIST_WAIT = 12;
    localparam S_OP_B_ID        = 13;
    localparam S_OP_B_SHOW      = 14;
    localparam S_OP_B_SHOW_WAIT = 15;
    
    localparam S_OP_SCALAR      = 16; // 标量输入状态
    
    localparam S_OP_CALC_CHECK  = 17;
    localparam S_OP_CALC_RUN    = 18;
    localparam S_OP_CALC_DONE   = 19;
    localparam S_OP_SHOW_RES    = 20; // 结果显示状态
    localparam S_OP_ERROR       = 21;

    reg [4:0] op_state;
    reg [2:0] reg_a_m, reg_a_n, reg_b_m, reg_b_n;
    reg [15:0] reg_scalar; // 锁存标量输入
    
    // 错误处理
    reg calc_error_flag;
    reg [31:0] error_timer_cnt;
    reg [3:0]  error_sec_left;
    localparam ONE_SEC_CNT = CLK_FREQ; 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_state <= S_OP_IDLE;
            reg_a_m <= 0; reg_a_n <= 0; reg_b_m <= 0; reg_b_n <= 0;
            reg_id_a <= 0; reg_id_b <= 0; reg_op <= 0;
            reg_scalar <= 0;
            fsm_disp_start <= 0;
            fsm_disp_mode <= 0;
            fsm_query_row <= 0; fsm_query_col <= 0; fsm_read_id <= 0;
            calc_start_reg <= 0;
            calc_error_flag <= 0;
            error_timer_cnt <= 0; error_sec_left <= 0;
        end else begin
            fsm_disp_start <= 0; // 默认值
            calc_start_reg <= 0;

            if (SW[2:0] != 3'b011) begin
                op_state <= S_OP_IDLE;
                calc_error_flag <= 0;
            end else begin
                case (op_state)
                    S_OP_IDLE: begin
                        calc_error_flag <= 0;
                        // 等待 Start 信号开始操作选择
                        if (btn_posedge) begin
                            op_state <= S_OP_SEL_OP;
                        end
                    end
                    
                    // --- 先选择操作类型 ---
                    S_OP_SEL_OP: begin
                        // 在数码管上显示 Op，等待确认
                        if (btn_posedge) begin
                            reg_op <= SW[6:4]; 
                            op_state <= S_OP_A_M;
                        end
                    end
                    
                    // --- 选择矩阵 A ---
                    S_OP_A_M: begin
                        if (uart_val_valid) begin
                            reg_a_m <= uart_val[2:0]; 
                            op_state <= S_OP_A_N;
                        end
                    end
                    S_OP_A_N: begin
                        if (uart_val_valid) begin
                            reg_a_n <= uart_val[2:0]; 
                            op_state <= S_OP_A_LIST;
                        end
                    end
                    S_OP_A_LIST: begin
                        fsm_disp_mode <= 2'b10; // 列表模式
                        fsm_query_row <= reg_a_m;
                        fsm_query_col <= reg_a_n;
                        fsm_disp_start <= 1;
                        op_state <= S_OP_A_LIST_WAIT;
                    end
                    S_OP_A_LIST_WAIT: begin
                        if (display_done) op_state <= S_OP_A_ID;
                    end
                    S_OP_A_ID: begin
                        if (uart_val_valid) begin
                            reg_id_a <= trans_phy_id; 
                            if (reg_op == OP_TRANS) begin
                                fsm_read_id <= trans_phy_id;
                                fsm_disp_mode <= 2'b00;
                                op_state <= S_OP_CALC_CHECK;
                            end else begin
                                op_state <= S_OP_A_SHOW;
                            end
                        end
                    end
                    S_OP_A_SHOW: begin
                        fsm_disp_mode <= 2'b00; // 正常模式
                        fsm_read_id <= reg_id_a;
                        fsm_disp_start <= 1;
                        op_state <= S_OP_A_SHOW_WAIT;
                    end
                    S_OP_A_SHOW_WAIT: begin
                        if (display_done) begin
                            // 根据操作类型分支
                            if (reg_op == OP_ADD || reg_op == OP_MULT) begin
                                op_state <= S_OP_B_M;
                            end else if (reg_op == OP_SCAL) begin
                                op_state <= S_OP_SCALAR;
                            end else begin
                                // 转置, 卷积
                                op_state <= S_OP_CALC_CHECK;
                            end
                        end
                    end

                    // --- 选择矩阵 B (仅用于加法/乘法) ---
                    S_OP_B_M: begin
                        if (uart_val_valid) begin
                            reg_b_m <= uart_val[2:0];
                            op_state <= S_OP_B_N;
                        end
                    end
                    S_OP_B_N: begin
                        if (uart_val_valid) begin
                            reg_b_n <= uart_val[2:0];
                            op_state <= S_OP_B_LIST;
                        end
                    end
                    S_OP_B_LIST: begin
                        fsm_disp_mode <= 2'b10; // 列表模式
                        fsm_query_row <= reg_b_m;
                        fsm_query_col <= reg_b_n;
                        fsm_disp_start <= 1;
                        op_state <= S_OP_B_LIST_WAIT;
                    end
                    S_OP_B_LIST_WAIT: begin
                        if (display_done) op_state <= S_OP_B_ID;
                    end
                    S_OP_B_ID: begin
                        if (uart_val_valid) begin
                            reg_id_b <= trans_phy_id;
                            op_state <= S_OP_B_SHOW;
                        end
                    end
                    S_OP_B_SHOW: begin
                        fsm_disp_mode <= 2'b00; // 正常模式
                        fsm_read_id <= reg_id_b;
                        fsm_disp_start <= 1;
                        op_state <= S_OP_B_SHOW_WAIT;
                    end
                    S_OP_B_SHOW_WAIT: begin
                        if (display_done) op_state <= S_OP_CALC_CHECK;
                    end

                    // --- 选择标量 (仅用于标量乘法) ---
                    S_OP_SCALAR: begin
                        // 等待 SW 输入并确认
                        if (btn_posedge) begin
                            // 使用 small_SW 作为标量，带符号扩展
                            reg_scalar <= {{12{small_SW[3]}}, small_SW[3:0]}; 
                            op_state <= S_OP_CALC_CHECK;
                        end
                    end

                    S_OP_CALC_CHECK: begin
                        // 校验逻辑
                        valid = 0;
                        case (reg_op)
                            OP_ADD : if (reg_a_m == reg_b_m && reg_a_n == reg_b_n) valid = 1;
                            OP_MULT: if (reg_a_n == reg_b_m) valid = 1;
                            default: valid = 1;
                        endcase

                        if (valid) begin
                            // 清除之前的倒计时窗口
                            calc_error_flag <= 0;
                            op_state <= S_OP_CALC_RUN;
                        end else begin
                            // 加法/乘法维度不匹配：开始倒计时并重试选择矩阵 B
                            if (!calc_error_flag) begin
                                calc_error_flag <= 1;
                                error_sec_left <= (cfg_countdown >= 5 && cfg_countdown <= 15) ? cfg_countdown : 4'd10;
                                error_timer_cnt <= ONE_SEC_CNT;
                            end
                            op_state <= (reg_op == OP_ADD || reg_op == OP_MULT) ? S_OP_B_M : S_OP_IDLE;
                        end
                    end
                    
                    S_OP_CALC_RUN: begin
                        calc_start_reg <= 1;
                        if (calc_done) op_state <= S_OP_CALC_DONE;
                    end
                    
                    S_OP_CALC_DONE: begin
                        // 自动显示结果
                        fsm_disp_mode <= 2'b00; // 正常模式 (但使用结果数据)
                        fsm_disp_start <= 1;
                        op_state <= S_OP_SHOW_RES;
                    end

                    S_OP_SHOW_RES: begin
                        if (display_done) begin
                            // 等待用户查看完毕
                            if (btn_posedge) op_state <= S_OP_IDLE;
                        end
                    end
                    
                    S_OP_ERROR: begin
                        // 倒计时计时在下方全局处理。
                        calc_error_flag <= 1;
                    end
                    
                    default: op_state <= S_OP_IDLE;
                endcase

                // 错误倒计时窗口 (跨重试状态运行)
                // 跳过 CALC_CHECK 状态的倒计时维护，以免干扰状态转换。
                if (calc_error_flag && (op_state != S_OP_CALC_CHECK)) begin
                    if (error_timer_cnt > 0) error_timer_cnt <= error_timer_cnt - 1;
                    else begin
                        error_timer_cnt <= ONE_SEC_CNT;
                        if (error_sec_left > 0) error_sec_left <= error_sec_left - 1;
                        else begin
                            op_state <= S_OP_IDLE; // 超时 -> 重置
                            calc_error_flag <= 0;
                        end
                    end
                end
            end
        end
    end

    // ============================================================
    // 6. 数码管显示数据 MUX
    // ============================================================
    reg [15:0] seg_data_mux;
    reg [2:0]  seg_mode_mux; // 四种模式: 0-Hex, 1-OpChar, 2-Countdown, 3-Off, 4-CycleCount

    always @(*) begin
        seg_data_mux = 0;
        seg_mode_mux = 0; // 默认 Hex 模式

        if (SW[2:0] == 3'b011) begin // Calc 模式
            // 当维度不匹配发生时，即使在重试输入时也保持显示倒计时
            if (calc_error_flag) begin
                seg_mode_mux = 2; // 倒计时模式
                seg_data_mux = {12'b0, error_sec_left};
            end else case (op_state)
                S_OP_IDLE, S_OP_A_M, S_OP_A_N, S_OP_A_LIST, S_OP_A_LIST_WAIT, S_OP_A_ID, S_OP_A_SHOW, S_OP_A_SHOW_WAIT: begin
                    seg_mode_mux = 0; // Hex
                    seg_data_mux = {13'b0, reg_a_m}; // 显示相关信息？也许是当前步骤？
                    // 这里显示步骤 ID 或者直接显示 0
                end
                S_OP_SEL_OP: begin
                    seg_mode_mux = 1; // OpChar 模式
                    seg_data_mux = {13'b0, SW[6:4]}; // 显示当前选中的操作
                end
                S_OP_ERROR: begin
                    seg_mode_mux = 2; // 倒计时模式
                    seg_data_mux = {12'b0, error_sec_left};
                end
                S_OP_CALC_RUN: begin
                    seg_mode_mux = 3; // 关闭模式
                    seg_data_mux = 0;
                end
                S_OP_CALC_DONE, S_OP_SHOW_RES: begin
                    if (reg_op == OP_CONV) begin
                        seg_mode_mux = 4; // 周期计数模式
                        seg_data_mux = bonus_cycles[15:0];
                    end else begin
                        seg_mode_mux = 0; // Hex
                        seg_data_mux = {13'b0, calc_m}; // 显示结果行数？
                    end
                end
                default: ;
            endcase
        end else begin
            // 其他模式下显示 0
            seg_mode_mux = 0;
            seg_data_mux = 16'd0; 
        end
    end

    // ============================================================
    // 7. 矩阵运算模块 (核心计算)
    // ============================================================

    matrix_operation #(.MAX_ROW(MAX_ROW), .MAX_COL(MAX_COL)) u_matrix_op (
        .clk(clk), .rst_n(rst_n),
        .start(calc_start_reg), 
        .op_type(reg_op),
        .mat_A_data(read_data_1), .mat_A_row(read_m_1), .mat_A_col(read_n_1),
        .mat_B_data(read_data_2), .mat_B_row(read_m_2), .mat_B_col(read_n_2),
        .scalar_val(reg_scalar), 
        .done(calc_done), .res_row(calc_m), .res_col(calc_n), .res_data(calc_data), .res_store_en(calc_store_en),
        .bonus_cycle_cnt(bonus_cycles),
        .conv_matrix_flat(conv_matrix_flat) 
    );

    // ============================================================
    // 8. 数码管驱动 (显示)
    // ============================================================
    seg_driver #(.CLK_FREQ(CLK_FREQ)) u_seg (
        .clk(clk), .rst_n(rst_n),
        .data_in(seg_data_mux), 
        .mode(seg_mode_mux),   
        .seg(SEG), .an(AN)
    );

    // ============================================================
    // 9. LED 指示 (状态)
    // ============================================================
    reg l0, l1, l2, l3, l4;
    always @(posedge clk) begin
        if (input_done) l0 <= ~l0;
        if (gen_done)   l1 <= ~l1;
        if (calc_done)  l2 <= ~l2;
        if (display_done) l3 <= ~l3;
        if (setting_done) l4 <= ~l4;
    end
    assign LED[0]=l0; assign LED[1]=l1; assign LED[2]=l2; assign LED[3]=l3; 
    
    // LED[4] 在计算错误时闪烁，否则显示 Settings 状态
    assign LED[4] = (SW[2:0] == 3'b011) ? calc_error_flag : l4;
    
    assign LED[7:5] = SW[2:0]; // 显示当前模式

endmodule

// ============================================================
// 数码管驱动模块 (seg_driver.v) - 内部定义
// ============================================================
module seg_driver #(parameter CLK_FREQ = 100_000_000)(
    input wire clk, rst_n,
    input wire [15:0] data_in, // 要显示的数据
    input wire [2:0]  mode,    // 0:Hex, 1:OpChar, 2:Countdown, 3:Off, 4:CycleCount
    output reg [7:0] seg,      // 段选信号 (Active High: 1=Light)
    output reg [7:0] an        // 位选信号 (Active High: 1=Select)
);
    // 刷新频率: 1kHz
    localparam CNT_MAX = CLK_FREQ / 1000;
    reg [31:0] cnt;
    reg [2:0]  scan_sel;  // 当前扫描的位 (0-7)
    reg [6:0]  char_code; // 字符编码 (不含小数点)

    // 1. 扫描计数器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cnt <= 0; scan_sel <= 0; end
        else if (cnt >= CNT_MAX) begin cnt <= 0; scan_sel <= scan_sel + 1; end
        else cnt <= cnt + 1;
    end

    // 2. 位选与数据解码逻辑
    always @(*) begin
        an = 8'b00000000; // 默认全灭
        char_code = 0;
        
        case (mode)
            3'd0: begin // Hex Mode (显示低 4 位的 16 进制数值)
                // 仅使用 an[3:0]
                if (scan_sel <= 3) begin
                    an[scan_sel] = 1'b1;
                    case (scan_sel)
                        0: char_code = {3'b0, data_in[3:0]};
                        1: char_code = {3'b0, data_in[7:4]};
                        2: char_code = {3'b0, data_in[11:8]};
                        3: char_code = {3'b0, data_in[15:12]};
                        default: char_code = 0;
                    endcase
                end
            end
            
            3'd1: begin // OpChar Mode (显示操作符字符)
                // 仅点亮 an[7]
                if (scan_sel == 7) begin
                    an[7] = 1'b1;
                    // data_in[2:0] 对应 OpType
                    case (data_in[2:0])
                        3'd0: char_code = 7'h10; // T
                        3'd1: char_code = 7'h0A; // A
                        3'd2: char_code = 7'h0B; // b
                        3'd3: char_code = 7'h0C; // C
                        3'd4: char_code = 7'h11; // J
                        default: char_code = 7'h12; // Blank
                    endcase
                end
            end
            
            3'd2: begin // Countdown Mode (倒计时显示)
                // 使用 an[7] 十位, an[6] 个位
                if (scan_sel == 7) begin
                    an[7] = 1'b1;
                    char_code = {3'b0, data_in[3:0] / 10}; // 十位
                end else if (scan_sel == 6) begin
                    an[6] = 1'b1;
                    char_code = {3'b0, data_in[3:0] % 10}; // 个位
                end
            end

            3'd3: begin // Off Mode (全灭)
                an = 8'b00000000;
            end

            3'd4: begin // Cycle Count Mode 
                // 显示在 an[7:4] (an[7]=千位, an[4]=个位)
                if (scan_sel >= 4 && scan_sel <= 7) begin
                    an[scan_sel] = 1'b1;
                    case (scan_sel)
                        4: char_code = {3'b0, data_in % 10};          // 个位
                        5: char_code = {3'b0, (data_in / 10) % 10};   // 十位
                        6: char_code = {3'b0, (data_in / 100) % 10};  // 百位
                        7: char_code = {3'b0, (data_in / 1000) % 10}; // 千位
                        default: char_code = 0;
                    endcase
                end
            end

            default: ;
        endcase
    end

    // 3. 7段译码器 
   
    always @(*) begin
        case (char_code)
            // 0-9
            7'h00: seg = 8'b11111100; // 0: a,b,c,d,e,f
            7'h01: seg = 8'b01100000; // 1: b,c
            7'h02: seg = 8'b11011010; // 2: a,b,d,e,g
            7'h03: seg = 8'b11110010; // 3: a,b,c,d,g
            7'h04: seg = 8'b01100110; // 4: b,c,f,g
            7'h05: seg = 8'b10110110; // 5: a,c,d,f,g
            7'h06: seg = 8'b10111110; // 6: a,c,d,e,f,g
            7'h07: seg = 8'b11100000; // 7: a,b,c
            7'h08: seg = 8'b11111110; // 8: a,b,c,d,e,f,g
            7'h09: seg = 8'b11110110; // 9: a,b,c,d,f,g
            
            // A-F
            7'h0A: seg = 8'b11101110; // A: a,b,c,e,f,g
            7'h0B: seg = 8'b00111110; // b: c,d,e,f,g
            7'h0C: seg = 8'b10011100; // C: a,d,e,f
            7'h0D: seg = 8'b01111010; // d: b,c,d,e,g
            7'h0E: seg = 8'b10011110; // E: a,d,e,f,g
            7'h0F: seg = 8'b10001110; // F: a,e,f,g
            
            // 特殊字符
            7'h10: seg = 8'b00011110; // t: d,e,f,g
            7'h11: seg = 8'b01111000; // J: b,c,d,e
            default: seg = 8'b00000000; // Blank
        endcase
    end
endmodule