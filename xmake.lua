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
local src_dir = path.join(prj_dir, "src")                  -- Lua 源码目录
local rtl_prj_dir = "/home/litian/Documents/stageFiles/studyplace/byPass"           -- Chisel RTL 子项目
local build_dir = path.join(prj_dir, "build")             -- 构建产物目录
local rtl_dir = path.join(build_dir, "Core")              -- 生成的 RTL 目录
local timeout_sec = tonumber(os.getenv("TIMEOUT")) or 60  -- 单个用例最长执行时间 (秒)

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
            cprint("${yellow underline}[WARNING]${clear} 未找到 mem_16384x128.sv  跳过 IROM 路径替换")
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
--   TIMEOUT=10 TC=foo xmake r Core # 单例运行最长 10 秒，超时强制终止
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

        -- ========================================================
        -- TIMEOUT 监测：当用户通过环境变量 TIMEOUT 指定单例最长执行时间时，
        -- 启动一个后台守护进程，超时后对当前 xmake 进程组发送 SIGTERM/SIGKILL，
        -- 从而强制终止仿真。该机制与 sim-basic / sim-regressive 行为保持一致，
        -- 让 `xmake r Core` 的单用例运行也能受到超时保护，避免死循环用例无限占用资源。
        -- ========================================================
        if timeout_sec > 0 then
            local self_pid = os.getpid()  -- 当前 xmake 进程 PID（一般也是其进程组组长）
            -- 通过 setsid 将守护进程脱离当前会话，使其在 xmake 退出后仍能存活；
            -- 超时触发时，先在 stderr 上输出与 sim-basic / sim-regressive 风格一致的中文提示，
            -- 再发 SIGTERM 优雅终止，宽限 5 秒后发 SIGKILL 兜底强杀。
            -- 守护进程在动手前先校验目标 PID 是否仍存在 (kill -0)，避免 PID 复用误杀。
            -- 注意：xmake 被杀后无法再调用 cprint 渲染颜色，因此守护进程直接发送 ANSI 转义码：
            --   \033[33;4m -> 黄色 + 下划线
            --   \033[31;4m -> 红色 + 下划线
            --   \033[0m    -> 复位样式
            local timeout_msg = string.format(
                "\\033[33;4m[INFO]\\033[0m [sim-single] 耗时过长: %s | \\033[31;4m用例编写不合理！\\033[0m\\n",
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
        else
            cprint("${yellow underline}[WARNING]${clear} 无效的 TIMEOUT 值: '%s'，忽略", tostring(timeout_sec))
        end

        -- 在 test_cases_basic / test_cases_regressive 目录中依次查找 <TC>.bin
        local search_dirs = { tc_basic_dir, tc_regressive_dir }
        local bin_file
        for _, d in ipairs(search_dirs) do
            local candidate = path.join(d, tc_name .. ".bin")
            if os.isfile(candidate) then
                bin_file = candidate
                break
            end
        end
        if not bin_file then
            raise(string.format("测试用例未找到: %s.bin (已搜索: %s, %s)",
                tc_name, tc_basic_dir, tc_regressive_dir))
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
-- target: sim-basic / sim-regressive —— 批量运行测试用例
-- ============================================================================
-- sim-basic       遍历 test_cases_basic/*.bin
-- sim-regressive  遍历 test_cases_regressive/*.bin
-- 判定标准：子进程 stdout 中包含 "ECALL"（表示参考模型检测到 ECALL 而正常结束）。
-- 本 target 不再落地仿真日志文件，也不再生成 summary.txt，只在终端输出简洁汇总。
-- 但每个用例的每周期占用/IPC 数据仍然由 Core 仿真自动写入 build/sim-data/<case>.csv，
-- 供 scripts/plot_sim.py 绘图使用（见 clean 目标也会清理该目录）。
-- ============================================================================
-- ============================================================================
-- target: sim-basic / sim-regressive —— 批量运行测试用例
-- ============================================================================
-- sim-basic       遍历 test_cases_basic/*.bin
-- sim-regressive  遍历 test_cases_regressive/*.bin
-- 判定标准：子进程 stdout 中包含 "ECALL"（表示参考模型检测到 ECALL 而正常结束）。
-- 本 target 不再落地仿真日志文件，也不再生成 summary.txt，只在终端输出简洁汇总。
-- 但每个用例的每周期占用/IPC 数据仍然由 Core 仿真自动写入 build/sim-data/<case>.csv，
-- 供 scripts/plot_sim.py 绘图使用（见 clean 目标也会清理该目录）。
-- ============================================================================
local function _make_batch_runner(label, dir)
    return function()
        -- 收集所有测试用例并排序
        local bin_files = os.files(path.join(dir, "*.bin"))
        table.sort(bin_files)

        if #bin_files == 0 then
            raise(string.format("%s 目录下未找到任何 .bin 文件", dir))
        end

        local passed     = {}
        local failed     = {}
        local timeouted  = {}

        cprint("${cyan underline}[INFO]${clear} [%s] 开始运行 %d 个用例 (单例最长不超过 %ds)",
            label, #bin_files, timeout_sec)

        -- 逐个运行测试用例：用 popen 捕获 stdout 到内存，读完即丢弃
        for _, bin_file in ipairs(bin_files) do
            local case_name = path.basename(bin_file)  -- 不含 .bin 后缀的文件名

            -- 使用系统 `timeout` 命令包裹 `xmake r Core`，超过 timeout_sec 秒发送 SIGTERM；
            -- 5 秒宽限期后 (--kill-after=5) 仍未退出则发送 SIGKILL，保证不残留进程。
            -- timeout 自身约定的退出码：超时被杀返回 124，被 SIGKILL 强杀返回 137。
            local log_text = ""
            local err_text = ""
            local t0 = os.time()
            try {
                function()
                    local stdout, stderr = os.iorunv("timeout",
                        {"--kill-after=5", tostring(timeout_sec), "xmake", "r", "Core"},
                        {envs = {TC = case_name}})
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

            local pass_mark = (log_text:find("ECALL", 1, true) ~= nil)
            -- 判定超时：timeout 命令以 124/137 退出，或实际运行时长达到上限阈值
            local is_timeout = (not pass_mark) and (
                err_text:find("exit: 124", 1, true) ~= nil or
                err_text:find("exit: 137", 1, true) ~= nil or
                elapsed >= timeout_sec
            )

            if pass_mark then
                table.insert(passed, case_name)
            elseif is_timeout then
                table.insert(timeouted, case_name)
            else
                table.insert(failed, case_name)
            end
        end

        -- ============================================================
        -- 终端输出简洁汇总（不写任何文件）
        -- ============================================================
        cprint("${green underline}[INFO]${clear} [%s] 通过 (%d): %s",
            label, #passed, #passed > 0 and table.concat(passed, ", ") or "(none)")
        if #failed > 0 then 
            cprint("${red underline}[INFO]${clear} [%s] 失败 (%d): %s",
                label, #failed, #failed > 0 and table.concat(failed, ", ") or "(none)")
        end
        if #timeouted > 0 then
            cprint("${yellow underline}[INFO]${clear} [%s] 耗时过长 (%d): %s | ${red underline}用例编写不合理！${clear}",
                label, #timeouted, #timeouted > 0 and table.concat(timeouted, ", ") or "(none)")
        end
        if #failed > 0 or #timeouted > 0 then
            raise(string.format("%s 完成，%d 个失败，%d 个耗时过长",
                label, #failed, #timeouted))
        end
    end
end

target("sim-basic", function()
    set_kind("phony")
    set_default(false)
    on_run(_make_batch_runner("sim-basic", tc_basic_dir))
end)

target("sim-regressive", function()
    set_kind("phony")
    set_default(false)
    on_run(_make_batch_runner("sim-regressive", tc_regressive_dir))
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

        -- 清理每周期仿真数据（占用 + IPC 的 CSV）
        os.tryrm(path.join(build_dir, "sim-data"))
        cprint("${green underline}[INFO]${clear} 已清理仿真数据: sim-data/")

        -- 清理运行时生成的 IROM hex 文件
        os.tryrm(irom_hex)
        cprint("${green underline}[INFO]${clear} 已清理 IROM hex 文件")

        cprint("${green underline}[INFO]${clear} 清理完成")
    end)
end)
