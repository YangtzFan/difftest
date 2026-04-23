# A verification framework for Multi-Issue Core in Verilua

基于 Verilua 的多发射核 Difftest 验证框架。通过 RV32I 参考模型（Lua 实现）与 RTL 仿真输出进行逐指令比对。

## XMake WorkFlow

```bash
# 初始化子模块
xmake run init

# 从 Chisel 编译生成 SystemVerilog RTL（仅首次或 RTL 变更时需要）
xmake build rtl

# 运行仿真（默认测试用例: and）
xmake run Core     # without waveform recorded
DUMP=1 xmake run Core # with waveform recorded

# 批量运行所有测试用例并输出汇总报告
xmake run sim-all
```

## 切换测试用例

通过环境变量 `TC` 指定测试用例名称（对应 `test_cases/<name>.bin`）。  
切换测试用例 **无需重新编译 RTL 或 VCS**，框架会自动将 `.bin` 转换为 `.hex` 并加载到 IROM。

```bash
TC=jal xmake run # 运行 jal 测试
TC=and xmake run # 运行 and 测试
```
`test_cases_pressure` 目录下的测试用例只能在 FPGA 开发板上运行，不要使用模拟器运行。

## 批量测试

`sim-all` 会遍历 `test_cases/` 下所有 `.bin` 文件，逐个执行 difftest 仿真：

- 子进程 stdout 捕获到内存，不落地日志文件，也不生成 `summary.txt`。
- 判定标准：仿真输出中包含 `ECALL`（参考模型正常触发 ECALL 结束）。
- 终端会打印通过 / 失败用例列表；若有失败则非零退出。
- 每个用例仍会生成 `build/sim-data/<case>.csv`，供绘图脚本使用（见下文）。

## 仿真数据与可视化

每次运行 `xmake run Core`（无论 `sim-all` 还是单用例）都会在
`build/sim-data/<case>.csv` 写入每周期的采样数据，列含义如下：

| 列名 | 含义 |
| --- | --- |
| `cycle` | 当前周期号 |
| `fb` / `iq` / `rob` / `sb` / `sq` | FetchBuffer / IssueQueue / ROB / StoreBuffer / AXIStoreQueue 的有效条目数 |
| `commits` | 截至该周期起始的累计已提交指令数 |
| `ipc` | 累计平均 IPC（`commits / cycle`） |

使用 `plot_sim.py` 可将 CSV 绘制为占用率 + IPC 双子图：

```bash
# 全部周期
python3 plot_sim.py and

# 从第 150 周期绘制到末尾
python3 plot_sim.py sw 150

# 绘制 100~200 周期（两个参数顺序无关，100 200 与 200 100 等价）
python3 plot_sim.py sw 100 200

# 保存到文件而非弹窗显示
python3 plot_sim.py and -o and.png
```

- 若请求区间内某段没有数据，不会强行补点，但横轴仍保留该区间范围。
- 需要 `matplotlib`，可通过 `pip install matplotlib` 安装。
- `xmake run clean` 会一并清理 `build/sim-data/` 目录。

## 项目结构

- `src/emu.lua` — RV32I 参考模型（状态、取指、译码、执行、内存访问）
- `src/main.lua` — Difftest 主控逻辑（驱动时钟、比对结果）
- `test_cases/` — RV32I 测试用例二进制文件
- `byPass/` — Chisel RTL 子项目
- `build/Core/` — 生成的 RTL 及 IROM hex 文件
