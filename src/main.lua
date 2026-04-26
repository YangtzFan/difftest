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
local tobit, band = bit.tobit, bit.band

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
 TEST PASS
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

-- ============================================================================
-- 各模块容量（与 byPass/src/main/scala/CPUConfig.scala 保持一致）
-- ----------------------------------------------------------------------------
-- 这里所有深度都与 RTL 的 CPUConfig 完全对齐；如果以后 CPUConfig 里的数值发生
-- 变化，这里也必须同步更新，否则 IPC 打印中的“分母”会失真。
-- ============================================================================
local FB_DEPTH  = 16   -- FetchBuffer    (CPUConfig.fetchBufferEntries)
local IQ_DEPTH  = 32   -- IssueQueue     (CPUConfig.issueQueueEntries)
local ROB_DEPTH = 128  -- ROB            (CPUConfig.robEntries)
local SB_DEPTH  = 16   -- StoreBuffer    (CPUConfig.sbEntries)
local SQ_DEPTH  = 16   -- AXIStoreQueue  (CPUConfig.axiSqEntries)

-- FetchBuffer/ROB 采用“环形指针多 1 位”的方案：count = (tail - head) mod 2^(idxW+1)
-- 其中指针位宽 = log2Ceil(depth) + 1，因此掩码就是 2*depth - 1。
local FB_PTR_MASK  = 2 * FB_DEPTH  - 1
local ROB_PTR_MASK = 2 * ROB_DEPTH - 1

-- ============================================================================
-- 缓存内部信号句柄
-- ----------------------------------------------------------------------------
-- 顶层 tb_top.sv 中 SoC_Top 的实例名为 u_SoC_Top；SoC_Top 内部按 Chisel 源码
-- 实际命名：coreCpu（MyCPU）、axiStoreQueue（AXIStoreQueue）。
-- MyCPU 内部：uFetchBuffer / uIssueQueue / uROB / uStoreBuffer。
-- 约定：Chisel 对于 Reg(Vec) 会发射 `<name>_<i>` 的扁平寄存器；对于 Bundle
-- 向量则发射 `<name>_<i>_<field>`，我们据此取位即可，无需改动 RTL。
-- ============================================================================
local u_soc = dut.u_SoC_Top
local u_cpu = u_soc.coreCpu

-- FetchBuffer：使用 head/tail 相减求当前占用
local sig_fb_head = u_cpu.uFetchBuffer.head
local sig_fb_tail = u_cpu.uFetchBuffer.tail

-- ROB：同样使用 head/tail 相减
local sig_rob_head = u_cpu.uROB.head
local sig_rob_tail = u_cpu.uROB.tail

-- AXIStoreQueue：内部已经维护 `count` 寄存器（RegInit），直接读取即可
local sig_sq_count = u_soc.axiStoreQueue.count

-- IssueQueue：Vec[depth] 的 validVec，每槽 1 bit；用循环求和作为占用数
local sig_iq_valid = {}
for i = 0, IQ_DEPTH - 1 do
    sig_iq_valid[i + 1] = u_cpu.uIssueQueue["validVec_" .. i]
end

-- StoreBuffer：Vec[depth] 的 buffer，需要拿每个 entry 的 valid 位
local sig_sb_valid = {}
for i = 0, SB_DEPTH - 1 do
    sig_sb_valid[i + 1] = u_cpu.uStoreBuffer["buffer_" .. i .. "_valid"]
end

-- ---------------------------------------------------------------------------
-- 占用率读取辅助函数
-- ---------------------------------------------------------------------------
local function fb_occupancy()
    -- 环形指针差：(tail - head) 可能为负，用 AND 掩码保证非负结果
    return band(sig_fb_tail:get() - sig_fb_head:get(), FB_PTR_MASK)
end

local function rob_occupancy()
    return band(sig_rob_tail:get() - sig_rob_head:get(), ROB_PTR_MASK)
end

local function iq_occupancy()
    local c = 0
    for i = 1, IQ_DEPTH do c = c + sig_iq_valid[i]:get() end
    return c
end

local function sb_occupancy()
    local c = 0
    for i = 1, SB_DEPTH do c = c + sig_sb_valid[i]:get() end
    return c
end

local function sq_occupancy()
    return sig_sq_count:get()
end

-- ============================================================================
-- 仿真数据 CSV 记录
-- ----------------------------------------------------------------------------
-- 通过环境变量 SIM_DATA_FILE 指定 CSV 输出路径（由 xmake.lua 在 before_run 中
-- 设置）。每个 test case 独占一个 CSV，记录每个时钟周期的队列占用与 IPC。
-- 列定义：cycle, fb, iq, rob, sb, sq, commits, ipc
-- 这些列名与 scripts/plot_sim.py 必须保持一致。
-- ============================================================================
local sim_data_path = os.getenv("SIM_DATA_FILE")
local sim_data_fh = nil
if sim_data_path and sim_data_path ~= "" then
    sim_data_fh = io.open(sim_data_path, "w")
    if sim_data_fh then
        sim_data_fh:write("cycle,fb,iq,rob,sb,sq,commits,ipc\n")
    end
end

-- 关闭 CSV；success/fail/timeout 三条路径都必须调用，以确保文件刷新落盘。
local function close_sim_data()
    if sim_data_fh then
        sim_data_fh:close()
        sim_data_fh = nil
    end
end

fork {
    main_task = function()
        -- 检查 DUMP 环境变量：如果设置了 DUMP=1，则启用 FSDB 波形记录
        -- 波形文件将保存到 build/vcs/Core 目录下，文件名基于测试用例名称
        if os.getenv("DUMP") then
            sim.dump_wave(tc .. ".vcd")
        end

        dut_reset() -- 复位 RTL
        
        local cycles       = dut.cycles:get() -- 仿真周期计数
        local stall        = 0
        local MAX_STALL    = 10000         -- 最大仿真周期（防止死循环）

        while true do -- 主仿真循环
            cycles = cycles + 1
            clock:posedge()

            -- ------------------------------------------------------------
            -- 本周期一开始就读取各队列占用快照，保证同一拍内多次打印值一致。
            -- 读取的是 commit 生效前 RTL 寄存器当前值；commit_step 只修改参考
            -- 模型内部状态，不会反向改变这些寄存器，所以整拍内复用即可。
            -- ------------------------------------------------------------
            local occ_fb  = fb_occupancy()
            local occ_iq  = iq_occupancy()
            local occ_rob = rob_occupancy()
            local occ_sb  = sb_occupancy()
            local occ_sq  = sq_occupancy()

            -- ------------------------------------------------------------
            -- 向 CSV 追加一条本周期的快照。
            -- commits 使用 emu.commit + commit_count_this_cycle 可能更准确，
            -- 但是 commit_step 在下面才调用，为了简单一致我们写 emu.commit：
            -- 也就是“上一拍结束时的已提交数”。绘图时这与 cycle 轴一一对应。
            -- ------------------------------------------------------------
            if sim_data_fh then
                local ipc = emu.commit / cycles
                sim_data_fh:write(f("%d,%d,%d,%d,%d,%d,%d,%.6f\n",
                    cycles, occ_fb, occ_iq, occ_rob, occ_sb, occ_sq, emu.commit, ipc))
            end

            -- 构造一个占用 + IPC 的“尾行”格式化函数。
            -- commits 参数表示截止到本次打印为止已累计的已提交指令数，传入可变值
            -- 是为了让 per-lane 日志能显示逐条递增的实时 commit 数。
            local function occupancy_line(commits)
                local ipc = commits / cycles
                return f("  Occupancy: FB=%d/%d IQ=%d/%d ROB=%d/%d SB=%d/%d SQ=%d/%d | Commits=%d Cycles=%d IPC=%.6f",
                    occ_fb,  FB_DEPTH,
                    occ_iq,  IQ_DEPTH,
                    occ_rob, ROB_DEPTH,
                    occ_sb,  SB_DEPTH,
                    occ_sq,  SQ_DEPTH,
                    commits, cycles, ipc)
            end

            -- 读取 RTL 提交信号：本周期一共有多少条指令被提交（0..commitWidth）。
            -- 配合 Vec 形式的 per-lane 信号，一拍内可验证多条指令（为未来多发射/多提交准备）。
            local commit_count = dut.io_debug_commit_count:get()
            if commit_count > 0 then
                stall = 0
                -- commitsBefore：本拍 commit_step 之前的累计提交数，用于为
                -- 每条 lane 单独计算“截至本条指令为止的总 commit 数”。
                local commitsBefore = emu.commit
                -- 让参考模型一次执行 commit_count 条指令，生成长度为 commit_count 的提交表。
                local inst_commit_table = emu:commit_step(commit_count)

                for i = 1, commit_count do
                    -- Lua 索引从 1 开始，而 RTL Vec 下标从 0 开始，lane = i - 1。
                    local lane = i - 1
                    -- 读取 RTL lane_i 的提交结果，通过 tobit 统一
                    local rtl_pc        = tobit(dut["io_debug_commit_" .. lane .. "_pc"]:get())
                    local rtl_reg_wen   = dut["io_debug_commit_" .. lane .. "_reg_wen"]:get()
                    local rtl_reg_waddr = tobit(dut["io_debug_commit_" .. lane .. "_reg_waddr"]:get())
                    local rtl_reg_wdata = tobit(dut["io_debug_commit_" .. lane .. "_reg_wdata"]:get())
                    local rtl_ram_wen   = dut["io_debug_commit_" .. lane .. "_ram_wen"]:get()
                    local rtl_ram_waddr = tobit(dut["io_debug_commit_" .. lane .. "_ram_waddr"]:get())
                    local rtl_ram_wdata = tobit(dut["io_debug_commit_" .. lane .. "_ram_wdata"]:get())
                    local rtl_ram_wmask = dut["io_debug_commit_" .. lane .. "_ram_wmask"]:get()

                    -- 取出参考模型对应的第 i 条提交记录
                    local ref = inst_commit_table[i]

                    local ref_pc        = tobit(ref.pc)
                    local ref_reg_wen   = ref.reg_wen and 1 or 0
                    local ref_reg_waddr = tobit(ref.reg_waddr)
                    local ref_reg_wdata = tobit(ref.reg_wdata)
                    local ref_ram_wen   = ref.ram_wen and 1 or 0
                    local ref_ram_waddr = tobit(ref.ram_waddr)
                    local ref_ram_wdata = tobit(ref.ram_wdata)
                    local ref_ram_wmask = ref.ram_wmask

                    -- 本拍截至当前 lane 已提交的总指令数：Commit # 为 commitsBefore + i - 1。
                    local commitsSoFar = commitsBefore + i

                    -- 打印提交日志
                    print(f("\27[33m[Cycle 0x%s] [Commit #%d] [lane %d] [PC=%s]\27[0m", to_hex(cycles), commitsSoFar - 1, lane, to_hex(ref_pc)))
                    print(f("  RTL: REGWEN=%d | RD=x%-2d | REGWDATA=%s | RAMWEN=%d | RAMWADDR=%s | RAMWDATA=%s | RAMWMASK=%d",
                        rtl_reg_wen, rtl_reg_waddr, to_hex(rtl_reg_wdata),
                        rtl_ram_wen, to_hex(rtl_ram_waddr), to_hex(rtl_ram_wdata), rtl_ram_wmask))
                    -- 每条 Commit 日志后紧跟一行占用 + IPC 摘要
                    print(occupancy_line(commitsSoFar))

                    -- 检测到 ECALL：程序正常结束
                    if ref.ecall then
                        print(f("[INFO] 检测到 ECALL 程序正常结束: %d 个周期, %d 条指令提交", cycles, emu.commit))
                        test_print("success")
                        close_sim_data()
                        io.flush()
                        sim.finish()
                        return
                    end

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
                        print(f("[Cycle 0x%s] [Commit #%d] [lane %d] [PC=%s vs RTL PC=%s]",
                            to_hex(cycles), commitsSoFar - 1, lane, to_hex(ref_pc), to_hex(rtl_pc)))
                        print(f("  REF: REGWEN=%d | RD=x%-2d | REGWDATA=%s | RAMWEN=%d | RAMWADDR=%s | RAMWDATA=%s | RAMWMASK=%d",
                        ref_reg_wen, ref_reg_waddr, to_hex(ref_reg_wdata),
                        ref_ram_wen, to_hex(ref_ram_waddr), to_hex(ref_ram_wdata), ref_ram_wmask))
                        test_print("fail")
                        close_sim_data()
                        io.flush()
                        sim.finish()
                        return
                    end
                end

            else
                stall = stall + 1
                -- 本拍无 commit：同样打印一行 cycle 头 + 占用 + IPC，方便从日志中
                -- 连续追踪各队列占用变化，分析 stall 点。
                print(f("\27[33m[Cycle 0x%s] [No Commit]\27[0m", to_hex(cycles)))
                print(occupancy_line(emu.commit))
            end

            if stall >= MAX_STALL then -- 达到最大周期数，视为运行超时
                print(f("\27[31m[ERROR] 运行超时: %d 个周期内未检测到有效指令 (共提交 %d 条指令)\27[0m", MAX_STALL, emu.commit))
                io.flush()
                test_print("fail")
                close_sim_data()
                sim.finish()
            end
        end
    end
}
