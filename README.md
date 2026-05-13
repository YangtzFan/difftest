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
xmake run sim-basic
```

## 切换测试用例

通过环境变量 `TC` 指定测试用例名称（对应 `test_cases_basic/<name>.bin`、`test_cases_regressive/<name>.bin` 或 `test_cases_pressure/<name>.bin`）。
切换测试用例 **无需重新编译 RTL 或 VCS**，框架会自动将 `.bin` 转换为 `.hex` 并加载到 IROM。

```bash
TC=jal xmake run # 运行 jal 测试
TC=and xmake run # 运行 and 测试
```

`test_cases_pressure/` 下用例规模较大，仅通过 `sim-single`（见下文）单跑接入仿真，**不**会被 `sim-basic` / `sim-regressive` 批量集扫描。

## 单用例标准化运行（sim-single）

`xmake r sim-single` 与直接 `xmake r Core` 的区别：本 target 会把 stdout+stderr 捕获并落盘到
`build/sim-log/<case>.log`（同名覆盖），CSV 仍写入 `build/sim-data/`。这样事后查日志无需重复仿真。

```bash
SIM=verilator xmake r sim-single                     # 默认用例 (and)
SIM=verilator TC=jal xmake r sim-single              # 指定用例
SIM=verilator TC=test_pressure TIMEOUT=0 xmake r sim-single  # 禁用超时（pressure 长时用例）
```

支持的 `.bin` 搜索目录：`test_cases_basic / test_cases_regressive / test_cases_pressure`，三目录同名则按列表顺序优先取。

## 批量测试（GNU parallel 并行）

`sim-basic` 和 `sim-regressive` 使用 **GNU parallel** 并行运行 `test_cases_basic/` / `test_cases_regressive/` 下所有 `.bin`：

```bash
SIM=verilator JOBS=100 xmake r sim-basic         # 100 并发，约 20s 跑完 39 个用例
SIM=verilator JOBS=100 xmake r sim-regressive    # 100 并发，约 1min 跑完 64 个用例
SIM=verilator xmake r sim-basic                  # JOBS 未设置时默认 8 并发
```

- **并发度**：`JOBS` 环境变量控制，默认 8。在 256 核服务器上推荐 `JOBS=100`。
- **临界区保护**：`build/Core/{irom,dram}.hex` 是 RTL `$readmemh` 的硬编码绝对路径，多 simv 并发会争抢；
  wrapper 用 `flock` 串行化"hex 写入 + simv `$readmemh` 加载完成"这段（只占整个仿真的几百毫秒），主仿真循环并行。
- **判定标准**：仿真输出中包含 `ECALL`（参考模型正常触发 ECALL 结束）。
- **输出隔离**：按 target 落到独立子目录，避免 basic / regressive 同名用例冲突：
  - `build/sim-log/<basic|regressive>/<case>.log` — 完整 stdout+stderr（同名覆盖）
  - `build/sim-data/<basic|regressive>/<case>.csv` — 每周期 IPC / 占用 CSV
  - `build/sim-status/<basic|regressive>/<case>.status` — `pass` / `fail` / `timeout` 标记
- 终端打印 `通过 / 失败 / 耗时过长` 三类用例列表；任一非通过则非零退出。
- 通过 `TIMEOUT=120` 修改单用例超时阈值（默认 600s）；`TIMEOUT=0` 禁用超时（适合 pressure 长时用例）。

> sim-single 仍单线程，CSV 写入 `build/sim-data/<case>.csv`（顶层，无子目录），其行为不变。

## 仿真数据与可视化

每次运行（单跑 `xmake run Core` / `sim-single`，或批量 `sim-basic` / `sim-regressive`）都会写入 CSV：

- 单跑：`build/sim-data/<case>.csv`
- 批量：`build/sim-data/<basic|regressive>/<case>.csv`

列含义如下：

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
- `xmake run clean` 会直接清空整个 `build/` 目录（包含 RTL、VCS/Verilator 编译产物、sim-data/、sim-log/、sim-status/、波形等）。

## 项目结构

- `src/emu.lua` — RV32I 参考模型（状态、取指、译码、执行、内存访问）
- `src/main.lua` — Difftest 主控逻辑（驱动时钟、比对结果）
- `test_cases_basic/` 和 `test_cases_regressive/` — RV32I 测试用例二进制文件
- `byPass/` — Chisel RTL 子项目
- `build/Core/` — 生成的 RTL 及 IROM hex 文件
