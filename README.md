# A verification framework for Multi-Issue Core in Verilua

基于 Verilua 的多发射核 Difftest 验证框架。通过 RV32I 参考模型（Lua 实现）与 RTL 仿真输出进行逐指令比对。

## XMake WorkFlow

```bash
# 初始化子模块
xmake run init

# 从 Chisel 编译生成 SystemVerilog RTL（仅首次或 RTL 变更时需要）
xmake build rtl

# 运行仿真（默认测试用例: and）
xmake run

# 输出波形文件
DUMP=1 xmake run

# 批量运行所有测试用例并输出汇总报告
xmake run sim-all
```

## 切换测试用例

通过环境变量 `TC` 指定测试用例名称（对应 `test_cases/<name>.bin`）。  
切换测试用例 **无需重新编译 RTL 或 VCS**，框架会自动将 `.bin` 转换为 `.hex` 并加载到 IROM。

```bash
TC=jal xmake run            # 运行 jal 测试
TC=pressure_test xmake run  # 运行压力测试
```

## 批量测试

`sim-all` 会遍历 `test_cases/` 下所有 `.bin` 文件，逐个执行 difftest 仿真：

- 日志输出：`build/sim-all/<case>.log`
- 汇总报告：`build/sim-all/summary.txt`
- 判定标准：进程退出码为 `0` 且输出包含 `TEST PASS`

## 项目结构

- `src/emu.lua` — RV32I 参考模型（状态、取指、译码、执行、内存访问）
- `src/main.lua` — Difftest 主控逻辑（驱动时钟、比对结果）
- `test_cases/` — RV32I 测试用例二进制文件
- `byPass/` — Chisel RTL 子项目
- `build/Core/` — 生成的 RTL 及 IROM hex 文件
