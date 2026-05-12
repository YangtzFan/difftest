---@diagnostic disable: undefined-global, undefined-field

-- ============================================================================
-- Difftest 验证框架构建配置
-- ============================================================================
-- 基于 Verilua 的多发射核 Difftest 验证框架
-- 通过 RV32I 参考模型（Lua 实现）与 RTL 仿真输出进行逐指令比对
-- ============================================================================

local prj_dir = os.curdir()
local tc_basic_dir      = path.join(prj_dir, "test_cases_basic")      -- 基础测试用例目录
local tc_regressive_dir = path.join(prj_dir, "test_cases_regressive") -- 回归测试用例目录
local tc_pressure_dir   = path.join(prj_dir, "test_cases_pressure")   -- 压力测试用例目录（仅供 sim-single 使用）
local src_dir = path.join(prj_dir, "src")                  -- Lua 源码目录
local rtl_prj_dir = "/nfs/home/zhanghang/Documents/byPass"           -- Chisel RTL 子项目
local build_dir = path.join(prj_dir, "build")             -- 构建产物目录
local rtl_dir = path.join(build_dir, "Core")              -- 生成的 RTL 目录
-- TIMEOUT 处理：
--   - 未设置 / 非法值 -> 默认 600 秒
--   - 显式设置为 0    -> 禁用超时检测（用例可无限运行）
--   - 正整数           -> 单例最长执行时间（秒）
local timeout_sec = tonumber(os.getenv("TIMEOUT"))
if timeout_sec == nil then timeout_sec = 600 end
if timeout_sec <= 0 then timeout_sec = 0 end

local sim = os.getenv("SIM") or "vcs"

-- 仿真日志与每周期 CSV 的统一输出目录
local sim_log_dir  = path.join(build_dir, "sim-log")
local sim_data_dir = path.join(build_dir, "sim-data")

-- IROM 的 hex 文件固定路径，用于运行时动态加载测试用例到 RTL 的 IROM
local irom_hex = path.join(rtl_dir, "irom.hex")
-- DRAM 的 hex 文件固定路径（v18 / TD-INDIR-B 新增）
-- 背景：原仿真壳层只把 .bin 装入 IROM，DRAM 启动全 0；-O0 编译产物在 .rodata
-- 段的只读数据（如 indirect_call_debug 的 OPS 函数指针表）读出全 0，触发架构性活循环。
-- 修复：把 .bin 同步生成 dram.hex（每行一个 32-bit 字，按字地址 0,1,2,... 顺序），
-- 并在 mem_65536x32.sv 中注入 $readmemh initial，使 DRAM 与 IROM 共享物理映像。
local dram_hex = path.join(rtl_dir, "dram.hex")

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
            cprint("${yellow underline}[WARNING]${clear} 未找到 mem_16384x128.sv  跳过 IROM 路径替换")
        end

        -- ============================================================
        -- v18 / TD-INDIR-B：向 mem_65536x32.sv（DRAM 物理阵列）注入 $readmemh
        -- ============================================================
        -- DRAM.scala 用的是普通 Mem(...)，FIRRTL 不会自动生成 readmemh 占位；
        -- 这里用文本注入：在 "always @(posedge W0_clk)" 之前插入 initial 块，
        -- 使 RTL 启动时把 dram.hex（与 .bin 等价的 32-bit 字流）预载入 Memory。
        -- 这样 RTL 数据 load 才能命中 .rodata / .data 段，与 emu.lua 的 dmem 预载对齐。
        local dram_mem_sv = path.join(rtl_dir, "mem_65536x32.sv")
        if os.isfile(dram_mem_sv) then
            local abs_dram_hex = path.absolute(dram_hex)
            io.replace(dram_mem_sv,
                'reg [31:0] Memory[0:65535];',
                string.format('reg [31:0] Memory[0:65535];\n  initial $readmemh("%s", Memory);', abs_dram_hex),
                { plain = true })
            cprint("${green underline}[INFO]${clear} 已向 mem_65536x32.sv 注入 DRAM $readmemh: %s", abs_dram_hex)
        else
            cprint("${yellow underline}[WARNING]${clear} 未找到 mem_65536x32.sv  跳过 DRAM 预载注入")
        end
    end)
end)

-- ============================================================================
-- target: Core —— Difftest 仿真后端入口
-- ============================================================================
-- 通过环境变量 TC 指定测试用例（不含 .bin 后缀），默认为 "and"
-- 运行前自动将 .bin 转换为 .hex 并写入 IROM 固定路径
-- 测试用例同时加载到 RTL（通过 $readmemh）和模拟器（通过 Lua IO）
--
-- 用法（直接调用 Core，原生交互式输出，不落盘日志）：
--   xmake build Core              # 编译验证组件
--   xmake run Core                # 运行默认测试用例 (and)
--   TC=add xmake run Core         # 运行 add 测试用例
--   DUMP=1 TC=beq xmake r Core    # 运行 beq 并输出波形
--   TIMEOUT=10 TC=foo xmake r Core # 单例最长 10 秒，超时强制终止
--   TIMEOUT=0  TC=foo xmake r Core # 禁用超时检测，用例可无限运行
--
-- 推荐的单用例命令（标准化输出，自动落盘 log + CSV）：
--   xmake run sim-single TC=<case>
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
        "+incdir+" .. path.join(rtl_dir, "verification"),
        "+incdir+" .. path.join(rtl_dir, "verification", "assert"),
        "+incdir+" .. path.join(rtl_dir, "verification", "assume"),
        "+incdir+" .. path.join(rtl_dir, "verification", "cover")
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

        -- ========================================================
        -- TIMEOUT 监测：单例 watchdog
        -- - timeout_sec > 0：启动后台守护进程，超时后向 xmake 进程组发送 SIGTERM/SIGKILL；
        -- - timeout_sec == 0：禁用，用例可无限运行（用户通过 TIMEOUT=0 显式选择）；
        -- 通过 setsid 将守护进程脱离当前会话，使其在 xmake 退出后仍能存活；
        -- 超时触发时，先在 stderr 上输出与批量 runner 风格一致的中文提示，
        -- 再发 SIGTERM 优雅终止，宽限 5 秒后发 SIGKILL 兜底强杀。
        -- 守护进程在动手前先校验目标 PID 是否仍存在 (kill -0)，避免 PID 复用误杀。
        -- 注意：xmake 被杀后无法再调用 cprint 渲染颜色，因此守护进程直接发送 ANSI 转义码：
        --   \033[33;4m -> 黄色 + 下划线
        --   \033[31;4m -> 红色 + 下划线
        --   \033[0m    -> 复位样式
        -- ========================================================
        if timeout_sec > 0 then
            local self_pid = os.getpid()  -- 当前 xmake 进程 PID（一般也是其进程组组长）
            local timeout_msg = string.format(
                "\\033[33;4m[INFO]\\033[0m [sim-single] 耗时过长: %s | \\033[31;4m用例编写不合理!\\033[0m\\n",
                tc_name)
            local watchdog_cmd = string.format(
                "( sleep %d ; if kill -0 %d 2>/dev/null ; then " ..
                "printf '%s' >&2 ; " ..
                "kill -TERM -%d 2>/dev/null || kill -TERM %d 2>/dev/null ; " ..
                "sleep 5 ; kill -KILL -%d 2>/dev/null || kill -KILL %d 2>/dev/null ; fi ) " ..
                "</dev/null &",
                timeout_sec, self_pid, timeout_msg,
                self_pid, self_pid, self_pid, self_pid)
            os.execv("setsid", {"sh", "-c", watchdog_cmd})
        end

        -- 在 test_cases_basic / test_cases_regressive / test_cases_pressure 三个目录中
        -- 依次查找 <TC>.bin。压力用例只允许通过单跑接入仿真，不会被纳入 sim-basic/sim-regressive。
        local search_dirs = { tc_basic_dir, tc_regressive_dir, tc_pressure_dir }
        local bin_file
        for _, d in ipairs(search_dirs) do
            local candidate = path.join(d, tc_name .. ".bin")
            if os.isfile(candidate) then
                bin_file = candidate
                break
            end
        end
        if not bin_file then
            raise(string.format("测试用例未找到: %s.bin (已搜索: %s, %s, %s)",
                tc_name, tc_basic_dir, tc_regressive_dir, tc_pressure_dir))
        end
        os.mkdir(rtl_dir)

        -- ========================================================
        -- 准备仿真数据 CSV 输出路径：build/sim-data/<case>.csv（同名覆盖）
        -- 以绝对路径通过环境变量 SIM_DATA_FILE 传给 main.lua，避免 main.lua
        -- 运行时的工作目录与项目根不一致导致路径错乱。
        -- ========================================================
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

        -- ========================================================
        -- v18 / TD-INDIR-B：同步生成 dram.hex
        -- ========================================================
        -- DRAM 物理阵列为 64K × 32-bit 字（mem_65536x32），$readmemh 默认从地址 0 开始
        -- 顺序填入。每行写一个 32-bit word（小端打包），这样 byte 偏移 0..3 → 第 0 行字、
        -- byte 偏移 4..7 → 第 1 行字……与 .bin 物理布局一致。
        -- 仅指令段对应的字也会被写入 DRAM，但 IROM 走另一通道，互不影响。
        local dram_lines = {}
        for i = 1, #data, 4 do
            local b0 = data:byte(i)
            local b1 = data:byte(i + 1)
            local b2 = data:byte(i + 2)
            local b3 = data:byte(i + 3)
            local word = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
            dram_lines[#dram_lines + 1] = string.format("%08x", word)
        end
        local dout = assert(io.open(dram_hex, "w"))
        dout:write(table.concat(dram_lines, "\n") .. "\n")
        dout:close()
        cprint("${green underline}[INFO]${clear} 已将测试用例 '%s' 转换为 dram hex: %s", tc_name, dram_hex)
    end)
    
    set_values("cfg.lua_main", path.join(src_dir, "main.lua"))
end)

-- ============================================================================
-- 运行测试用例的工厂函数 _make_runner(mode, label, dir)
-- ============================================================================
-- 返回的闭包将被赋给 on_run，由 xmake 在运行时绑定到 script-scope 沙箱，
-- 因此可以在闭包内自由使用 os.mkdir / os.iorunv / os.time / try-catch 等 API。
-- 内部 inline 定义 run_one：执行单个用例 + 落盘日志 + 判定通过/超时/失败，
-- 被 sim-single 和 sim-basic/sim-regressive 三个 target 共用，避免重复代码。
--
-- 通过 os.iorunv 启动子 xmake 跑 Core target，捕获 stdout+stderr 写入日志：
--   - timeout_sec > 0：用系统 `timeout` 命令包裹，超时退出码 124/137；
--   - timeout_sec == 0：不包裹 `timeout`，子进程可无限运行；
-- 判定通过：日志包含 "ECALL"（参考模型正常退出标志）。
-- 落盘路径：build/sim-log/<case>.log（"w" 模式覆盖）。
--
-- mode = "single"  --> 运行 TC 环境变量指定的单个用例（默认 "and"）
-- mode = "batch"   --> 遍历 dir/*.bin 批量运行
-- ============================================================================
local function _make_runner(mode, label, dir)
    return function()
        -- ---------- 内部 helper：跑单个用例 ----------
        local function run_one(case_name)
            os.mkdir(sim_log_dir)
            local log_path = path.join(sim_log_dir, case_name .. ".log")

            -- 给子 xmake 注入环境变量：TC 指定用例名，SIM 指定后端
            os.setenv("TC", case_name)
            os.setenv("SIM", sim)

            local log_text = ""
            local err_text = ""
            local t0 = os.time()
            try {
                function()
                    local stdout, stderr
                    if timeout_sec > 0 then
                        -- 用 `timeout` 命令包裹子 xmake，超时 SIGTERM；
                        -- --kill-after=5 表示 5 秒宽限期后仍未退出则 SIGKILL。
                        -- timeout 自身约定：被 SIGTERM 杀返回 124，被 SIGKILL 杀返回 137。
                        stdout, stderr = os.iorunv("timeout",
                            {"--kill-after=5", tostring(timeout_sec), "xmake", "r", "Core"})
                    else
                        -- TIMEOUT=0：禁用外部超时，子进程可无限运行（适合压力测试）
                        stdout, stderr = os.iorunv("xmake", {"r", "Core"})
                    end
                    log_text = (stdout or "") .. (stderr or "")
                end,
                catch {
                    function(errors)
                        err_text = tostring(errors or "")
                        log_text = err_text
                    end
                }
            }
            local elapsed = os.time() - t0

            -- 落盘完整日志（"w" 覆盖同名旧文件）
            local lf, lerr = io.open(log_path, "w")
            if lf then
                lf:write(log_text or "")
                lf:close()
            else
                cprint("${yellow underline}[WARNING]${clear} 无法写入日志 %s: %s",
                    log_path, tostring(lerr))
            end

            local pass = (log_text:find("ECALL", 1, true) ~= nil)
            -- 仅在 timeout_sec>0 模式下才考虑超时；
            -- 通过 timeout 命令的退出码或实际墙钟时长两路判定。
            local is_timeout = (not pass) and timeout_sec > 0 and (
                err_text:find("exit: 124", 1, true) ~= nil or
                err_text:find("exit: 137", 1, true) ~= nil or
                elapsed >= timeout_sec
            )
            return { pass = pass, is_timeout = is_timeout, log_path = log_path, elapsed = elapsed }
        end

        -- ---------- 分支：单例 vs 批量 ----------
        if mode == "single" then
            local case_name = os.getenv("TC")
            if not case_name or case_name == "" then case_name = "and" end

            if timeout_sec > 0 then
                cprint("${cyan underline}[INFO]${clear} [sim-single] 运行用例: %s (最长 %ds)",
                    case_name, timeout_sec)
            else
                cprint("${cyan underline}[INFO]${clear} [sim-single] 运行用例: %s (TIMEOUT=0，禁用超时)",
                    case_name)
            end

            local r = run_one(case_name)
            cprint("${green underline}[INFO]${clear} [sim-single] 日志: %s", r.log_path)
            if r.pass then
                cprint("${green underline}[INFO]${clear} [sim-single] 通过: %s (耗时 %ds)",
                    case_name, r.elapsed)
            elseif r.is_timeout then
                cprint("${yellow underline}[INFO]${clear} [sim-single] 耗时过长: %s | ${red underline}用例编写不合理!${clear}",
                    case_name)
                raise(string.format("sim-single 超时: %s", case_name))
            else
                cprint("${red underline}[INFO]${clear} [sim-single] 失败: %s (耗时 %ds，查看日志 %s)",
                    case_name, r.elapsed, r.log_path)
                raise(string.format("sim-single 失败: %s", case_name))
            end
            return
        end

        -- mode == "batch"
        local bin_files = os.files(path.join(dir, "*.bin"))
        table.sort(bin_files)

        if #bin_files == 0 then
            raise(string.format("%s 目录下未找到任何 .bin 文件", dir))
        end

        os.mkdir(sim_log_dir)

        local passed     = {}
        local failed     = {}
        local timeouted  = {}

        if timeout_sec > 0 then
            cprint("${cyan underline}[INFO]${clear} [%s] 开始运行 %d 个用例 (单例最长不超过 %ds)",
                label, #bin_files, timeout_sec)
        else
            cprint("${cyan underline}[INFO]${clear} [%s] 开始运行 %d 个用例 (TIMEOUT=0，禁用超时)",
                label, #bin_files)
        end
        cprint("${cyan underline}[INFO]${clear} [%s] 日志输出: %s/<case>.log",
            label, sim_log_dir)

        for _, bin_file in ipairs(bin_files) do
            local case_name = path.basename(bin_file)  -- 不含 .bin 后缀的文件名
            local r = run_one(case_name)
            if r.pass then
                table.insert(passed, case_name)
            elseif r.is_timeout then
                table.insert(timeouted, case_name)
            else
                table.insert(failed, case_name)
            end
        end

        -- 终端汇总（详细日志已落盘 sim-log/）
        cprint("${green underline}[INFO]${clear} [%s] 通过 (%d): %s",
            label, #passed, #passed > 0 and table.concat(passed, ", ") or "(none)")
        if #failed > 0 then
            cprint("${red underline}[INFO]${clear} [%s] 失败 (%d): %s",
                label, #failed, table.concat(failed, ", "))
        end
        if #timeouted > 0 then
            cprint("${yellow underline}[INFO]${clear} [%s] 耗时过长 (%d): %s | ${red underline}用例编写不合理!${clear}",
                label, #timeouted, table.concat(timeouted, ", "))
        end
        if #failed > 0 or #timeouted > 0 then
            raise(string.format("%s 完成，%d 个失败，%d 个耗时过长",
                label, #failed, #timeouted))
        end
    end
end

-- ============================================================================
-- target: sim-single —— 单用例标准化运行（落盘 log + CSV）
-- ============================================================================
-- 与直接 `xmake r Core` 的区别：本 target 会捕获 stdout+stderr 并自动落盘到
-- build/sim-log/<case>.log，便于事后查阅而无需重复仿真。CSV 一并写入 build/sim-data/。
-- 支持的 .bin 搜索目录：test_cases_basic / test_cases_regressive / test_cases_pressure。
-- 用法：
--   xmake r sim-single                    # 默认用例 (and)
--   TC=foo xmake r sim-single             # 指定用例
--   TIMEOUT=0 TC=foo xmake r sim-single   # 禁用超时（适合 pressure 长时用例）
-- ============================================================================
target("sim-single", function()
    set_kind("phony")
    set_default(false)
    on_run(_make_runner("single"))
end)

-- ============================================================================
-- target: sim-basic / sim-regressive —— 批量运行测试用例
-- ============================================================================
-- sim-basic       遍历 test_cases_basic/*.bin
-- sim-regressive  遍历 test_cases_regressive/*.bin
-- 注意：test_cases_pressure 不在批量范围内，仅可通过 sim-single 单跑接入。
-- 判定标准、日志落盘策略与 sim-single 完全一致（共用 run_one helper）。
-- ============================================================================
target("sim-basic", function()
    set_kind("phony")
    set_default(false)
    on_run(_make_runner("batch", "sim-basic", tc_basic_dir))
end)

target("sim-regressive", function()
    set_kind("phony")
    set_default(false)
    on_run(_make_runner("batch", "sim-regressive", tc_regressive_dir))
end)

-- ============================================================================
-- target: clean —— 清空整个 build/ 目录
-- ============================================================================
-- 直接整目录删除，省去逐项维护，避免不同后端 / 新增文件被遗漏。
-- ============================================================================
target("clean", function()
    set_kind("phony")
    set_default(false)
    on_run(function()
        os.tryrm(build_dir)
        cprint("${green underline}[INFO]${clear} 已清空整个 build/ 目录: %s", build_dir)
    end)
end)
