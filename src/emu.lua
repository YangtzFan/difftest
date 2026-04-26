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
local band, bor, bxor, lshift, rshift, arshift, tobit
    = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.arshift, bit.tobit
local assert = assert
local f = string.format

-- ============================================================================
-- RV32I 操作码常量定义
-- ============================================================================
local OP_LUI    = 0x37    -- U-type: 高位立即数加载（Load Upper Immediate）
local OP_AUIPC  = 0x17    -- U-type: PC 加高位立即数（Add Upper Immediate to PC）
local OP_JAL    = 0x6F    -- J-type: 跳转并链接（Jump And Link）
local OP_JALR   = 0x67    -- I-type: 寄存器间接跳转并链接
local OP_B      = 0x63    -- B-type: 条件分支（BEQ/BNE/BLT/BGE/BLTU/BGEU）
local OP_L      = 0x03    -- I-type: 从内存加载（LB/LH/LW/LBU/LHU）
local OP_S      = 0x23    -- S-type: 存储到内存（SB/SH/SW）
local OP_I      = 0x13    -- I-type: 立即数运算（ADDI/SLTI/ANDI/ORI/XORI/SLLI/SRLI/SRAI）
local OP_R      = 0x33    -- R-type: 寄存器间运算（ADD/SUB/SLL/SLT/AND/OR/XOR/SRA/SRL）
local OP_FENCE  = 0x0F    -- FENCE: 内存屏障（顺序核中视为空操作）
local OP_SYSTEM = 0x73    -- SYSTEM: ECALL/EBREAK（顺序核中视为空操作）
local DMEM_MASK = 0x3FFFF -- 地址空间使用 addr[17:0] 18 位（256KB），与硬件 DRAM 容量一致。

--- 将有符号 32 位整数转换为无符号表示
---@param x integer 有符号 32 位整数
---@return integer 无符号 32 位值（0 ~ 4294967295）
local function to_u32(x)
    if x < 0 then return x + 0x100000000 end -- 2^32
    return x
end

---@class (exact) difftest.decode_entry
---@field inst   integer 保存原始指令，用于日志输出
---@field opcode integer
---@field rd     integer inst[11:7]
---@field funct3 integer inst[14:12]
---@field rs1    integer inst[19:15]
---@field rs2    integer inst[24:20]
---@field funct7 integer inst[31:25]
---@field imm    integer

---@class (exact) difftest.commit_entry
---@field commit_index integer 当前提交指令个数
---@field pc           integer 当前指令的 PC（无符号）
---@field reg_wen      boolean 是否写寄存器
---@field reg_waddr    integer 目的寄存器编号
---@field reg_wdata    integer 寄存器写入数据
---@field ram_wen      boolean 是否写数据内存
---@field ram_waddr    integer 内存写入地址
---@field ram_wdata    integer 内存写入数据
---@field ram_wmask    integer 内存写入掩码（0=字节, 1=半字, 2=字）
---@field ecall        boolean 是否是 ECALL 指令

---@class difftest.emulator
---@field pc integer 程序计数器
---@field regs table<integer, integer> 32 个通用寄存器
---@field imem string 指令内存（二进制字节串）
---@field imem_size integer 指令内存大小（字节数）
---@field dmem table 数据内存（稀疏表）
---@field commit integer 当前时钟周期数
local emu = class() --[[@as difftest.emulator]]

-- ============================================================================
-- 寄存器读写访问
-- ============================================================================
---@param idx integer 寄存器编号 (0-31)
---@return integer 寄存器值（有符号 32 位）
function emu:read_reg(idx)
    if idx == 0 then return 0 end -- x0 始终返回 0（RISC-V 规范）
    return self.regs[idx]
end

---@param idx integer 寄存器编号 (0-31)
---@param value integer 写入值
function emu:write_reg(idx, value)
    if idx == 0 then return end -- 对 x0 的写入被静默忽略（RISC-V 规范）
    self.regs[idx] = tobit(value) -- 截断为有符号 32 位整数
end

-- ============================================================================
-- 数据内存访问
-- ============================================================================
-- 数据内存采用稀疏 Lua 表存储，未写入的地址隐含值为 0。

-- 从数据内存读取单个字节（基础函数）使用稀疏表，未写入地址返回 0
---@param addr integer 字节地址
---@return integer 字节值（0-255）
function emu:raw_read(addr)
    return self.dmem[band(addr, DMEM_MASK)] or 0
end

-- 向数据内存写入单个字节（基础函数）存储值截断为 8 位
---@param addr integer 字节地址
---@param val integer 待写入值（仅使用低 8 位）
function emu:raw_write(addr, val)
    self.dmem[band(addr, DMEM_MASK)] = band(val, 0xFF)
end

-- ====== Load 操作（读取） ======

-- LB：读取字节，符号扩展至 32 位
---@param addr integer 字节地址
---@return integer 符号扩展后的 32 位值
function emu:read_byte_signed(addr)
    local b = self:raw_read(addr)
    if b >= 128 then return b - 256 end -- 如果 bit 7 为 1（值 >= 128），进行符号扩展
    return b
end

-- LBU：读取字节，零扩展至 32 位
---@param addr integer 字节地址
---@return integer 零扩展后的 32 位值（0-255）
function emu:read_byte_unsigned(addr)
    return self:raw_read(addr) -- 高位程序自动补 0
end

--- LH：读取半字（16 位小端序），符号扩展至 32 位
---@param addr integer 半字起始地址
---@return integer 符号扩展后的 32 位值
function emu:read_half_signed(addr)
    local lo = self:raw_read(addr)      -- 低字节
    local hi = self:raw_read(addr + 1)  -- 高字节
    local h = bor(lo, lshift(hi, 8))     -- 拼装为 16 位无符号值
    -- 如果 bit 15 为 1（值 >= 32768），进行符号扩展
    if h >= 32768 then return h - 65536 end
    return h
end

--- LHU：读取半字（16 位小端序），零扩展至 32 位
---@param addr integer 半字起始地址
---@return integer 零扩展后的 32 位值（0-65535）
function emu:read_half_unsigned(addr)
    local lo = self:raw_read(addr)
    local hi = self:raw_read(addr + 1)
    return bor(lo, lshift(hi, 8)) -- 高位程序自动补 0
end

--- LW：读取字（32 位小端序）
---@param addr integer 字起始地址
---@return integer 32 位有符号整数
function emu:read_word(addr)
    local b0 = self:raw_read(addr) -- 最低字节
    local b1 = self:raw_read(addr + 1)
    local b2 = self:raw_read(addr + 2)
    local b3 = self:raw_read(addr + 3) -- 最高字节
    return tobit(bor(b0, lshift(b1, 8), lshift(b2, 16), lshift(b3, 24)))
end

-- ====== Store 操作（写入） ======

-- SB：写入字节
---@param addr integer 字节地址
---@param val integer 待写入值（仅使用低 8 位）
function emu:write_byte(addr, val)
    self:raw_write(addr, val) -- 直接将 val 的最低 8 位写入 addr 处
end

-- SH：写入半字（16 位小端序）
-- 将 val 的低 16 位按小端序写入 addr 和 addr+1
---@param addr integer 半字起始地址
---@param val integer 待写入值（仅使用低 16 位）
function emu:write_half(addr, val)
    self:raw_write(addr, band(val, 0xFF)) -- 写入 val 的低 8 位作为低字节
    self:raw_write(addr + 1, band(rshift(val, 8), 0xFF)) -- 写入 val 的 9-16 位作为高字节
end

-- SW：写入字（32 位小端序）
---@param addr integer 字起始地址
---@param val integer 待写入的 32 位值
function emu:write_word(addr, val)
    self:raw_write(addr, band(val, 0xFF)) -- byte 0（最低字节）
    self:raw_write(addr + 1, band(rshift(val, 8), 0xFF)) -- byte 1
    self:raw_write(addr + 2, band(rshift(val, 16), 0xFF)) -- byte 2
    self:raw_write(addr + 3, band(rshift(val, 24), 0xFF)) -- byte 3（最高字节）
end

-- ============================================================================
-- 初始化
-- ============================================================================
-- 加载指令二进制文件并初始化核心状态（PC=0、寄存器清零、数据内存清零）
---@param tc_name string 测试用例名称（不含 .bin 后缀）
---@param options table? 其他需要传入的参数
function emu:_init(tc_name, options)
    -- 根据当前脚本路径推算项目根目录
    -- emu.lua 位于 src/emu.lua，项目根目录 = 脚本所在目录的父目录
    local src_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
    local prj_dir = src_dir:match("^(.*/)[^/]+/$") or "./"
    -- 在 test_cases_basic / test_cases_regressive 中依次查找 <tc>.bin
    local search_subdirs = { "test_cases_basic/", "test_cases_regressive/" }
    local bin_path
    for _, sub in ipairs(search_subdirs) do
        local candidate = prj_dir .. sub .. tc_name .. ".bin"
        local fh = io.open(candidate, "rb")
        if fh then
            fh:close()
            bin_path = candidate
            break
        end
    end
    assert(bin_path, "无法打开指令文件: " .. tc_name .. ".bin (已搜索 test_cases_basic/, test_cases_regressive/)")
    local file = assert(io.open(bin_path, "rb"), "无法打开指令文件: " .. bin_path)

    self.pc = 0 -- 程序计数器，初始化为 0
    self.regs = {} -- 32 个通用寄存器，初始化为 0
    for i = 0, 31 do
        self.regs[i] = 0
    end
    self.imem = file:read("*a") -- 指令内存：从二进制文件加载全部内容
    self.imem_size = #self.imem -- 指令内存的大小
    file:close()
    self.dmem = {} -- 数据内存：稀疏表，未写入的地址默认返回 0
    self.commit = 0 -- 当前时钟周期计数

    print(f("[EMU] 模拟器初始化完成，加载测试用例: %s (%d 字节)", tc_name, self.imem_size))
end

-- ============================================================================
-- 取指
-- ============================================================================
-- 根据当前 PC [17:0] 读取 4 个字节，拼装为 32 位指令字（小端序）超出二进制文件范围的地址返回 0x0（零填充）
---@return integer 32 位指令（有符号 32 位表示）
function emu:fetch()
    local pc = self.pc
    
    local effective_pc = band(pc, 0x3FFFC) -- 保留 PC[17:0]，低 2 位清空（4 字节对齐）
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
-- 对 32 位指令进行完整译码
-- 提取所有字段并生成五类立即数（I/S/B/U/J），覆盖 RV32I 全部基础指令
---@param inst integer 32 位指令
---@return difftest.decode_entry 译码结果表（包含 opcode、rd、rs1、rs2、funct3、funct7、各类立即数）
function emu:decode(inst)
    local opcode = band(inst, 0x7F) -- inst[6:0]
    local d = {
        inst = inst, -- 保存原始指令，用于日志输出
        -- 基础字段提取
        opcode = opcode,
        rd     = band(rshift(inst, 7), 0x1F), -- inst[11:7]
        funct3 = band(rshift(inst, 12), 0x07), -- inst[14:12]
        rs1    = band(rshift(inst, 15), 0x1F), -- inst[19:15]
        rs2    = band(rshift(inst, 20), 0x1F), -- inst[24:20]
        funct7 = band(rshift(inst, 25), 0x7F), -- inst[31:25]
        imm    = 0,
    } --[[@as difftest.decode_entry]]

    -- 生成立即数
    if opcode == OP_LUI or opcode == OP_AUIPC then
        -- U 型立即数（用于 LUI/AUIPC）
        -- inst[31:12] 置于高 20 位，低 12 位为 0
        d.imm = tobit(band(inst, 0xFFFFF000))
    elseif opcode == OP_JALR or opcode == OP_L or opcode == OP_I then
        -- I 型立即数（用于 S-type/L-type/JALR）
        d.imm = arshift(inst, 20) -- inst[31:20] 符号扩展至 32 位
    elseif opcode == OP_S then
        -- S 型立即数（用于 SB/SH/SW）
        d.imm = bor(d.rd, lshift(d.funct7, 5))-- 由 inst[31:25] 和 inst[11:7] 拼装
        if band(d.imm, 0x800) ~= 0 then
            d.imm = tobit(bor(d.imm, 0xFFFFF000)) -- 从 bit 11（即 inst[31]）符号扩展至 32 位
        end
    elseif opcode == OP_B then
        -- B 型立即数（用于 BEQ/BNE/BLT/BGE/BLTU/BGEU）
        -- inst[31]、inst[30:25]、inst[11:8]、inst[7]拼装，imm[0] 始终为 0（半字对齐）
        local b_11   = band(rshift(inst, 7), 1)      -- inst[7]     → imm[11]
        local b_4_1  = band(rshift(inst, 8), 0xF)    -- inst[11:8]  → imm[4:1]
        local b_10_5 = band(rshift(inst, 25), 0x3F)  -- inst[30:25] → imm[10:5]
        local b_12   = rshift(inst, 31) -- inst[31]    → imm[12]（逻辑右移取最高位）
        d.imm = bor(
            lshift(b_4_1, 1),    -- imm[4:1]  置于 bit 1-4
            lshift(b_10_5, 5),   -- imm[10:5] 置于 bit 5-10
            lshift(b_11, 11),    -- imm[11]   置于 bit 11
            lshift(b_12, 12)     -- imm[12]   置于 bit 12
        )
        if b_12 == 1 then -- 从 bit 12 符号扩展至 32 位
            d.imm = tobit(bor(d.imm, 0xFFFFE000))
        end
    elseif opcode == OP_JAL then
        -- J 型立即数（用于 JAL）
        -- inst[31]、inst[30:21]、inst[20]、inst[19:12] 拼装，imm[0] 始终为 0（半字对齐）
        local j_19_12 = band(rshift(inst, 12), 0xFF)    -- inst[19:12] → imm[19:12]
        local j_11    = band(rshift(inst, 20), 1)        -- inst[20]    → imm[11]
        local j_10_1  = band(rshift(inst, 21), 0x3FF)   -- inst[30:21] → imm[10:1]
        local j_20    = rshift(inst, 31)                 -- inst[31]    → imm[20]
        d.imm = bor(
            lshift(j_10_1, 1),    -- imm[10:1]  置于 bit 1-10
            lshift(j_11, 11),     -- imm[11]    置于 bit 11
            lshift(j_19_12, 12),  -- imm[19:12] 置于 bit 12-19
            lshift(j_20, 20)      -- imm[20]    置于 bit 20
        )
        -- 从 bit 20 符号扩展至 32 位
        if j_20 == 1 then
            d.imm = tobit(bor(d.imm, 0xFFE00000))
        end
    elseif opcode == OP_R or opcode == OP_SYSTEM or opcode == OP_FENCE then
        d.imm = 0
    else
        assert(false, f("[EMU] Unknown opcode %d", opcode))
    end

    return d
end

-- ============================================================================
-- 指令执行
-- ============================================================================
-- 执行一条 RV32I 指令并生成提交记录，根据译码结果更新模拟机架构状态，返回提交信息供 difftest 比对使用
---@param d difftest.decode_entry 译码结果（由 decode 方法生成）
---@return difftest.commit_entry commit 提交记录
function emu:execute(d)
    local pc     = self.pc
    local opcode = d.opcode
    local rd     = d.rd
    local rs1    = d.rs1
    local rs2    = d.rs2
    local funct3 = d.funct3
    local funct7 = d.funct7

    -- 读取源寄存器值
    local rs1_val = self:read_reg(rs1)
    local rs2_val = self:read_reg(rs2)

    -- 提交记录：默认值
    local commit = {
        commit_index = self.commit, -- 当前提交指令序数
        pc           = pc,          -- 当前指令的 PC（无符号）
        reg_wen      = false,       -- 是否写寄存器
        reg_waddr    = 0,           -- 目的寄存器编号
        reg_wdata    = 0,           -- 寄存器写入数据
        ram_wen      = false,       -- 是否写数据内存
        ram_waddr    = 0,           -- 内存写入地址
        ram_wdata    = 0,           -- 内存写入数据
        ram_wmask    = 0,           -- 内存写入掩码（0=字节, 1=半字, 2=字）
        ecall        = false        -- 是否是 ECALL 指令
    } --[[@as difftest.commit_entry]]

    local next_pc = to_u32(tobit(pc + 4)) -- 下一条 PC 默认 +4（分支指令则自行更新）
    local rd_val   = 0 -- 目的寄存器写入值（默认为 0，等待后续程序更新）
    local write_rd = false -- 指令类型是否需要写寄存器（默认不写入，等待后续程序更新）

    -- ================================================================
    -- 指令分发与执行
    -- ================================================================
    if opcode == OP_LUI then
        -- LUI：将 U 型立即数加载到目的寄存器高 20 位
        rd_val   = d.imm
        write_rd = true
    elseif opcode == OP_AUIPC then
        -- AUIPC：将 U 型立即数加上当前 PC，结果写入目的寄存器
        rd_val   = tobit(pc + d.imm)
        write_rd = true
    elseif opcode == OP_JAL then
        -- JAL：跳转到 PC + J 型立即数偏移，链接地址（PC+4）写入 rd
        rd_val   = tobit(pc + 4)   -- 链接地址（返回地址）
        write_rd = true
        next_pc  = to_u32(tobit(pc + d.imm))
    elseif opcode == OP_JALR then
        -- JALR：跳转到 (rs1 + I 型立即数) & ~1，链接地址写入 rd
        rd_val   = tobit(pc + 4)
        write_rd = true
        next_pc  = to_u32(band(rs1_val + d.imm, 0xFFFFFFFE))
    elseif opcode == OP_B then
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
            error(f("[EMU] 未知分支指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        if taken then
            next_pc = to_u32(tobit(pc + d.imm))
        end
        -- 分支指令不写寄存器（write_rd 保持 false）
    elseif opcode == OP_L then
        -- 从数据内存加载数据到目的寄存器
        local addr   = tobit(rs1_val + d.imm) -- 有效地址 = rs1 + I 型偏移
        local loaded = 0
        if funct3 == 0 then         -- LB: 读取 1 字节，符号扩展
            loaded = self:read_byte_signed(addr)
        elseif funct3 == 1 then     -- LH: 读取 2 字节，符号扩展
            loaded = self:read_half_signed(addr)
        elseif funct3 == 2 then     -- LW: 读取 4 字节
            loaded = self:read_word(addr)
        elseif funct3 == 4 then     -- LBU: 读取 1 字节，零扩展
            loaded = self:read_byte_unsigned(addr)
        elseif funct3 == 5 then     -- LHU: 读取 2 字节，零扩展
            loaded = self:read_half_unsigned(addr)
        else
            error(f("[EMU] 未知加载指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        rd_val   = loaded
        write_rd = true

    elseif opcode == OP_S then
        -- 将寄存器数据存储到数据内存
        local addr = tobit(rs1_val + d.imm) -- 有效地址 = rs1 + S 型偏移
        if funct3 == 0 then         -- SB: 写入 1 字节（rs2 的最低 8 位）
            self:write_byte(addr, rs2_val)
        elseif funct3 == 1 then     -- SH: 写入 2 字节（rs2 的最低 16 位）
            self:write_half(addr, rs2_val)
        elseif funct3 == 2 then     -- SW: 写入 4 字节（rs2 完整 32 位）
            self:write_word(addr, rs2_val)
        else
            error(f("[EMU] 未知存储指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        -- 记录 RAM 写入信息，供提交记录使用
        commit.ram_wen   = true
        commit.ram_waddr = addr       -- 写入地址
        commit.ram_wdata = rs2_val    -- 写入数据（完整 rs2 值）
        commit.ram_wmask = funct3     -- 掩码编码与 funct3 一致（0=B, 1=H, 2=W）
        -- 存储指令不写寄存器（write_rd 保持 false）

    elseif opcode == OP_I then
        -- 立即数运算指令
        local imm = d.imm
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
            error(f("[EMU] 未知立即数运算指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        write_rd = true

    elseif opcode == OP_R then
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
            error(f("[EMU] 未知寄存器运算指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        write_rd = true

    elseif opcode == OP_FENCE then
        assert(false, "[EMU] 不支持解析 FENCE 指令")
        -- ============================================================
        -- FENCE: 内存顺序指令
        -- 在顺序单发射核中无实际效果，PC 正常 +4
        -- ============================================================
    elseif opcode == OP_SYSTEM then
        -- ============================================================
        -- ECALL/EBREAK: 系统调用/断点
        -- ECALL (inst == 0x00000073) 标记为程序正常结束信号
        -- PC 正常 +4（不影响流水线提交行为）
        -- ============================================================
        if d.inst == 0x00000073 then
            commit.ecall = true
        end

    else
        assert(false, "[EMU] 未知指令")
        -- ============================================================
        -- 未识别的操作码：视为空操作（NOP）
        -- RTL 对未识别指令也会正常通过流水线提交，regWen=false
        -- 常见场景：指令内存超出程序范围的区域被零填充（0x00000000）
        -- ============================================================
    end

    if write_rd then
        self:write_reg(rd, rd_val) -- 写回寄存器， x0 写入自动忽略
        commit.reg_wen   = true
        commit.reg_waddr = rd
        commit.reg_wdata = tobit(rd_val)
    end

    self.pc = next_pc -- 更新 PC
    return commit
end

-- ============================================================================
-- 主步进接口
-- ============================================================================
-- 每次调用将按 ISA 顺序执行 inst_commit_count 条指令，更新内部架构状态，为每条指令生成一个提交记录项。
---@nodiscard
---@param inst_commit_count integer 本周期需要提交的指令数
---@return table<integer, difftest.commit_entry> 提交记录表
function emu:commit_step(inst_commit_count)
    local inst_commit_table = {} --[[@as table<integer, difftest.commit_entry>]]

    for i = 1, inst_commit_count do
        self.commit = self.commit + 1    -- 递增周期计数
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
