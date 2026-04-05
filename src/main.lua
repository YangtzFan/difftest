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
        print("\27[32m" .. [[
  _____         _____ _____
 |  __ \ /\    / ____/ ____|
 | |__) /  \  | (___| (___
 |  ___/ /\ \  \___ \\___ \
 | |  / ____ \ ____) |___) |
 |_| /_/    \_\_____/_____/
]] .. "\27[0m") -- 验证通过：打印绿色提示
    elseif msg == "fail" then
        print("\27[31mTEST FAIL\27[0m") -- 验证失败：打印红色提示
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
        -- 检查 DUMP 环境变量：如果设置了 DUMP=1，则启用 FSDB 波形记录
        -- 波形文件将保存到 build/vcs/Core 目录下，文件名基于测试用例名称
        if os.getenv("DUMP") then
            sim.dump_wave(tc)
        end

        dut_reset() -- 复位 RTL
        
        local cycles       = dut.cycles:get() -- 仿真周期计数
        local commit_count = 0                -- 累计提交指令数
        local MAX_CYCLES   = 100000           -- 最大仿真周期（防止死循环）

        while cycles < MAX_CYCLES do -- 主仿真循环
            cycles = cycles + 1
            clock:posedge()

            -- 读取 RTL 提交信号：本周期是否有指令提交
            local have_inst = dut.io_debug_commit_have_inst:get()
            if have_inst == 1 then
                -- 读取 RTL 的提交结果，通过 tobit 统一
                local rtl_pc        = tobit(dut.io_debug_commit_pc:get())
                local rtl_reg_wen   = dut.io_debug_commit_reg_wen:get()
                local rtl_reg_waddr = tobit(dut.io_debug_commit_reg_waddr:get())
                local rtl_reg_wdata = tobit(dut.io_debug_commit_reg_wdata:get())
                local rtl_ram_wen   = dut.io_debug_commit_ram_wen:get()
                local rtl_ram_waddr = tobit(dut.io_debug_commit_ram_waddr:get())
                local rtl_ram_wdata = tobit(dut.io_debug_commit_ram_wdata:get())
                local rtl_ram_wmask = dut.io_debug_commit_ram_wmask:get()

                -- 驱动参考模型执行一条指令，取出参考模型的结果
                commit_count = commit_count + 1
                local inst_commit_table = emu:commit_step(1)
                local ref = inst_commit_table[1]

                local ref_pc        = tobit(ref.pc)
                local ref_reg_wen   = ref.reg_wen and 1 or 0
                local ref_reg_waddr = tobit(ref.reg_waddr)
                local ref_reg_wdata = tobit(ref.reg_wdata)
                local ref_ram_wen   = ref.ram_wen and 1 or 0
                local ref_ram_waddr = tobit(ref.ram_waddr)
                local ref_ram_wdata = tobit(ref.ram_wdata)
                local ref_ram_wmask = ref.ram_wmask

                -- 打印提交日志
                print(f("[Cycle 0x%s] [Commit #%d] [PC=%s]", to_hex(cycles), emu.commit, to_hex(ref_pc)))
                print(f("  REF: REGWEN=%d | RD=x%-2d | REGWDATA=%s | RAMWEN=%d | RAMWADDR=%s | RAMWDATA=%s | RAMWMASK=%d",
                    ref_reg_wen, ref_reg_waddr, to_hex(ref_reg_wdata),
                    ref_ram_wen, to_hex(ref_ram_waddr), to_hex(ref_ram_wdata), ref_ram_wmask))

                -- Difftest 比对逻辑
                local mismatch = (rtl_pc ~= ref_pc)
                if ref_reg_wen == 1 then
                    mismatch = (rtl_reg_wen ~= 1) or (rtl_reg_waddr ~= ref_reg_waddr) or (rtl_reg_wdata ~= ref_reg_wdata)
                end
                if ref_ram_wen == 1 then
                    mismatch = (rtl_ram_wen ~= 1) or (rtl_ram_waddr ~= ref_ram_waddr) or (rtl_ram_wdata ~= ref_ram_wdata) or (rtl_ram_wmask ~= ref_ram_wmask)
                end

                -- 检测到不匹配：打印所有值并终止仿真
                if mismatch then
                    print(f("\27[31m========== RTL MISMATCH ==========\27[0m"))
                    print(f("[Cycle 0x%s] [Commit #%d] [PC=%s] [RTL PC=%s]", to_hex(cycles), commit_count, to_hex(ref_pc), to_hex(rtl_pc)))
                    print(f("  RTL: REGWEN=%d | RD=x%-2d | REGWDATA=%s | RAMWEN=%d | RAMWADDR=%s | RAMWDATA=%s | RAMWMASK=%d",
                    rtl_reg_wen, rtl_reg_waddr, to_hex(rtl_reg_wdata),
                    rtl_ram_wen, to_hex(rtl_ram_waddr), to_hex(rtl_ram_wdata), rtl_ram_wmask))
                    test_print("fail")
                    io.flush()
                    sim.finish()
                    return
                end

                -- 检测到 ECALL：程序正常结束
                if ref.ecall then
                    print(f("[INFO] 检测到 ECALL 程序正常结束: %d 个周期, %d 条指令提交", cycles, commit_count))
                    test_print("success")
                    io.flush()
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
