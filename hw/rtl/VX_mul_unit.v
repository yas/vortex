`include "VX_define.vh"

module VX_mul_unit #(
    parameter CORE_ID = 0
) (
    input wire clk,
    input wire reset,
    
    // Inputs
    VX_mul_req_if   mul_req_if,

    // Outputs
    VX_wb_if        mul_wb_if
);    
    wire [`NUM_THREADS-1:0][31:0] alu_result;      
    wire [`NUM_THREADS-1:0][63:0] mul_result;
    wire [`NUM_THREADS-1:0][31:0] div_result;
    wire [`NUM_THREADS-1:0][31:0] rem_result;

    wire [`MUL_BITS-1:0]          alu_op  = mul_req_if.mul_op;
    wire [`NUM_THREADS-1:0][31:0] alu_in1 = mul_req_if.rs1_data;
    wire [`NUM_THREADS-1:0][31:0] alu_in2 = mul_req_if.rs2_data;

    genvar i;

    for (i = 0; i < `NUM_THREADS; i++) begin    

        wire [32:0] mul_in1 = {(alu_op != `MUL_MULHU)                          & alu_in1[i][31], alu_in1[i]};
        wire [32:0] mul_in2 = {(alu_op != `MUL_MULHU && alu_op != `MUL_MULHSU) & alu_in2[i][31], alu_in2[i]};
    
        wire [32:0] div_in1 = {(alu_op == `MUL_DIV || alu_op == `MUL_REM) & alu_in1[i][31], alu_in1[i]};
        wire [32:0] div_in2 = {(alu_op == `MUL_DIV || alu_op == `MUL_REM) & alu_in2[i][31], alu_in2[i]};

        VX_mult #(
            .WIDTHA(33),
            .WIDTHB(33),
            .WIDTHP(64),
            .SIGNED(1),
            .PIPELINE(`MUL_LATENCY)
        ) multiplier (
            .clk(clk),
            .reset(reset),
            .dataa(mul_in1),
            .datab(mul_in2),
            .result(mul_result[i])
        );

        VX_divide #(
            .WIDTHN(33),
            .WIDTHD(33),
            .WIDTHQ(32),
            .WIDTHR(32),
            .NSIGNED(1),
            .DSIGNED(1),
            .PIPELINE(`DIV_LATENCY)
        ) sdiv (
            .clk(clk),
            .reset(reset),
            .numer(div_in1),
            .denom(div_in2),
            .quotient(div_result[i]),
            .remainder(rem_result[i])
        );
        
        always @(*) begin
            case (alu_op)    
                `MUL_MUL:   alu_result[i] = mul_result[i][31:0];
                `MUL_MULH,      
                `MUL_MULHSU,    
                `MUL_MULHU: alu_result[i] = mul_result[i][63:32];            
                `MUL_DIV,       
                `MUL_DIVU:  alu_result[i] = (alu_in2[i] == 0) ? 32'hffffffff : div_result[i];            
                `MUL_REM,       
                `MUL_REMU:  alu_result[i] = (alu_in2 == 0) ? alu_in1[i] : rem_result[i];
                default:    alu_result[i] = alu_in1[i] + alu_in2[i]; // ADD, LUI, AUIPC, FENCE
            endcase
        end       
    end  

    reg result_avail;
    reg [4:0] pending_ctr;
    wire [4:0] instr_delay = `IS_DIV_OP(alu_op) ? `DIV_LATENCY : `MUL_LATENCY;

    always @(posedge clk) begin
        if (reset) begin     
            result_avail <= 0;       
            pending_ctr  <= 0;
        end else begin         
            if (result_avail && !stall) begin
                result_avail <= 0;
                pending_ctr  <= 0;
            end
            if ((| mul_req_if.valid) && (pending_ctr == 0)) begin  
                pending_ctr <= instr_delay - 1;
                if (instr_delay == 1)
                    result_avail <= 1;
            end else if (pending_ctr != 0) begin
                pending_ctr <= pending_ctr - 1; 
                if (pending_ctr == 1)
                    result_avail <= 1;
            end            
        end        
    end  

    wire pipeline_stall = ~result_avail && (| mul_req_if.valid);
    
    wire stall = (~mul_wb_if.ready && (| mul_wb_if.valid)) 
              || pipeline_stall;

    VX_generic_register #(
        .N(`NUM_THREADS + `NW_BITS + 32 + `NR_BITS + `WB_BITS + (`NUM_THREADS * 32)),
    ) mul_reg (
        .clk   (clk),
        .reset (reset),
        .stall (stall),
        .flush (0),
        .in    ({mul_req_if.valid, mul_req_if.warp_num, mul_req_if.curr_PC, mul_req_if.rd, mul_req_if.wb, alu_result}),
        .out   ({mul_wb_if.valid,  mul_wb_if.warp_num,  mul_wb_if.curr_PC,  mul_wb_if.rd,  mul_wb_if.wb,  mul_wb_if.data})
    );    

    assign mul_req_if.ready = ~stall;

endmodule