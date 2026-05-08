`timescale 1ns/1ps

module matrix_storage #(
    parameter DATA_WIDTH = 16,  //每个矩阵元素占16bits
    parameter MAX_ROW = 5, //最大行数
    parameter MAX_COL = 5, //最大列数
    parameter MAX_MATRIX_NUM = 16 //最多储存的矩阵数量
)(
    input clk,rst_n,


    input [3:0] max_num_of_one_type, //一种矩阵最多存2个，没做setting


    input in_en, //写入功能的使能
    input [2:0] in_col, //待写入矩阵的列
    input [2:0] in_row, //待写入矩阵的行

    //写入的这个矩阵，把它完全压扁成一维向量来存储
    input [DATA_WIDTH * MAX_ROW * MAX_COL - 1:0] in_matrix,


    input [2:0] out_col,//要查询矩阵的列
    input [2:0] out_row,//要查询矩阵的行



    output reg  [MAX_MATRIX_NUM - 1:0] id_isMatch,//每一位对应一个格子，1代表格子中的矩阵匹配上我们要的，0代表不匹配
    output reg  [3:0] match_num, //总的有多少个是匹配的，没做setting，最多2


    //要输出的第一个矩阵
    input [3:0] id_1,//对应储存柜子里面得到地址
    output [DATA_WIDTH * MAX_ROW * MAX_COL - 1:0] matrix_1,//矩阵本身
    output [2:0] out_col_1,//要输出矩阵的列
    output [2:0] out_row_1,//要输出矩阵的行


    //要输出的第二个矩阵
    input [3:0] id_2,
    output [DATA_WIDTH * MAX_ROW * MAX_COL - 1:0] matrix_2,
    output [2:0] out_col_2,
    output [2:0] out_row_2,

    //相对ID和绝对ID的转化
    input [3:0] relative_id_in,//用户输入的相对id
    output reg [3:0] physical_id_out//相对id转化的得到的绝对id
);

        //每个柜子里面储存的是5 * 5的矩阵，矩阵的每一格都是16bits
    reg [DATA_WIDTH * MAX_ROW * MAX_COL - 1 : 0] matrix_data [0 : MAX_MATRIX_NUM - 1];
                                                            //一共有16个柜子
    
    reg [2:0] id_col [0 : MAX_MATRIX_NUM - 1];//16个柜子每个柜子里储存的列
    reg [2:0] id_row [0 : MAX_MATRIX_NUM - 1];//16个柜子每个柜子里储存的行
    reg id_isFull [0 : MAX_MATRIX_NUM - 1];//1代表这个柜子里面有元素，0代表没有


    reg [31:0] access_time [0 : MAX_MATRIX_NUM - 1]; //记录每一个格子现在矩阵进来的时间
    reg [31:0] global_timer;//每次进来一个矩阵，这个总时间就加1


    
    reg [4:0] match_count;//当前储存的同规格矩阵数量
    reg [4:0] target_slot;//最终要写入的柜子的id
    reg [4:0] first_empty_slot;//目前第一个空的柜子
    reg [4:0] first_match_slot;//第一个匹配的柜子
    reg [4:0] lru_slot;//全局时间最晚的柜子，就是要替代这个
    reg [31:0] min_time;
    reg found_empty;//1代表找到了空柜子
    reg found_match;//1代表找到了匹配的矩阵


    //以下两个具体逻辑实现了读入一个矩阵
    //1. 找到写入的位置的组合逻辑实现
    integer i_calc;//定义一个临时变量
    always @(*) begin
        //初始化清零所有变量
        match_count = 0;
        found_empty = 0;
        found_match = 0;
        first_empty_slot = MAX_MATRIX_NUM;
        first_match_slot = MAX_MATRIX_NUM;
        target_slot = MAX_MATRIX_NUM;

        lru_slot = MAX_MATRIX_NUM;
        min_time = 32'hFFFFFFFF;

        //挨着遍历所有的格子
        for (i_calc = 0; i_calc < MAX_MATRIX_NUM; i_calc = i_calc + 1) begin
            //这个if判断找到第一个空的位置
            if (id_isFull[i_calc] == 1'b0 && found_empty == 0) begin
                first_empty_slot = i_calc;
                found_empty = 1;
            end

            //这个if判断数清楚现在有多少与输入的行列相同的矩阵
            if (id_isFull[i_calc] == 1'b1 && id_row[i_calc] == in_row && id_col[i_calc] == in_col) begin
                match_count = match_count + 1;
                if (found_match == 0) begin
                    first_match_slot = i_calc;
                    found_match = 1;
                end
                
                //这里取找那个先进来的矩阵，如果满了进来的就替换这里
                if (access_time[i_calc] < min_time) begin
                    min_time = access_time[i_calc];
                    lru_slot = i_calc;
                end
            end
        end

        //如果现在还没存到两个矩阵就存在空的那个里面
        if (match_count < max_num_of_one_type) begin
            if (found_empty)
                target_slot = first_empty_slot;
            else//完全满了就放第一个格子
                target_slot = 0;
        end
        else begin//如果现在存了两个矩阵就存在那个先进来的位置里面
            target_slot = lru_slot;
        end
    end


    //2.写入具体格子的时序逻辑实现
    integer i_rst;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin//rst的时候完全清零
            global_timer <= 32'd0;
            for (i_rst = 0; i_rst < MAX_MATRIX_NUM; i_rst = i_rst + 1) begin
                id_isFull[i_rst] <= 1'b0;
                id_row[i_rst]    <= 3'd0;
                id_col[i_rst]    <= 3'd0;
                matrix_data[i_rst] <= 0;
                access_time[i_rst] <= 32'd0;
            end
        end
        else if (in_en) begin
            if (target_slot < MAX_MATRIX_NUM) begin
                //在上面找到的应该写入的位置一次性并行直接写入
                matrix_data[target_slot] <= in_matrix;
                id_row[target_slot]      <= in_row;
                id_col[target_slot]      <= in_col;
                id_isFull[target_slot]   <= 1'b1;
                //标记好这个矩阵式什么时候进入这个格子的
                access_time[target_slot] <= global_timer;
                //写入一个矩阵总时间++
                global_timer <= global_timer + 1;
            end
        end
    end




    //3.查询具体矩阵的组合逻辑实现
    integer i_query;
    always @(*) begin
        //先归零中间变量
        id_isMatch = 0;
        match_num = 0;
        //挨个遍历每一个格子
        for (i_query = 0; i_query < MAX_MATRIX_NUM; i_query = i_query + 1) begin
            //如果找到行列匹配的给格子上标记好，并且记好数
            if (id_isFull[i_query] && id_row[i_query] == out_row && id_col[i_query] == out_col) begin
                id_isMatch[i_query] = 1'b1;
                match_num = match_num + 1;
            end
        end
    end

    //读取数据，直接利用输入的id获取，方便其它板块使用，注意，这里的id是绝对id
    assign matrix_1  = matrix_data[id_1];
    assign out_row_1 = id_row[id_1];
    assign out_col_1 = id_col[id_1];

    assign matrix_2  = matrix_data[id_2];
    assign out_row_2 = id_row[id_2];
    assign out_col_2 = id_col[id_2];

    //4.这里实现了计算板块的用户输入的相对id和存储的绝对id的转化
    integer i_trans;
    reg [4:0] match_cnt_trans; //内部临时变量，因为没实现setting，其实最多为2
    always @(*) begin
        physical_id_out = 0; 
        match_cnt_trans = 0;
        //挨个遍历所有格子
        for (i_trans = 0; i_trans < MAX_MATRIX_NUM; i_trans = i_trans + 1) begin
            if (id_isMatch[i_trans]) begin
                match_cnt_trans = match_cnt_trans + 1;
                //上面在找匹配矩阵维护了id_isMatch，这个就是对应的绝对id
                if (match_cnt_trans == {1'b0, relative_id_in}) begin
                    physical_id_out = i_trans[3:0];
                end
            end
        end
    end
    //且这里的相对id1对应绝对id在前的，相对id2对应绝对id在后的
endmodule