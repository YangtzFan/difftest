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

## 批量测试

`sim-basic` 和 `sim-regressive` 逐个执行 `test_cases_basic/` 和 `test_cases_regressive/` 下所有 `.bin` 文件的 difftest 仿真：

- 判定标准：仿真输出中包含 `ECALL`（参考模型正常触发 ECALL 结束）。
- 终端会打印通过 / 失败 / 超时用例列表；若有失败则非零退出。
- **每个用例完整 stdout+stderr 落盘到 `build/sim-log/<case>.log`**（同名旧文件直接覆盖），跑完后可直接 `cat` 查阅，避免对单例重复仿真。
- **每周期 IPC / 占用 CSV 落盘到 `build/sim-data/<case>.csv`**；单跑 `xmake r sim-single` 或 `xmake r Core` 也写入同一目录。
- 可通过设置环境变量 `TIMEOUT=120` 修改超时阈值为 120 s，默认 600 s；`TIMEOUT=0` 表示禁用超时检测（适合 pressure 长时用例）。
- 上述 log / data 行为对 `sim-single` 同样适用（单跑也落盘）。

## 仿真数据与可视化

每次运行 `xmake run Core`（无论批量还是单用例）都会写入 `build/sim-data/<case>.csv`，列含义如下：

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
- `xmake run clean` 会直接清空整个 `build/` 目录（包含 RTL、VCS/Verilator 编译产物、sim-data/、sim-log/、波形等）。

## 项目结构

- `src/emu.lua` — RV32I 参考模型（状态、取指、译码、执行、内存访问）
- `src/main.lua` — Difftest 主控逻辑（驱动时钟、比对结果）
- `test_cases_basic/` 和 `test_cases_regressive/` — RV32I 测试用例二进制文件
- `byPass/` — Chisel RTL 子项目
- `build/Core/` — 生成的 RTL 及 IROM hex 文件
