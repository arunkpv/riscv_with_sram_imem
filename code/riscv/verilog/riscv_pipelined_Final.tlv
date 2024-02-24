\m4_TLV_version 1d -p verilog --bestsv --noline --clkAlways --inlineGen --iArgs --verbose: tl-x.org
\SV
   
   //m4_include_lib(['https://raw.githubusercontent.com/stevehoover/RISC-V_MYTH_Workshop/master/tlv_lib/risc-v_shell_lib.tlv'])
   m4_include_lib(['https://raw.githubusercontent.com/arunkpv/vsd-hdp/main/code/riscv/verilog/include/risc-v_shell_lib.tlv'])

   // Module interface, either for Makerchip, or not.
   m4_ifelse_block(M4_MAKERCHIP, 1, ['
      // Makerchip module interface.
      m4_makerchip_module
      wire CLK_top = clk;
      logic [9:0] out;
      assign passed = cyc_cnt > 100;
      assign failed = 1'b0;
      '], ['
      // Custom module interface for BabySoC.
      module riscv(
         input clk,
         input reset,
         output reg [9:0] out
      );
      wire clk = CLK_top;
      '])

\TLV

   // /====================\
   // | Sum 1 to 9 Program |
   // \====================/
   //
   // Program for MYTH Workshop to test RV32I
   // Add 1,2,3,...,9 (in that order).
   //
   // Regs:
   //  r10 (a0): In: 0, Out: final sum
   //  r12 (a2): 10
   //  r13 (a3): 1..10
   //  r14 (a4): Sum
   // 
   // External to function:
   m4_asm(ADD,  r10,  r0,  r0)           // Initialize r10 to 0.
   m4_asm(ADD,  r15,  r0,  r0)           // Initialize r15 to 0.
   // Function:
   m4_asm(ADD,  r14,  r0,  r0)           // Initialize partial sum register r14 with 0x0
   m4_asm(ADDI, r12,  r0, 1010)          // Store count of 10 in register r12.
   m4_asm(ADD,  r13,  r0,  r0)           // Initialize count register r13 with 0
   // Loop:
   m4_asm(ADD,  r14, r13, r14)           // Incremental addition
   m4_asm(ADDI, r13, r13, 1)             // Increment count register by 1
   m4_asm(BLT,  r13, r12, 1111111111000) // If r13 is less than r12, branch to label named <loop>
                                         // 0xFFFF_FFF8 = -8 (decimal)
   m4_asm(ADD,  r10, r14, r0)            // Store final result to register r10 so that it can be read by main program
   
   m4_asm(SW,  r0, r10, 00100)           // DMEM[1] = r10 = 45 (2d)
   m4_asm(LW, r15,  r0, 00100)           // r15 = DMEM[1] = 45 (2d)
   
   // Optional: Jump to itself (infinite loop)
   m4_asm(JAL, r7, 111111111111111010100) // Offset[20:0] = -44 (0x1F_FFD4)
   
   // Additional instructions added to test out the RAW hazard during Load redirect
   //m4_asm(ADD,  r1, r15, r1)      // r1 = r1 + r15 = 46 (2e)
   //m4_asm(ADD,  r1,  r1, r1)      // r1 = r1 + r1  = 92 (5c)
   //m4_asm(LW,   r2,  r0, 10000)   // r2 = DMEM[4] = 4
   //m4_asm(ADD,  r3,  r2, r3)      // r3 = r2 + r3 = 4 + 3 = 7
   //m4_asm(SW,   r0,  r3, 01100)   // DMEM[3] = r3 = 7
   //m4_asm(LW,   r2,  r0, 00100)   // r2 = DMEM[1] = 45 (2d)
   //m4_asm(ADD,  r2,  r2, r2)      // r2 = r2 + r2 = 90 (5a)
   
   
   m4_define_hier(['M4_IMEM'], M4_NUM_INSTRS)

   |cpu
      @0
         $reset = *reset;
         
         // PC logic
         // Use the previous $br_tgt_pc if the branch was taken in the previous instruction
         $pc[31:0] = >>1$reset ? 32'b0 :
                     >>3$valid_taken_br ? >>3$br_tgt_pc :
                     (>>3$valid_jump && >>3$is_jal) ? >>3$br_tgt_pc :
                     (>>3$valid_jump && >>3$is_jalr) ? >>3$jalr_tgt_pc :
                     >>3$valid_load ? >>3$inc_pc :
                     >>1$inc_pc;
         
         // IMEM Enable, ReadAddress port connections:
         // Assuming IMEM is DWORD-addressable, align the PC with the IMEM Read address port
         // Essentially, PC[1:0] = 2'b0. Hence, we can make the connection as follows:
         $imem_rd_en = !$reset;
         $imem_rd_addr[M4_IMEM_INDEX_CNT-1:0] = $pc[M4_IMEM_INDEX_CNT+1:2]; //imem_rd_addr[31:0]
         
         // Start signal pulses for 1 cycle immediately after reset deassertion
         //$start = >>1$reset && !$reset;
         
         // Valid signal is a 3-Cycle valid corresponding to the 3-stage pipeline we are 
         // implementing. Following reset deassertion, toggles as follows: 100100100...
         //$valid = $reset ? 1'b0 :
         //                  $start ? 1'b1 : >>3$valid;
      @1
         // Increment PC by 1 instruction length (fixed 4 bytes) every cycle
         $inc_pc[31:0] = $pc + 32'd4;
         
         // INSTRUCTION FETCH
         $instr[31:0] = $imem_rd_data[31:0];
         
         // INSTRUCTION-TYPE DECODE:
         // $instr[1:0] = 2'b11 for RV32I Base
         // Register
         $is_r_instr = ($instr[6:2] == 5'b01011) ||
                       ($instr[6:2] == 5'b01100) ||
                       ($instr[6:2] == 5'b01110) ||
                       ($instr[6:2] == 5'b10100);
         
         // Immediate
         $is_i_instr = ($instr[6:2] == 5'b00000) ||
                       ($instr[6:2] == 5'b00001) ||
                       ($instr[6:2] == 5'b00100) ||
                       ($instr[6:2] == 5'b00110) ||
                       ($instr[6:2] == 5'b11001);
         
         // Store
         $is_s_instr = ($instr[6:2] == 5'b01000) ||
                       ($instr[6:2] == 5'b01001);
         
         // Branch
         $is_b_instr = ($instr[6:2] == 5'b11000);
         
         // Upper Immediate
         $is_u_instr = ($instr[6:2] == 5'b00101) ||
                       ($instr[6:2] == 5'b01101);
         
         // Jump
         $is_j_instr = ($instr[6:2] == 5'b11011);
         
         // IMMEDIATE VALUE DECODE
         $imm[31:0] = $is_i_instr ? {{21{$instr[31]}}, $instr[30:20]} :
                      $is_s_instr ? {{21{$instr[31]}}, $instr[30:25], $instr[11:7]} :
                      $is_b_instr ? {{20{$instr[31]}}, $instr[7], $instr[30:25], $instr[11:8], 1'b0} :
                      $is_u_instr ? {$instr[31:12], 12'b0} :
                      $is_j_instr ? {{12{$instr[31]}}, $instr[19:12], $instr[20], $instr[30:21], 1'b0} :
                      32'b0;
         
         // INSTRUCTION DECODING
         $opcode[6:0] = $instr[6:0];
         
         $rd_valid     = $is_r_instr | $is_i_instr | $is_u_instr | $is_j_instr;
         $funct3_valid = $is_r_instr | $is_i_instr | $is_s_instr | $is_b_instr;
         $rs1_valid    = $is_r_instr | $is_i_instr | $is_s_instr | $is_b_instr;
         $rs2_valid    = $is_r_instr | $is_s_instr | $is_b_instr;
         $funct7_valid = $is_r_instr;
         
         ?$rd_valid
            $rd[4:0]     = $instr[11:7];
         ?$funct3_valid
            $funct3[2:0] = $instr[14:12];
         ?$rs1_valid
            $rs1[4:0]    = $instr[19:15];
         ?$rs2_valid
            $rs2[4:0]    = $instr[24:20];
         ?$funct7_valid
            $funct7[6:0] = $instr[31:25];
         
         // Decode the individual instructions
         $dec_bits[10:0] = {$funct7[5], $funct3[2:0], $opcode[6:0]};
         
         $is_lui   = ($dec_bits[6:0] == 7'b0110111);
         $is_auipc = ($dec_bits[6:0] == 7'b0010111);
         $is_jal   = ($dec_bits[6:0] == 7'b1101111);
         $is_jalr  = ($dec_bits[9:0] == 10'b000_1100111);
         
         $is_beq  = ($dec_bits[9:0] == 10'b000_1100011);
         $is_bne  = ($dec_bits[9:0] == 10'b001_1100011);
         $is_blt  = ($dec_bits[9:0] == 10'b100_1100011);
         $is_bge  = ($dec_bits[9:0] == 10'b101_1100011);
         $is_bltu = ($dec_bits[9:0] == 10'b110_1100011);
         $is_bgeu = ($dec_bits[9:0] == 10'b111_1100011);
         
         $is_load = ($opcode == 7'b0000011);    // All load instructions are treated the same
         
         $is_sb = ($dec_bits[9:0] == 10'b000_0100011);
         $is_sh = ($dec_bits[9:0] == 10'b001_0100011);
         $is_sw = ($dec_bits[9:0] == 10'b010_0100011);
         
         $is_addi  = ($dec_bits[9:0]  == 10'b000_0010011);
         $is_slti  = ($dec_bits[9:0]  == 10'b010_0010011);
         $is_sltiu = ($dec_bits[9:0]  == 10'b011_0010011);
         $is_xori  = ($dec_bits[9:0]  == 10'b100_0010011);
         $is_ori   = ($dec_bits[9:0]  == 10'b110_0010011);
         $is_andi  = ($dec_bits[9:0]  == 10'b111_0010011);
         $is_slli  = ($dec_bits[10:0] == 11'b0_001_0010011);
         $is_srli  = ($dec_bits[10:0] == 11'b0_101_0010011);
         $is_srai  = ($dec_bits[10:0] == 11'b1_101_0010011);
         $is_add   = ($dec_bits[10:0] == 11'b0_000_0110011);
         $is_sub   = ($dec_bits[10:0] == 11'b1_000_0110011);
         $is_sll   = ($dec_bits[10:0] == 11'b0_001_0110011);
         $is_slt   = ($dec_bits[10:0] == 11'b0_010_0110011);
         $is_sltu  = ($dec_bits[10:0] == 11'b0_011_0110011);
         $is_xor   = ($dec_bits[10:0] == 11'b0_100_0110011);
         $is_srl   = ($dec_bits[10:0] == 11'b0_101_0110011);
         $is_sra   = ($dec_bits[10:0] == 11'b1_101_0110011);
         $is_or    = ($dec_bits[10:0] == 11'b0_110_0110011);
         $is_and   = ($dec_bits[10:0] == 11'b0_111_0110011);
         
         $is_jump = ($is_jal || $is_jalr);
         
         `BOGUS_USE($is_beq $is_bne $is_blt $is_bge $is_bltu $is_bgeu $is_load $is_sb $is_sh $is_sw $is_addi);
         `BOGUS_USE($is_slti $is_sltiu $is_xori $is_ori $is_andi $is_slli $is_srli $is_srai $is_add $is_sub);
         `BOGUS_USE($is_sll $is_slt $is_sltu $is_xor $is_srl $is_sra $is_or $is_and);
         
      @2
         // Target PC for a branch instruction
         $br_tgt_pc[31:0] = $pc + $imm;
         
         // REGISTER FILE READ
         //$rf_reset = $reset;
         $rf_rd_en1 = $rs1_valid;
         $rf_rd_index1[4:0] = $rs1;
         $rf_rd_en2 = $rs2_valid;
         $rf_rd_index2[4:0] = $rs2;
         
         // Handling Read-After-Write Hazard
         $src1_value[31:0] = (>>1$rf_wr_index == $rf_rd_index1) && >>1$rf_wr_en
                             ? >>1$rf_wr_data : $rf_rd_data1;
         
         $src2_value[31:0] = (>>1$rf_wr_index == $rf_rd_index2) && >>1$rf_wr_en
                             ? >>1$rf_wr_data : $rf_rd_data2;
         
      @3
         // ALU
         // Intermediate result signals for SLT, SLTI instructions
         $sltu_rslt[31:0]   = ($src1_value < $src2_value);
         $sltiu_rslt[31:0]  = ($src1_value < $imm);
         
         $result[31:0] = $is_lui   ? $imm[31:0] :
                         $is_auipc ? ($pc + $imm) :
                         $is_jal   ? ($pc + 32'd4) :
                         $is_jalr  ? ($pc + 32'd4) :
                         ($is_load || $is_s_instr) ? ($src1_value + $imm) :
                         $is_sll   ? ($src1_value << $src2_value[4:0]) :
                         $is_slli  ? ($src1_value << $imm[5:0]) :
                         $is_srl   ? ($src1_value >> $src2_value[4:0]) :
                         $is_srli  ? ($src1_value >> $imm[5:0]) :
                         $is_sra   ? ({{32{$src1_value[31]}}, $src1_value} >> $src2_value[4:0]) :
                         $is_srai  ? ({{32{$src1_value[31]}}, $src1_value} >> $imm[4:0]) :
                         $is_add   ? ($src1_value + $src2_value) :
                         $is_addi  ? ($src1_value + $imm) :
                         $is_sub   ? ($src1_value - $src2_value) :
                         $is_xor   ? ($src1_value ^ $src2_value) :
                         $is_xori  ? ($src1_value ^ $imm) :
                         $is_and   ? ($src1_value & $src2_value) :
                         $is_andi  ? ($src1_value & $imm) :
                         $is_or    ? ($src1_value | $src2_value) :
                         $is_ori   ? ($src1_value | $imm) :
                         $is_slt   ? ($src1_value[31] == $src2_value[31]) ? $sltu_rslt : {31'b0, $src1_value[31]} :
                         $is_slti  ? ($src1_value[31] == $imm[31]) ? $sltiu_rslt : {31'b0, $src1_value[31]} :
                         $is_sltu  ? ($src1_value < $src2_value) :
                         $is_sltiu ? ($src1_value < $imm) :
                         32'bx;
         
         // BRANCH INSTRNS.
         $taken_br = $is_beq  ? ($src1_value == $src2_value) :
                     $is_bne  ? ($src1_value != $src2_value) :
                     $is_bltu ? ($src1_value <  $src2_value) :
                     $is_bgeu ? ($src1_value >= $src2_value) :
                     $is_blt  ? ($src1_value < $src2_value) ^ ($src1_value[31] != $src2_value[31]) :
                     $is_bge  ? ($src1_value >= $src2_value) ^ ($src1_value[31] != $src2_value[31]) :
                     1'b0;
         
         // Valid signals to handle flow hazards due to branches and loads
         $valid_taken_br = ($taken_br && $valid);
         $valid_load = ($is_load && $valid);
         $valid_jump = ($is_jump && $valid);
         
         // JALR Target PC
         $jalr_tgt_pc[31:0] = $src1_value + $imm ;
         
         // Assert valid only if, in the previous two instructions:
         //   - a branch was not taken
         //   - were not load instructions
         //   - were not jump instructions
         $valid = !(>>1$valid_taken_br || >>2$valid_taken_br ||
                    >>1$valid_load || >>2$valid_load ||
                    >>1$valid_jump || >>2$valid_jump);
         
         // REGISTER FILE WRITE
         $rf_wr_en = (!$valid_load && !>>1$valid_load) && ($rd_valid && ($rd != 5'b0) && $valid) || >>2$valid_load;
         $rf_wr_index[4:0] = >>2$valid_load ? >>2$rd : $rd;
         $rf_wr_data[31:0] = >>2$valid_load ? >>2$ld_data : $result;
         
      @4
         // DMEM: Mini 1-R/W Memory
         //       16 entries, 32-bit wide
         $dmem_wr_en = ($is_s_instr && $valid);
         $dmem_rd_en = $valid_load;
         $dmem_addr[3:0] = $result[5:2];
         $dmem_wr_data[31:0] = $src2_value;
         
      @5
         // Load data from DMEM to RF 2 cycles after valid_load is asserted
         $ld_data[31:0] = $dmem_rd_data;
         
         
      
   
   // Assert these to end simulation (before Makerchip cycle limit).
   //*passed = *cyc_cnt > 40;
   //*passed = |cpu/xreg[15]>>5$value == (1+2+3+4+5+6+7+8+9);
   //*failed = 1'b0;
   
   \SV_plus
      always @ (posedge clk)
      begin
         *out = |cpu/xreg[15]>>5$value;
      end
   
   // Macro instantiations for:
   //  o instruction memory
   //  o register file
   //  o data memory
   //  o CPU visualization
   |cpu
      m4+imem(@1)    // Args: (read stage)
      m4+rf(@2, @3)  // Args: (read stage, write stage) - if equal, no register bypass is required
      m4+dmem(@4)    // Args: (read/write stage)
   
   //m4+cpu_viz(@4)    // For visualisation, argument should be at least equal to the last stage of CPU logic. @4 would work for all labs.
/*   
   |cpu
      @2
         \viz_js
            render() {
               //let is_s_instr    = "$is_s_instr:    "+'$is_s_instr'.asInt(NaN).toString()+"\n";
               
               let imm           = "$imm            : "+'$imm'.asInt(NaN).toString()+" (0x"+'$imm'.asInt(NaN).toString(16)+")"+"\n";
               
               let rf_rd_index1  = "$rf_rd_index1   : "+'$rf_rd_index1'.asInt(NaN).toString()+" (0x"+'$rf_rd_index1'.asInt(NaN).toString(16)+")"+"\n";
               let rf_rd_index2  = "$rf_rd_index2   : "+'$rf_rd_index2'.asInt(NaN).toString()+" (0x"+'$rf_rd_index2'.asInt(NaN).toString(16)+")"+"\n";
               
               let valid_load_3  = ">>3$valid_load  : "+'>>3$valid_load'.asInt(NaN).toString()+"\n";
               let rf_wr_index_3 = ">>3$rf_wr_index : "+'>>3$rf_wr_index'.asInt(NaN).toString()+" (0x"+'>>3$rf_wr_index'.asInt(NaN).toString(16)+")"+"\n";
                
               let valid_load_2  = ">>2$valid_load  : "+'>>2$valid_load'.asInt(NaN).toString()+"\n";
               let rf_wr_index_2 = ">>2$rf_wr_index : "+'>>2$rf_wr_index'.asInt(NaN).toString()+" (0x"+'>>2$rf_wr_index'.asInt(NaN).toString(16)+")"+"\n";
               
               let rf_wr_index_1 = ">>1$rf_wr_index : "+'>>1$rf_wr_index'.asInt(NaN).toString()+" (0x"+'>>1$rf_wr_index'.asInt(NaN).toString(16)+")"+"\n";
               let rd_valid      = "$rd_valid       : "+'$rd_valid'.asInt(NaN).toString()+"\n";
               let rf_wr_en      = ">>1$rf_wr_en       : "+'>>1$rf_wr_en'.asInt(NaN).toString()+"\n";
               let ld_data_3     = ">>3$ld_data     : "+'>>3$ld_data'.asInt(NaN).toString()+" (0x"+'>>3$ld_data'.asInt(NaN).toString(16)+")"+"\n";
               let result_2      = ">>2$result      : "+'>>2$result'.asInt(NaN).toString()+" (0x"+'>>2$result'.asInt(NaN).toString(16)+")"+"\n";
               let result_1      = ">>1$result      : "+'>>1$result'.asInt(NaN).toString()+" (0x"+'>>1$result'.asInt(NaN).toString(16)+")"+"\n";
               let rf_rd_data1   = "$rf_rd_data1    : "+'$rf_rd_data1'.asInt(NaN).toString()+" (0x"+'$rf_rd_data1'.asInt(NaN).toString(16)+")"+"\n";
               let rf_rd_data2   = "$rf_rd_data2    : "+'$rf_rd_data2'.asInt(NaN).toString()+" (0x"+'$rf_rd_data2'.asInt(NaN).toString(16)+")"+"\n";
               
               let src1_val      = "$src1_val       : "+'$src1_value'.asInt(NaN).toString()+" (0x"+'$src1_value'.asInt(NaN).toString(16)+")"+"\n";
               let src2_val      = "$src2_val       : "+'$src2_value'.asInt(NaN).toString()+" (0x"+'$src2_value'.asInt(NaN).toString(16)+")"+"\n";
               
               let str_2 = "@2:------------------------\n"
                         //+ is_s_instr
                         + imm
                         + rf_rd_index1 + rf_rd_index2 + "\n"
                         + valid_load_3 + rf_wr_index_3 + "\n"
                         + valid_load_2 + rf_wr_index_2 + "\n"
                         + rf_wr_index_1 + rd_valid + rf_wr_en + "\n"
                         + ld_data_3
                         + result_2
                         + result_1
                         + rf_rd_data1 + rf_rd_data2+ "\n"
                         + src1_val + src2_val;
               
               let str_stage2 = new fabric.Text(str_2, {
                  top: 0, left: 0,
                  fontSize: 14, fontFamily: "monospace"
               });
               return [str_stage2];
            },
            where: {left: 100, top: 180}

   |cpu
      @3
         \viz_js
            render() {
               let alu_result    = "$result         : "+'$result'.asInt(NaN).toString()+" (0x"+'$result'.asInt(NaN).toString(16)+")"+"\n";
               
               let src1_val      = "$src1_val       : "+'$src1_value'.asInt(NaN).toString()+" (0x"+'$src1_value'.asInt(NaN).toString(16)+")"+"\n";
               let src2_val      = "$src2_val       : "+'$src2_value'.asInt(NaN).toString()+" (0x"+'$src2_value'.asInt(NaN).toString(16)+")"+"\n";
               
               let imm           = "$imm            : "+'$imm'.asInt(NaN).toString()+" (0x"+'$imm'.asInt(NaN).toString(16)+")"+"\n";
               
               let rd_valid      = "$rd_valid       : "+'$rd_valid'.asInt(NaN).toString()+"\n";
               let rf_wr_en      = "$rf_wr_en       : "+'$rf_wr_en'.asInt(NaN).toString()+"\n";
               
               let str_3 = "@3:------------------------\n"
                         + src1_val + src2_val
                         + imm
                         + alu_result +"\n"
                         + rd_valid + rf_wr_en;
               
               let str_stage3 = new fabric.Text(str_3, {
                  top: 0, left: 0,
                  fontSize: 14, fontFamily: "monospace"
               });
               return [str_stage3];
            },
            where: {left: 100, top: 620}
*/
// Somehow, uncommenting this section makes the viz_js for @3 to go away
/*
   |cpu
      @4
         \viz_js
            render() {
               let rf_wr_en      = "$rf_wr_en      : "+'$rf_wr_en'.asInt(NaN).toString()+"\n";
               let valid_load_2  = ">>2$valid_load : "+'>>2$valid_load'.asInt(NaN).toString()+"\n";
               let rd_2          = ">>2$rd         : "+'>>2$rd'.asInt(NaN).toString()+" (0x"+'>>2$rd'.asInt(NaN).toString(16)+")"+"\n";
               let rd            = "$rd            : "+'$rd'.asInt(NaN).toString()+" (0x"+'$rd'.asInt(NaN).toString(16)+")"+"\n";
               let rf_wr_index   = "$rf_wr_index   : "+'$rf_wr_index'.asInt(NaN).toString()+" (0x"+'$rf_wr_data'.asInt(NaN).toString(16)+")"+"\n";
               
               let ld_data_2     = ">>2$ld_data    : "+'>>2$ld_data'.asInt(NaN).toString()+" (0x"+'>>2$ld_data'.asInt(NaN).toString(16)+")"+"\n";
               let result        = "$result        : "+'$result'.asInt(NaN).toString()+" (0x"+'$result'.asInt(NaN).toString(16)+")"+"\n";
               
               let rf_wr_data    = "$rf_wr_data    : "+'$rf_wr_data'.asInt(NaN).toString()+" (0x"+'$rf_wr_data'.asInt(NaN).toString(16)+")"+"\n";
               
               let str_4 = "@4:------------------------\n"
                         + rf_wr_en
                         + valid_load_2 + "\n"
                         + rd_2 + rd + "\n"
                         + rf_wr_index + "\n"
                         + ld_data_2
                         + result + "\n"
                         + rf_wr_data;
               
               let str_stage4 = new fabric.Text(str_4, {
                  top: 0, left: 0,
                  fontSize: 14, fontFamily: "monospace"
               });
               return [str_stage4];
            },
            where: {left: 400, top: 590}
*/
      // Note: Because of the magic we are using for visualisation, if visualisation is enabled below,
      //       be sure to avoid having unassigned signals (which you might be using for random inputs)
      //       other than those specifically expected in the labs. You'll get strange errors for these.
\SV
   endmodule
