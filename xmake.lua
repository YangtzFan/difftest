---@diagnostic disable: undefined-global, undefined-field

-- ============================================================================
-- Difftest 验证框架构建配置
-- ============================================================================
-- 基于 Verilua 的多发射核 Difftest 验证框架
-- 通过 RV32I 参考模型（Lua 实现）与 RTL 仿真输出进行逐指令比对
-- ============================================================================

local prj_dir = os.curdir()
local tc_dir = path.join(prj_dir, "test_cases")            -- 测试用例目录
local src_dir = path.join(prj_dir, "src")                  -- Lua 源码目录
local rtl_prj_dir = "/home/litian/Documents/stageFiles/studyplace/byPass"           -- Chisel RTL 子项目
local build_dir = path.join(prj_dir, "build")              -- 构建产物目录
local rtl_dir = path.join(build_dir, "Core")               -- 生成的 RTL 目录

local sim = os.getenv("SIM") or "vcs"

-- IROM 的 hex 文件固定路径，用于运行时动态加载测试用例到 RTL 的 IROM
local irom_hex = path.join(rtl_dir, "irom.hex")

-- ============================================================================
-- target: init —— 初始化子模块
-- ============================================================================
target("init", function()
    set_kind("phony")
    set_default(false)
    local function isempty(v)
        return v == nil or v == ""
    end
    local default_proxy = os.getenv("default_proxy_LAN")
    local http          = os.getenv("http_proxy")
    local https         = os.getenv("https_proxy")
    local isProxyEmpty  = isempty(http) or isempty(https)
    local autoSetProxy  = false

    before_run(function()
        if (isProxyEmpty) then
            cprint("${yellow underline}[WARNING]${clear} http_proxy and https_proxy have not been set.")
            if (isempty(default_proxy)) then
                cprint("${red underline}[SEVERE]${clear} There are no proxy set. Initialization operation failed.")
                local msg = format("Initialization failed")
                raise(msg)
            else
                autoSetProxy = true
            end
        end
    end)

    on_run(function()
        if (autoSetProxy) then
            local envs          = {}
            envs["http_proxy"]  = default_proxy
            envs["https_proxy"] = default_proxy
            os.addenvs(envs)
            cprint(
                "${green underline}[INFO] Default proxy has been set. Proxy has been configured automatically.${clear}")
        end
        cprint("${green underline}[INFO] Updating submodules in this repo... This may take a few seconds.${clear}")
        os.exec("git submodule update --init")
    end)
end)

-- ============================================================================
-- target: rtl —— 从 Chisel 生成 SystemVerilog RTL
-- ============================================================================
-- 生成后会对 RTL 进行后处理：
--   1. 替换 assert 和 $fwrite 输出端口
--   2. 替换 mem_16384x128.sv 中 $readmemh 的路径为固定的 irom.hex 路径
--      这样切换测试用例只需更新 hex 文件，无需重新编译 RTL 或 VCS
-- ============================================================================
target("rtl", function()
    set_kind("phony")
    on_build(function()
        import("core.base.task")

        -- 清理旧的构建产物
        os.tryrm(path.join(rtl_prj_dir, "build", "*"))
        os.tryrm(path.join(rtl_prj_dir, "out", "*.dep"))

        -- 在 byPass 子目录中执行 Chisel → SystemVerilog 编译
        os.cd(rtl_prj_dir)
        os.exec("xmake run -P . rtl")

        -- 将生成的 RTL 文件复制到 build/Core/
        os.tryrm(rtl_dir)
        os.mkdir(rtl_dir)
        os.cp(path.join(rtl_prj_dir, "build", "rtl", "*"), rtl_dir)

        -- 收集所有 .sv 文件
        local vfiles = {}
        table.join2(vfiles, os.files(path.join(rtl_dir, "*.sv")))
        table.join2(vfiles, os.files(path.join(rtl_dir, "*", "*.sv")))

        for _, f in ipairs(vfiles) do
            -- 将 Chisel 生成的 assert(1'b0) 替换为 VCS 兼容的 $fatal
            io.replace(f, "assert(1'b0)", "$fatal", { plain = true })
            -- 将断言输出从 stderr (0x80000002) 重定向到 stdout (0x80000001)
            -- 确保断言信息能被仿真日志捕获
            io.replace(f, "$fwrite(32'h80000002", "$fwrite(32'h80000001", { plain = true })
        end

        -- ============================================================
        -- 替换 mem_16384x128.sv 中的 $readmemh 路径
        -- ============================================================
        -- Chisel 编译时使用了占位 hex 文件，此处将其替换为固定的 irom.hex 路径
        -- 运行时只需更新 irom.hex 即可切换测试用例，无需重新编译 RTL 或 VCS
        local mem_sv = path.join(rtl_dir, "mem_16384x128.sv")
        if os.isfile(mem_sv) then
            local abs_hex_path = path.absolute(irom_hex)
            -- 使用正则匹配替换 $readmemh 中的文件路径（匹配引号间的任意内容）
            io.replace(mem_sv, '$readmemh%(".-"', '$readmemh("' .. abs_hex_path .. '"')
            cprint("${green underline}[INFO]${clear} 已替换 mem_16384x128.sv 中的 $readmemh 路径: %s", abs_hex_path)
        else
            cprint("${yellow underline}[WARNING]${clear} 未找到 mem_16384x128.sv，跳过 IROM 路径替换")
        end
    end)
end)

-- ============================================================================
-- target: run —— 运行 Difftest 仿真
-- ============================================================================
-- 通过环境变量 TC 指定测试用例（不含 .bin 后缀），默认为 "and"
-- 运行前自动将 .bin 转换为 .hex 并写入 IROM 固定路径
-- 测试用例同时加载到 RTL（通过 $readmemh）和模拟器（通过 Lua IO）
-- 用法：
--   xmake build Core              # 编译验证组建
--   xmake run Core                # 运行默认测试用例 (and)
--   TC=add xmake run Core         # 运行 add 测试用例
--   DUMP=1 TC=beq xmake Core      # 运行 beq 并输出波形
-- ============================================================================
target("Core", function()
    set_default(true)
    add_rules("verilua")

    if sim == "verilator" then
        add_toolchains("@verilator")
    elseif sim == "vcs" then 
        add_toolchains("@vcs")
    end

    add_files(
        path.join(src_dir, "*.lua"),
        path.join(rtl_dir, "*.sv"),
        path.join(rtl_dir, "verification", "*.sv"),
        path.join(rtl_dir, "verification", "assert", "*.sv"),
        path.join(rtl_dir, "verification", "assume", "*.sv"),
        path.join(rtl_dir, "verification", "cover", "*.sv")
    )

    set_values("cfg.build_dir_name", "Core")
    set_values("cfg.top", "SoC_Top")
    add_values("cfg.tb_gen_flags", 
        "+incdir+" .. path.join(rtl_dir, "verification"),
        "+incdir+" .. path.join(rtl_dir, "verification", "assert"),
        "+incdir+" .. path.join(rtl_dir, "verification", "assume"),
        "+incdir+" .. path.join(rtl_dir, "verification", "cover"),
        "--single-unit"
    )

    add_values("vcs.flags", "+define+ASSERT_VERBOSE_CO0_test_for_smokeND_=1", "+define+STOP_COND_=1")
    add_values("vcs.flags",
        "+incdir+" .. path.join(SNF_dir, "verification"),
        "+incdir+" .. path.join(SNF_dir, "verification", "assert"),
        "+incdir+" .. path.join(SNF_dir, "verification", "assume"),
        "+incdir+" .. path.join(SNF_dir, "verification", "cover")
    )

    add_values("verilator.flags", "+define+ASSERT_VERBOSE_CO0_test_for_smokeND_=1", "+define+STOP_COND_=1")
    add_values("verilator.flags",
        "+incdir+" .. path.join(rtl_dir, "verification"),
        "+incdir+" .. path.join(rtl_dir, "verification", "assert"),
        "+incdir+" .. path.join(rtl_dir, "verification", "assume"),
        "+incdir+" .. path.join(rtl_dir, "verification", "cover"),
        "--trace", "--no-trace-top", "--threads 4"
    )

    -- ============================================================
    -- 运行前钩子：将 .bin 转换为 .hex 写入 IROM 固定路径
    -- ============================================================
    -- 每次运行时都会执行，确保 IROM 内容与当前测试用例一致
    -- 转换规则：
    --   1. 读取 .bin 文件中的全部字节
    --   2. 补齐到 16 字节（128 位 = 4 条 32 位指令）的整数倍
    --   3. 每 16 字节输出一行 32 个十六进制字符
    --   4. 每行格式（高位到低位）：word3 word2 word1 word0
    --      对应 128 位数据的 [127:96] [95:64] [63:32] [31:0]
    --   5. 每个 word 从 4 字节小端序读取
    before_run(function()
        local tc_name = os.getenv("TC")
        if not tc_name or tc_name == "" then 
            tc_name = "and"
            os.setenv("TC", "and")
        end
        local bin_file = path.join(tc_dir, tc_name .. ".bin")
        if not os.isfile(bin_file) then
            raise("测试用例未找到: " .. bin_file)
        end
        os.mkdir(rtl_dir)

        -- ========================================================
        -- 准备仿真数据 CSV 输出路径：build/sim-data/<case>.csv
        -- 以绝对路径通过环境变量 SIM_DATA_FILE 传给 main.lua，避免
        -- main.lua 运行时的工作目录与项目根不一致导致路径错乱。
        -- ========================================================
        local sim_data_dir  = path.join(build_dir, "sim-data")
        os.mkdir(sim_data_dir)
        local sim_data_file = path.absolute(path.join(sim_data_dir, tc_name .. ".csv"))
        os.setenv("SIM_DATA_FILE", sim_data_file)
        cprint("${green underline}[INFO]${clear} 每周期数据将写入: %s", sim_data_file)

        -- 读取二进制文件
        local fh = assert(io.open(bin_file, "rb"))
        local data = fh:read("*a")
        fh:close()

        -- 补齐到 16 字节边界
        local rem = #data % 16
        if rem ~= 0 then
            data = data .. string.rep("\0", 16 - rem)
        end

        -- 逐 16 字节（4 条指令）转换为一行 hex
        local lines = {}
        for i = 1, #data, 16 do
            local words = {}
            for w = 0, 3 do
                local offset = i + w * 4
                local b0 = data:byte(offset)
                local b1 = data:byte(offset + 1)
                local b2 = data:byte(offset + 2)
                local b3 = data:byte(offset + 3)
                words[w] = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
            end
            -- 输出顺序：word3 word2 word1 word0（高位在前）
            lines[#lines + 1] = string.format("%08x%08x%08x%08x", words[3], words[2], words[1], words[0])
        end

        -- 写入 hex 文件到 IROM 固定路径
        local out = assert(io.open(irom_hex, "w"))
        out:write(table.concat(lines, "\n") .. "\n")
        out:close()

        cprint("${green underline}[INFO]${clear} 已将测试用例 '%s' 转换为 hex: %s", tc_name, irom_hex)
    end)
    
    set_values("cfg.lua_main", path.join(src_dir, "main.lua"))
end)

-- ============================================================================
-- target: sim-all —— 批量运行所有测试用例
-- ============================================================================
-- 遍历 test_cases/ 目录下所有 .bin 文件，逐个运行 difftest 仿真。
-- 判定标准：子进程 stdout 中包含 "ECALL"（表示参考模型检测到 ECALL 而正常结束）。
-- 本 target 不再落地仿真日志文件，也不再生成 summary.txt，只在终端输出简洁汇总。
-- 但每个用例的每周期占用/IPC 数据仍然由 Core 仿真自动写入 build/sim-data/<case>.csv，
-- 供 scripts/plot_sim.py 绘图使用（见 clean 目标也会清理该目录）。
-- ============================================================================
target("sim-all", function()
    set_kind("phony")
    set_default(false)
    on_run(function()
        -- 收集所有测试用例并排序
        local bin_files = os.files(path.join(tc_dir, "*.bin"))
        table.sort(bin_files)

        if #bin_files == 0 then
            raise("test_cases 目录下未找到任何 .bin 文件")
        end

        local passed = {}
        local failed = {}

        cprint("${cyan underline}[INFO]${clear} 开始运行 %d 个测试用例", #bin_files)

        -- 逐个运行测试用例：用 popen 捕获 stdout 到内存，读完即丢弃
        for _, bin_file in ipairs(bin_files) do
            local case_name = path.basename(bin_file)  -- 不含 .bin 后缀的文件名

            -- 使用 xmake 内置的 os.iorunv 在子进程中运行仿真，捕获 stdout 到内存；
            -- 通过 envs 选项向子进程注入 TC 环境变量。xmake 沙箱禁用 io.popen/pcall，
            -- 因此改用 os.iorunv + try{} 模式。子进程非零退出会抛异常，在 catch 中
            -- 把异常字符串（通常包含 stdout）当作日志扫描即可。
            local log_text = ""
            try {
                function()
                    local stdout, stderr = os.iorunv("xmake",
                        {"r", "Core"}, {envs = {TC = case_name}})
                    log_text = (stdout or "") .. (stderr or "")
                end,
                catch {
                    function(errors)
                        log_text = tostring(errors or "")
                    end
                }
            }

            local pass_mark = (log_text:find("ECALL", 1, true) ~= nil)
            if pass_mark then
                table.insert(passed, case_name)
            else
                table.insert(failed, case_name)
            end
        end

        -- ============================================================
        -- 终端输出简洁汇总（不写任何文件）
        -- ============================================================
        cprint("${green underline}[INFO]${clear} 通过 (%d): %s",
            #passed, #passed > 0 and table.concat(passed, ", ") or "(none)")
        if #failed > 0 then
            cprint("${red underline}[INFO]${clear} 失败 (%d): %s", #failed, table.concat(failed, ", "))
            raise(string.format("sim-all 完成，%d 个测试用例失败", #failed))
        else
            cprint("${green underline}[INFO]${clear} 失败 (%d): %s", #failed, "(none)")
        end
    end)
end)

-- ============================================================================
-- target: clean —— 清理构建产物和仿真中间文件
-- ============================================================================
-- 删除以下内容：
--   - build/vcs/Core/sim_build/     VCS 编译产物
--   - build/vcs/Core/*.fsdb*        FSDB 波形文件及其附属文件
--   - build/vcs/Core/*.log          仿真日志
--   - build/vcs/Core/*.key          Verdi 密钥文件
--   - build/sim-all/                批量仿真输出目录
--   - build/Core/irom.hex           运行时生成的 IROM hex 文件
-- ============================================================================
target("clean", function()
    set_kind("phony")
    set_default(false)
    on_run(function()
        local vcs_dir = path.join(build_dir, "vcs", "Core")

        -- 清理 VCS 编译产物
        os.tryrm(path.join(vcs_dir, "sim_build"))
        cprint("${green underline}[INFO]${clear} 已清理 VCS 编译产物: sim_build/")

        -- 清理 FSDB 波形文件（*.fsdb 及其附属文件 *.fsdb.*）
        local fsdb_files = os.files(path.join(vcs_dir, "*.fsdb*"))
        for _, f in ipairs(fsdb_files) do
            os.tryrm(f)
        end
        if #fsdb_files > 0 then
            cprint("${green underline}[INFO]${clear} 已清理 %d 个 FSDB 波形文件", #fsdb_files)
        end

        -- 清理仿真日志
        local log_files = os.files(path.join(vcs_dir, "*.log"))
        for _, f in ipairs(log_files) do
            os.tryrm(f)
        end

        -- 清理 Verdi 密钥文件
        local key_files = os.files(path.join(vcs_dir, "*.key"))
        for _, f in ipairs(key_files) do
            os.tryrm(f)
        end

        -- 清理批量仿真输出（旧版 sim-all 可能残留）
        os.tryrm(path.join(build_dir, "sim-all"))
        cprint("${green underline}[INFO]${clear} 已清理批量仿真输出: sim-all/")

        -- 清理每周期仿真数据（占用 + IPC 的 CSV）
        os.tryrm(path.join(build_dir, "sim-data"))
        cprint("${green underline}[INFO]${clear} 已清理仿真数据: sim-data/")

        -- 清理运行时生成的 IROM hex 文件
        os.tryrm(irom_hex)
        cprint("${green underline}[INFO]${clear} 已清理 IROM hex 文件")

        cprint("${green underline}[INFO]${clear} 清理完成")
    end)
end)
