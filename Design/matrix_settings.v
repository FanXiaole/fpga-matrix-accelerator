`timescale 1ns / 1ps

module matrix_settings(
    input wire clk,
    input wire rst_n,
    input wire start,         // 进入设置模式后，按键触发修改
    input wire [3:0] param_sel, // 选择要设置的参数 (来自SW[7:4])
                                // 0: 每种规格最大数量 (SW[3:0] input)
                                // 1: 倒计时时间 (SW[3:0] input)
    input wire [3:0] val_in,  // 输入值 (来自SW[3:0])
    
    output reg [3:0] cfg_max_spec_count, // 输出给 Storage
    output reg [3:0] cfg_countdown_sec,  // 输出给 Top/Op
    output reg done // 设置完成脉冲
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_max_spec_count <= 4'd2;  // 默认值
            cfg_countdown_sec  <= 4'd10; // 默认值
            done <= 0;
        end else begin
            done <= 0;
            if (start) begin
                case (param_sel)
                    4'd0: begin
                        // 限制范围 1~5
                        if (val_in >= 1 && val_in <= 5) 
                            cfg_max_spec_count <= val_in;
                        done <= 1;
                    end
                    4'd1: begin
                        // 限制范围 5~15
                        if (val_in >= 5 && val_in <= 15) 
                            cfg_countdown_sec <= val_in;
                        done <= 1;
                    end
                    default: done <= 1;
                endcase
            end
        end
    end
endmodule