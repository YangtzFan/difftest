-- ============================================================================
-- 模拟器 (Emulator) —— RV32I 参考模型
-- ============================================================================
-- 支持运行 RV32I 所有 37 条基础指令。clock_step 函数传入提交的指令个数，
-- 返回所有提交的指令信息，供 difftest 框架进行比对。
--
-- 本模块将以下功能整合为单一 class（由 pl.class 创建）：
--   状态管理   —— PC、通用寄存器（x0-x31）、指令/数据内存、周期计数
--   取指与译码 —— 从指令内存取出 32 位指令，解析 RV32I 全部字段和立即数
--   指令执行   —— 执行 RV32I 全部 37 条基础指令并生成提交记录
--   内存访问   —— Load/Store 操作（字节/半字/字，小端序）
-- ============================================================================

local class = require "pl.class"

local bit = require "bit"
local band, bor, bxor, lshift, rshift, arshift =
    bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.arshift
local tobit = bit.tobit
local f = string.format

-- ============================================================================
-- 数据内存访问辅助函数（局部函数，性能优先）
-- ============================================================================
-- 数据内存采用稀疏 Lua 表存储，未写入的地址隐含值为 0。
-- 地址空间为 18 位（256KB），与硬件 DRAM 容量一致。

-- 18 位地址掩码：硬件 DRAM 使用 addr[17:0]，共 256KB
local DMEM_MASK = 0x3FFFF

--- 从数据内存读取单个字节（原始无符号值 0-255）
-- 使用稀疏表，未写入地址返回 0
---@param dmem table 数据内存稀疏表
---@param addr integer 字节地址
---@return integer 字节值（0-255）
local function raw_read(dmem, addr)
    return dmem[band(addr, DMEM_MASK)] or 0
end

--- 向数据内存写入单个字节
-- 存储值截断为 8 位
---@param dmem table 数据内存稀疏表
---@param addr integer 字节地址
---@param val integer 待写入值（仅使用低 8 位）
local function raw_write(dmem, addr, val)
    dmem[band(addr, DMEM_MASK)] = band(val, 0xFF)
end

-- ====== Load 操作（读取） ======

--- LB：读取字节，符号扩展至 32 位
-- 读取 addr 处的 1 字节，bit 7 为符号位，扩展至 32 位有符号整数
---@param dmem table 数据内存稀疏表
---@param addr integer 字节地址
---@return integer 符号扩展后的 32 位值
local function read_byte_signed(dmem, addr)
    local b = raw_read(dmem, addr)
    -- 如果 bit 7 为 1（值 >= 128），进行符号扩展
    if b >= 128 then return b - 256 end
    return b
end

--- LBU：读取字节，零扩展至 32 位
-- 读取 addr 处的 1 字节，高位补 0
---@param dmem table 数据内存稀疏表
---@param addr integer 字节地址
---@return integer 零扩展后的 32 位值（0-255）
local function read_byte_unsigned(dmem, addr)
    return raw_read(dmem, addr)
end

--- LH：读取半字（16 位小端序），符号扩展至 32 位
-- 读取 addr 和 addr+1 两个字节，拼装为 16 位值后符号扩展
---@param dmem table 数据内存稀疏表
---@param addr integer 半字起始地址
---@return integer 符号扩展后的 32 位值
local function read_half_signed(dmem, addr)
    local lo = raw_read(dmem, addr)      -- 低字节
    local hi = raw_read(dmem, addr + 1)  -- 高字节
    local h = bor(lo, lshift(hi, 8))     -- 拼装为 16 位无符号值
    -- 如果 bit 15 为 1（值 >= 32768），进行符号扩展
    if h >= 32768 then return h - 65536 end
    return h
end

--- LHU：读取半字（16 位小端序），零扩展至 32 位
-- 读取 addr 和 addr+1 两个字节，拼装为 16 位值后高位补 0
---@param dmem table 数据内存稀疏表
---@param addr integer 半字起始地址
---@return integer 零扩展后的 32 位值（0-65535）
local function read_half_unsigned(dmem, addr)
    local lo = raw_read(dmem, addr)
    local hi = raw_read(dmem, addr + 1)
    return bor(lo, lshift(hi, 8))
end

--- LW：读取字（32 位小端序）
-- 读取 addr 到 addr+3 共 4 个字节，拼装为 32 位有符号整数
---@param dmem table 数据内存稀疏表
---@param addr integer 字起始地址
---@return integer 32 位有符号整数
local function read_word(dmem, addr)
    local b0 = raw_read(dmem, addr)      -- 最低字节
    local b1 = raw_read(dmem, addr + 1)
    local b2 = raw_read(dmem, addr + 2)
    local b3 = raw_read(dmem, addr + 3)  -- 最高字节
    return tobit(bor(b0, lshift(b1, 8), lshift(b2, 16), lshift(b3, 24)))
end

-- ====== Store 操作（写入） ======

--- SB：写入字节
-- 将 val 的最低 8 位写入 addr 处
---@param dmem table 数据内存稀疏表
---@param addr integer 字节地址
---@param val integer 待写入值（仅使用低 8 位）
local function write_byte(dmem, addr, val)
    raw_write(dmem, addr, val)
end

--- SH：写入半字（16 位小端序）
-- 将 val 的低 16 位按小端序写入 addr 和 addr+1
---@param dmem table 数据内存稀疏表
---@param addr integer 半字起始地址
---@param val integer 待写入值（仅使用低 16 位）
local function write_half(dmem, addr, val)
    raw_write(dmem, addr,     band(val, 0xFF))             -- 低字节
    raw_write(dmem, addr + 1, band(rshift(val, 8), 0xFF))  -- 高字节
end

--- SW：写入字（32 位小端序）
-- 将 val 的全部 32 位按小端序写入 addr 到 addr+3
---@param dmem table 数据内存稀疏表
---@param addr integer 字起始地址
---@param val integer 待写入的 32 位值
local function write_word(dmem, addr, val)
    raw_write(dmem, addr,     band(val, 0xFF))              -- byte 0（最低字节）
    raw_write(dmem, addr + 1, band(rshift(val, 8), 0xFF))   -- byte 1
    raw_write(dmem, addr + 2, band(rshift(val, 16), 0xFF))  -- byte 2
    raw_write(dmem, addr + 3, band(rshift(val, 24), 0xFF))  -- byte 3（最高字节）
end

-- ============================================================================
-- RV32I 操作码常量定义
-- ============================================================================
local OP_LUI    = 0x37   -- U-type: 高位立即数加载（Load Upper Immediate）
local OP_AUIPC  = 0x17   -- U-type: PC 加高位立即数（Add Upper Immediate to PC）
local OP_JAL    = 0x6F   -- J-type: 跳转并链接（Jump And Link）
local OP_JALR   = 0x67   -- I-type: 寄存器间接跳转并链接
local OP_BRANCH = 0x63   -- B-type: 条件分支（BEQ/BNE/BLT/BGE/BLTU/BGEU）
local OP_LOAD   = 0x03   -- I-type: 从内存加载（LB/LH/LW/LBU/LHU）
local OP_STORE  = 0x23   -- S-type: 存储到内存（SB/SH/SW）
local OP_IMM    = 0x13   -- I-type: 立即数运算（ADDI/SLTI/ANDI/ORI/XORI/SLLI/SRLI/SRAI）
local OP_REG    = 0x33   -- R-type: 寄存器间运算（ADD/SUB/SLL/SLT/AND/OR/XOR/SRA/SRL）
local OP_FENCE  = 0x0F   -- FENCE: 内存屏障（顺序核中视为空操作）
local OP_SYSTEM = 0x73   -- SYSTEM: ECALL/EBREAK（顺序核中视为空操作）

--- 将有符号 32 位整数转换为无符号表示
-- 用于无符号比较（SLTU/BLTU/BGEU/SLTIU）和 PC 地址计算
---@param x integer 有符号 32 位整数
---@return integer 无符号 32 位值（0 ~ 4294967295）
local function to_u32(x)
    if x < 0 then return x + 0x100000000 end -- 2^32
    return x
end

-- ============================================================================
-- 模拟器类定义
-- ============================================================================

---@class difftest.emulator
---@field pc integer 程序计数器
---@field regs table<integer, integer> 32 个通用寄存器
---@field imem string 指令内存（二进制字节串）
---@field imem_size integer 指令内存大小（字节数）
---@field dmem table 数据内存（稀疏表）
---@field cycle integer 当前时钟周期数
local emu = class() --[[@type difftest.emulator]]

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化模拟器
-- 加载指令二进制文件并初始化核心状态（PC=0、寄存器清零、数据内存清零）
---@param tc_name string 测试用例名称（不含 .bin 后缀）
---@param options table? 其他需要传入的参数
function emu:_init(tc_name, options)
    -- 根据当前脚本路径推算项目根目录
    -- emu.lua 位于 src/emu.lua，项目根目录 = 脚本所在目录的父目录
    local src_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
    local prj_dir = src_dir:match("^(.*/)[^/]+/$") or "./"
    -- 构建二进制文件路径：<项目根>/test_cases/<tc_name>.bin
    local bin_path = prj_dir .. "test_cases/" .. tc_name .. ".bin"

    -- 程序计数器，初始化为 0
    self.pc = 0

    -- 32 个通用寄存器，初始化为 0
    self.regs = {}
    for i = 0, 31 do
        self.regs[i] = 0
    end

    -- 指令内存：从二进制文件加载全部内容
    local file = assert(io.open(bin_path, "rb"), "无法打开指令文件: " .. bin_path)
    self.imem = file:read("*a")
    self.imem_size = #self.imem
    file:close()

    -- 数据内存：稀疏表，未写入的地址默认返回 0
    self.dmem = {}

    -- 当前时钟周期计数
    self.cycle = 0

    print(f("[EMU] 模拟器初始化完成，加载测试用例: %s (%d 字节)", tc_name, self.imem_size))
end

-- ============================================================================
-- 寄存器访问
-- ============================================================================

--- 读取通用寄存器
---@param idx integer 寄存器编号 (0-31)
---@return integer 寄存器值（有符号 32 位）
function emu:read_reg(idx)
    if idx == 0 then return 0 end -- x0 始终返回 0（RISC-V 规范）
    return self.regs[idx]
end

--- 写入通用寄存器
---@param idx integer 寄存器编号 (0-31)
---@param value integer 写入值
function emu:write_reg(idx, value)
    if idx == 0 then return end -- 对 x0 的写入被静默忽略（RISC-V 规范）
    self.regs[idx] = tobit(value) -- 截断为有符号 32 位整数
end

-- ============================================================================
-- 取指
-- ============================================================================

--- 从指令内存中取出一条 32 位指令（小端序）
-- 根据当前 PC 读取 4 个字节，拼装为 32 位指令字
-- PC 地址按 18 位回绕（与 RTL 的 IROM 256KB 地址空间一致）
-- 超出二进制文件范围的地址返回 0x00000000（零填充）
---@return integer 32 位指令（有符号 32 位表示）
function emu:fetch()
    local pc = self.pc
    -- 只保留 18 位地址空间（0x00000 ~ 0x3FFFF），低 2 位清空（4 字节对齐）
    local effective_pc = band(pc, 0x3FFFC)
    -- 若超出二进制文件范围，返回全零（NOP）
    if effective_pc + 3 >= self.imem_size then
        return 0
    end

    -- 从小端序字节流中读取 32 位指令
    -- 注意：Lua 字符串索引从 1 开始，故 effective_pc 需要 +1
    local imem = self.imem
    local b0 = imem:byte(effective_pc + 1) -- 最低字节 inst[7:0]
    local b1 = imem:byte(effective_pc + 2) -- inst[15:8]
    local b2 = imem:byte(effective_pc + 3) -- inst[23:16]
    local b3 = imem:byte(effective_pc + 4) -- 最高字节 inst[31:24]

    return tobit(bor(b0, lshift(b1, 8), lshift(b2, 16), lshift(b3, 24)))
end

-- ============================================================================
-- 译码
-- ============================================================================

--- 对 32 位指令进行完整译码
-- 提取所有字段并生成五类立即数（I/S/B/U/J），覆盖 RV32I 全部基础指令
---@param inst integer 32 位指令
---@return table 译码结果表（包含 opcode、rd、rs1、rs2、funct3、funct7、各类立即数）
function emu:decode(inst)
    local d = {}

    d.inst = inst -- 保存原始指令，用于日志输出

    -- 基础字段提取（使用标准位运算，所有指令格式通用）
    d.opcode = band(inst, 0x7F)              -- inst[6:0]   操作码（7 位）
    d.rd     = band(rshift(inst, 7), 0x1F)   -- inst[11:7]  目的寄存器（5 位）
    d.funct3 = band(rshift(inst, 12), 0x07)  -- inst[14:12] 功能码 3（3 位）
    d.rs1    = band(rshift(inst, 15), 0x1F)  -- inst[19:15] 源寄存器 1（5 位）
    d.rs2    = band(rshift(inst, 20), 0x1F)  -- inst[24:20] 源寄存器 2（5 位）
    d.funct7 = band(rshift(inst, 25), 0x7F)  -- inst[31:25] 功能码 7（7 位）

    -- I 型立即数（用于 ADDI/SLTI/Load/JALR）
    -- inst[31:20] 符号扩展至 32 位
    d.imm_i = arshift(inst, 20)

    -- S 型立即数（用于 SB/SH/SW）
    -- 由 inst[31:25]（imm[11:5]）和 inst[11:7]（imm[4:0]）拼装
    local s_4_0  = band(rshift(inst, 7), 0x1F)    -- inst[11:7]  → imm[4:0]
    local s_11_5 = band(rshift(inst, 25), 0x7F)   -- inst[31:25] → imm[11:5]
    d.imm_s = bor(s_4_0, lshift(s_11_5, 5))       -- 拼装 12 位原始值
    -- 从 bit 11（即 inst[31]）符号扩展至 32 位
    if band(d.imm_s, 0x800) ~= 0 then
        d.imm_s = tobit(bor(d.imm_s, 0xFFFFF000))
    end

    -- B 型立即数（用于 BEQ/BNE/BLT/BGE/BLTU/BGEU）
    -- 由 inst[31]（imm[12]）、inst[30:25]（imm[10:5]）、
    --    inst[11:8]（imm[4:1]）、inst[7]（imm[11]）拼装
    -- 注意：imm[0] 始终为 0（半字对齐）
    local b_11   = band(rshift(inst, 7), 1)      -- inst[7]     → imm[11]
    local b_4_1  = band(rshift(inst, 8), 0xF)    -- inst[11:8]  → imm[4:1]
    local b_10_5 = band(rshift(inst, 25), 0x3F)  -- inst[30:25] → imm[10:5]
    local b_12   = rshift(inst, 31)               -- inst[31]    → imm[12]（逻辑右移取最高位）
    d.imm_b = bor(
        lshift(b_4_1, 1),    -- imm[4:1]  置于 bit 1-4
        lshift(b_10_5, 5),   -- imm[10:5] 置于 bit 5-10
        lshift(b_11, 11),    -- imm[11]   置于 bit 11
        lshift(b_12, 12)     -- imm[12]   置于 bit 12
    )
    -- 从 bit 12 符号扩展至 32 位
    if b_12 == 1 then
        d.imm_b = tobit(bor(d.imm_b, 0xFFFFE000))
    end

    -- U 型立即数（用于 LUI/AUIPC）
    -- inst[31:12] 置于高 20 位，低 12 位为 0
    d.imm_u = tobit(band(inst, 0xFFFFF000))

    -- J 型立即数（用于 JAL）
    -- 由 inst[31]（imm[20]）、inst[30:21]（imm[10:1]）、
    --    inst[20]（imm[11]）、inst[19:12]（imm[19:12]）拼装
    -- 注意：imm[0] 始终为 0（半字对齐）
    local j_19_12 = band(rshift(inst, 12), 0xFF)    -- inst[19:12] → imm[19:12]
    local j_11    = band(rshift(inst, 20), 1)        -- inst[20]    → imm[11]
    local j_10_1  = band(rshift(inst, 21), 0x3FF)   -- inst[30:21] → imm[10:1]
    local j_20    = rshift(inst, 31)                 -- inst[31]    → imm[20]
    d.imm_j = bor(
        lshift(j_10_1, 1),    -- imm[10:1]  置于 bit 1-10
        lshift(j_11, 11),     -- imm[11]    置于 bit 11
        lshift(j_19_12, 12),  -- imm[19:12] 置于 bit 12-19
        lshift(j_20, 20)      -- imm[20]    置于 bit 20
    )
    -- 从 bit 20 符号扩展至 32 位
    if j_20 == 1 then
        d.imm_j = tobit(bor(d.imm_j, 0xFFE00000))
    end

    return d
end

-- ============================================================================
-- 指令执行
-- ============================================================================

--- 执行一条 RV32I 指令并生成提交记录
-- 根据译码结果更新模拟器的寄存器、内存和 PC 状态，
-- 同时返回提交信息供 difftest 比对使用
--
-- 覆盖 RV32I 全部 37 条基础指令（不含 FENCE/ECALL/EBREAK 等特权指令，
-- 这些在顺序单发射核中视为空操作处理）
--
-- 执行流程：
--   1. 读取源寄存器值
--   2. 根据操作码分发到对应指令处理逻辑
--   3. 计算结果并更新寄存器/内存/PC
--   4. 生成提交记录（commit record）
---@param d table 译码结果（由 decode 方法生成）
---@return table commit 提交记录
function emu:execute(d)
    local pc     = self.pc
    local opcode = d.opcode
    local rd     = d.rd
    local rs1    = d.rs1
    local rs2    = d.rs2
    local funct3 = d.funct3
    local funct7 = d.funct7
    local dmem   = self.dmem -- 数据内存引用，传给局部内存函数

    -- 读取源寄存器值（x0 恒为 0）
    local rs1_val = self:read_reg(rs1)
    local rs2_val = self:read_reg(rs2)

    -- 提交记录：默认值
    local commit = {
        clock_cycle = self.cycle,   -- 当前时钟周期
        pc          = pc,           -- 当前指令的 PC（无符号）
        inst        = d.inst,       -- 原始指令字（用于日志）
        reg_wen     = false,        -- 是否写寄存器
        reg_waddr   = 0,            -- 目的寄存器编号
        reg_wdata   = 0,            -- 寄存器写入数据
        ram_wen     = false,        -- 是否写数据内存
        ram_waddr   = 0,            -- 内存写入地址
        ram_wdata   = 0,            -- 内存写入数据
        ram_wmask   = 0,            -- 内存写入掩码（0=字节, 1=半字, 2=字）
    }

    -- 下一条 PC 默认 +4（顺序执行）
    local next_pc = to_u32(tobit(pc + 4))

    -- 目的寄存器写入值和写使能标志
    local rd_val   = 0
    local write_rd = false -- 指令类型是否需要写寄存器

    -- ================================================================
    -- 指令分发与执行
    -- ================================================================

    if opcode == OP_LUI then
        -- LUI：将 U 型立即数加载到目的寄存器高 20 位
        rd_val   = d.imm_u
        write_rd = true

    elseif opcode == OP_AUIPC then
        -- AUIPC：将 U 型立即数加上当前 PC，结果写入目的寄存器
        rd_val   = tobit(pc + d.imm_u)
        write_rd = true

    elseif opcode == OP_JAL then
        -- JAL：跳转到 PC + J 型立即数偏移，链接地址（PC+4）写入 rd
        rd_val   = tobit(pc + 4)   -- 链接地址（返回地址）
        write_rd = true
        next_pc  = to_u32(tobit(pc + d.imm_j))

    elseif opcode == OP_JALR then
        -- JALR：跳转到 (rs1 + I 型立即数) & ~1，链接地址写入 rd
        rd_val   = tobit(pc + 4)
        write_rd = true
        next_pc  = to_u32(band(rs1_val + d.imm_i, 0xFFFFFFFE))

    elseif opcode == OP_BRANCH then
        -- 条件分支：根据比较结果决定是否跳转到 PC + B 型偏移
        local taken = false
        if funct3 == 0 then         -- BEQ: 相等时跳转
            taken = (rs1_val == rs2_val)
        elseif funct3 == 1 then     -- BNE: 不等时跳转
            taken = (rs1_val ~= rs2_val)
        elseif funct3 == 4 then     -- BLT: 有符号小于时跳转
            taken = (rs1_val < rs2_val)
        elseif funct3 == 5 then     -- BGE: 有符号大于等于时跳转
            taken = (rs1_val >= rs2_val)
        elseif funct3 == 6 then     -- BLTU: 无符号小于时跳转
            taken = (to_u32(rs1_val) < to_u32(rs2_val))
        elseif funct3 == 7 then     -- BGEU: 无符号大于等于时跳转
            taken = (to_u32(rs1_val) >= to_u32(rs2_val))
        else
            error(f("未知分支指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        if taken then
            next_pc = to_u32(tobit(pc + d.imm_b))
        end
        -- 分支指令不写寄存器（write_rd 保持 false）

    elseif opcode == OP_LOAD then
        -- 从数据内存加载数据到目的寄存器
        local addr   = tobit(rs1_val + d.imm_i) -- 有效地址 = rs1 + I 型偏移
        local loaded = 0
        if funct3 == 0 then         -- LB: 读取 1 字节，符号扩展
            loaded = read_byte_signed(dmem, addr)
        elseif funct3 == 1 then     -- LH: 读取 2 字节，符号扩展
            loaded = read_half_signed(dmem, addr)
        elseif funct3 == 2 then     -- LW: 读取 4 字节
            loaded = read_word(dmem, addr)
        elseif funct3 == 4 then     -- LBU: 读取 1 字节，零扩展
            loaded = read_byte_unsigned(dmem, addr)
        elseif funct3 == 5 then     -- LHU: 读取 2 字节，零扩展
            loaded = read_half_unsigned(dmem, addr)
        else
            error(f("未知加载指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        rd_val   = loaded
        write_rd = true

    elseif opcode == OP_STORE then
        -- 将寄存器数据存储到数据内存
        local addr = tobit(rs1_val + d.imm_s) -- 有效地址 = rs1 + S 型偏移
        if funct3 == 0 then         -- SB: 写入 1 字节（rs2 的最低 8 位）
            write_byte(dmem, addr, rs2_val)
        elseif funct3 == 1 then     -- SH: 写入 2 字节（rs2 的最低 16 位）
            write_half(dmem, addr, rs2_val)
        elseif funct3 == 2 then     -- SW: 写入 4 字节（rs2 完整 32 位）
            write_word(dmem, addr, rs2_val)
        else
            error(f("未知存储指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        -- 记录 RAM 写入信息，供提交记录使用
        commit.ram_wen   = true
        commit.ram_waddr = addr       -- 写入地址
        commit.ram_wdata = rs2_val    -- 写入数据（完整 rs2 值）
        commit.ram_wmask = funct3     -- 掩码编码与 funct3 一致（0=B, 1=H, 2=W）
        -- 存储指令不写寄存器（write_rd 保持 false）

    elseif opcode == OP_IMM then
        -- 立即数运算指令
        local imm = d.imm_i
        if funct3 == 0 then         -- ADDI: rd = rs1 + imm
            rd_val = tobit(rs1_val + imm)
        elseif funct3 == 2 then     -- SLTI: rd = (rs1 < imm) ? 1 : 0 （有符号比较）
            rd_val = (rs1_val < imm) and 1 or 0
        elseif funct3 == 3 then     -- SLTIU: rd = (rs1 < imm) ? 1 : 0 （无符号比较）
            rd_val = (to_u32(rs1_val) < to_u32(imm)) and 1 or 0
        elseif funct3 == 4 then     -- XORI: rd = rs1 ^ imm
            rd_val = bxor(rs1_val, imm)
        elseif funct3 == 6 then     -- ORI: rd = rs1 | imm
            rd_val = bor(rs1_val, imm)
        elseif funct3 == 7 then     -- ANDI: rd = rs1 & imm
            rd_val = band(rs1_val, imm)
        elseif funct3 == 1 then     -- SLLI: rd = rs1 << shamt（逻辑左移）
            local shamt = band(imm, 0x1F) -- 移位量取低 5 位
            rd_val = lshift(rs1_val, shamt)
        elseif funct3 == 5 then     -- SRLI/SRAI: 根据 funct7 区分逻辑/算术右移
            local shamt = band(imm, 0x1F)
            if funct7 == 0x20 then  -- SRAI: 算术右移（保留符号位）
                rd_val = arshift(rs1_val, shamt)
            else                    -- SRLI: 逻辑右移（高位补 0）
                rd_val = rshift(rs1_val, shamt)
            end
        else
            error(f("未知立即数运算指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        write_rd = true

    elseif opcode == OP_REG then
        -- 寄存器间运算指令
        if funct3 == 0 then
            if funct7 == 0x20 then  -- SUB: rd = rs1 - rs2
                rd_val = tobit(rs1_val - rs2_val)
            else                    -- ADD: rd = rs1 + rs2
                rd_val = tobit(rs1_val + rs2_val)
            end
        elseif funct3 == 1 then     -- SLL: rd = rs1 << rs2[4:0]（逻辑左移）
            rd_val = lshift(rs1_val, band(rs2_val, 0x1F))
        elseif funct3 == 2 then     -- SLT: rd = (rs1 < rs2) ? 1 : 0 （有符号比较）
            rd_val = (rs1_val < rs2_val) and 1 or 0
        elseif funct3 == 3 then     -- SLTU: rd = (rs1 < rs2) ? 1 : 0 （无符号比较）
            rd_val = (to_u32(rs1_val) < to_u32(rs2_val)) and 1 or 0
        elseif funct3 == 4 then     -- XOR: rd = rs1 ^ rs2
            rd_val = bxor(rs1_val, rs2_val)
        elseif funct3 == 5 then
            if funct7 == 0x20 then  -- SRA: rd = rs1 >> rs2[4:0]（算术右移）
                rd_val = arshift(rs1_val, band(rs2_val, 0x1F))
            else                    -- SRL: rd = rs1 >> rs2[4:0]（逻辑右移）
                rd_val = rshift(rs1_val, band(rs2_val, 0x1F))
            end
        elseif funct3 == 6 then     -- OR: rd = rs1 | rs2
            rd_val = bor(rs1_val, rs2_val)
        elseif funct3 == 7 then     -- AND: rd = rs1 & rs2
            rd_val = band(rs1_val, rs2_val)
        else
            error(f("未知寄存器运算指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        write_rd = true

    elseif opcode == OP_FENCE then
        -- ============================================================
        -- FENCE: 内存顺序指令
        -- 在顺序单发射核中无实际效果，PC 正常 +4
        -- ============================================================

    elseif opcode == OP_SYSTEM then
        -- ============================================================
        -- ECALL/EBREAK: 系统调用/断点
        -- 在顺序单发射核中视为空操作，PC 正常 +4
        -- ============================================================

    else
        -- ============================================================
        -- 未识别的操作码：视为空操作（NOP）
        -- RTL 对未识别指令也会正常通过流水线提交，regWen=false
        -- 常见场景：指令内存超出程序范围的区域被零填充（0x00000000）
        -- ============================================================
    end

    -- ================================================================
    -- 寄存器写回
    -- ================================================================
    -- 根据 RTL 行为：regWriteEnable 仅取决于指令类型，
    -- 不检查 rd 是否为 x0。x0 的写入在 write_reg 内部被忽略。
    -- 这与硬件的 Rename 阶段行为一致：
    --   regWriteEnable = uType || jal || jalr || lType || iType || rType
    if write_rd then
        self:write_reg(rd, rd_val)   -- x0 写入自动忽略
        commit.reg_wen   = true
        commit.reg_waddr = rd
        commit.reg_wdata = tobit(rd_val)
    end

    -- ================================================================
    -- 更新 PC
    -- ================================================================
    self.pc = next_pc
    return commit
end

-- ============================================================================
-- 主步进接口
-- ============================================================================

--- 执行指定数量的指令，返回提交记录表
-- 每次调用将按 ISA 顺序执行 inst_commit_count 条指令，
-- 更新内部架构状态（PC、寄存器、数据内存），
-- 并为每条指令生成一个提交记录项。
---@nodiscard
---@param inst_commit_count integer 本周期需要提交的指令数
---@return table 提交记录表
function emu:clock_step(inst_commit_count)
    local inst_commit_table = {}

    for i = 1, inst_commit_count do
        self.cycle = self.cycle + 1      -- 递增周期计数
        local inst    = self:fetch()     -- 第一步：取指
        local decoded = self:decode(inst)  -- 第二步：译码
        local commit  = self:execute(decoded) -- 第三步：执行
        inst_commit_table[i] = commit    -- 将提交记录添加到返回表
    end

    -- 返回的提交记录数量必须等于请求数量
    assert(inst_commit_count == #inst_commit_table)
    return inst_commit_table
end

return emu
