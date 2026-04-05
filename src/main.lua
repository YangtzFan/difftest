-- ============================================================================
-- Difftest 主控文件
-- ============================================================================
-- 功能：
--   1. 驱动 RTL 仿真时钟
--   2. 检测 RTL 指令提交信号
--   3. 调用参考模型（emu）执行对应指令
--   4. 比对 RTL 输出与参考模型输出
--   5. 发现不匹配时打印详细日志并终止仿真
-- ============================================================================
local utils = require "verilua.LuaUtils"
local bit    = require "bit"
local tobit  = bit.tobit

-- 加载模拟器类并创建实例
local emu = require "emu"
local tc = assert(os.getenv "TC", "获取 TC 环境变量失败")
local emu = emu(tc) --[[@as difftest.emulator]]

local to_hex = utils.to_hex_str
local f = string.format
local print = print

local function test_print(msg)
    if msg == "success" then
        print("\27[32m" .. "TEST PASS" .. "\27[0m") -- 验证通过：打印绿色提示
    elseif msg == "fail" then
        print("\27[31m" .. "TEST FAIL: %s\27[0m") -- 验证失败：打印红色提示
    else
        assert(false, f("Unknown msg %s", msg))
    end
end

local clock = dut.clock:chdl()

local function dut_reset()
    dut.reset:set_imm(1)
    clock:posedge(10)
    dut.reset:set_imm(0)
end

fork {
    main_task = function()
        dut_reset() -- 复位 RTL
        
        local cycles       = dut.cycles:get() -- 仿真周期计数
        local commit_count = 0                -- 累计提交指令数
        local MAX_CYCLES   = 100000           -- 最大仿真周期（防止死循环）

        while cycles < MAX_CYCLES do -- 主仿真循环
            cycles = cycles + 1
            clock:posedge()

            -- 读取 RTL 提交信号：本周期是否有指令提交
            local have_inst = dut.io_debug_wb_have_inst:get()
            if have_inst == 1 then
                -- 读取 RTL 的提交结果
                local rtl_pc    = dut.io_debug_wb_pc:get()    -- 提交指令 PC
                local rtl_ena   = dut.io_debug_wb_ena:get()   -- 寄存器写使能
                local rtl_reg   = dut.io_debug_wb_reg:get()   -- 目的寄存器编号
                local rtl_value = dut.io_debug_wb_value:get() -- 寄存器写入值
                local rtl_pc_s    = tobit(rtl_pc) -- Verilog wire 为无符号，通过 tobit 统一
                local rtl_value_s = tobit(rtl_value)

                -- 驱动参考模型执行一条指令，取出参考模型的结果
                commit_count = commit_count + 1
                local inst_commit_table = emu:commit_step(1)
                local ref = inst_commit_table[1]
                local ref_pc    = tobit(ref.pc)
                local ref_ena   = ref.reg_wen and 1 or 0
                local ref_waddr = ref.reg_waddr
                local ref_wdata = tobit(ref.reg_wdata)

                -- 打印提交日志
                print(f("[Cycle %6d]\t[Commit #%d]\tPC=%s | WEN=%d | RD=x%-2d | WDATA=%s",
                    cycles, emu.commit, to_hex(ref_pc),
                    ref_ena, ref_waddr, to_hex(ref_wdata)))
                if ref.ram_wen then
                    print(f(" | MEM[%s]=%s(mask=%d)",
                        to_hex(ref.ram_waddr), to_hex(ref.ram_wdata), ref.ram_wmask))
                end

                -- Difftest 比对逻辑
                -- 比对 PC、寄存器写使能、寄存器地址和数据
                local mismatch = (ref_pc ~= rtl_pc_s) or (ref_ena ~= rtl_ena)
                if not mismatch and ref_ena == 1 and rtl_ena == 1 then
                    mismatch = (ref_waddr ~= rtl_reg) or (ref_wdata ~= rtl_value_s)
                end

                -- 检测到不匹配：打印所有值并终止仿真
                if mismatch then
                    print(f("\n\27[31m========== DIFFTEST MISMATCH ==========\27[0m"))
                    print(f("[Cycle %d] [Commit #%d]", cycles, commit_count))
                    print(f("  指令: %s @ PC=%s", to_hex(tobit(ref.inst)), to_hex(ref_pc)))
                    print(f("  REF: PC=%s  WEN=%d  RD=x%-2d  WDATA=%s",
                        to_hex(ref_pc), ref_ena, ref_waddr, to_hex(ref_wdata)))
                    print(f("  RTL: PC=%s  WEN=%d  RD=x%-2d  WDATA=%s",
                        to_hex(rtl_pc), rtl_ena, rtl_reg, to_hex(rtl_value)))
                    print(f("\27[31m========================================\27[0m"))
                    io.flush()

                    test_print()
                    sim.finish()
                    return
                end

                -- 检测到 ECALL：程序正常结束
                if ref.ecall then
                    print(f("[INFO] 检测到 ECALL 程序正常结束: %d 个周期, %d 条指令提交", cycles, commit_count))
                    io.flush()
                    test_print("success")
                    sim.finish()
                    return
                end
            end
        end
        -- 达到最大周期数，视为运行超时
        print(f("\27[31m[ERROR] 运行超时: %d 个周期内未检测到 ECALL (共提交 %d 条指令)\27[0m", MAX_CYCLES, commit_count))
        io.flush()
        test_print("fail")
        sim.finish()
    end
}
