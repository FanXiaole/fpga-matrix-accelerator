`timescale 1ns / 1ps

module key_filter #(
    parameter CLK_FREQ = 100_000_000, // 系统时钟频率
    parameter CNT_MS   = 20           // 需要防抖的时间 (ms)
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,   // 原始按键输入
    output reg  key_out,  // 消抖后的电平
    output wire key_flag  // 消抖后的单脉冲 (按下瞬间为1)
    //完全按照lab课的课件当中的第一种思路
);

    // 计数器走到2,000,000才算是按下去了，这个时候才发flag
    localparam CNT_MAX = (CLK_FREQ / 1000) * CNT_MS;

    reg [31:0] cnt; //计数器
    reg key_cnt_start; // 计数器启动标志
    reg key_r0, key_r1; // 用于同步和边沿检测

    // 1.消除亚稳态，即在你按下的瞬间时钟恰好正在变化，这个时候电压不稳，先让r0变化，下一个周期再r1变化，即可得到稳定电压
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_r0 <= 1'b0;
            key_r1 <= 1'b0;
        end else begin
            key_r0 <= key_in;
            key_r1 <= key_r0;
        end
    end

    // 2. 抖动检测与计数
    // 此时启动计数器。只有当计数器数满 20ms，且输入一直保持不变，才更新 key_out。
    // 检测输入是否发生变化
    wire key_change = (key_r1 != key_out);
    //异或逻辑，即外界与内部不一样的时候change会变为1
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 0;
            key_out <= 0;
        end else begin
            if (key_change) begin
                if (cnt < CNT_MAX) begin
                    cnt <= cnt + 1; // 正在计数
                end else begin
                    // 计数达到 20ms，说明信号稳定了，更新输出
                    key_out <= key_r1; 
                    cnt <= 0;
                end
            end else begin
                // 如果中间信号变回来了（说明是抖动），计数器清零
                cnt <= 0; 
            end
        end
    end

    // 3. 生成消抖后的上升沿脉冲 (PosEdge)
    // 只有当 key_out 从 0 变 1 时，产生一个周期的脉冲
    reg key_out_d;//用来储存上一拍的key_out
    always @(posedge clk) key_out_d <= key_out;
    
    //不同的时候说明发生了上升沿，此时产生一拍的变化，其它板块可以利用这个变化
    assign key_flag = key_out & ~key_out_d;

endmodule