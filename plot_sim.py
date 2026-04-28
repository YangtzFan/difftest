#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
plot_sim.py —— 绘制 Difftest 仿真每周期的占用率与 IPC 曲线
-----------------------------------------------------------
使用方法:
    python plot_sim.py <case_name> [cycle_a] [cycle_b] [-o out.png]

        # 完整波形
        python plot_sim.py and
        # 从第 150 周期绘制到末尾
        python plot_sim.py sw 150
        # 绘制 100~200 周期之间（两个参数不要求有序）
        python plot_sim.py sw 100 200
        python plot_sim.py sw 200 100   # 等价写法

说明:
    读取 build/sim-data/<case_name>.csv，文件由 difftest 在运行每条用例时
    自动写入。列格式:
        cycle, fb, iq, rob, sb, sq, commits, ipc
    其中 fb/iq/rob/sb/sq 分别对应 FetchBuffer、IssueQueue、ROB、StoreBuffer
    与 AXIStoreQueue 在该时钟周期末的有效条目数；commits 为累计已提交指令数；
    ipc 为累计平均 IPC。

    区间规则：
      - 不给定区间参数 → 绘制全部周期。
      - 只给 1 个参数 A → 区间为 [A, 最大周期]。
      - 给 2 个参数 A,B → 区间为 [min(A,B), max(A,B)]。
      - 若请求区间内某段没有数据点，不会强行补数据，但横轴仍保留该区间范围。
"""

import argparse
import csv
import os
import sys


# ---------------------------------------------------------------------------
# 各队列的实际深度 —— 与 byPass/src/main/scala/CPUConfig.scala 保持一致
# ---------------------------------------------------------------------------
QUEUE_DEPTHS = {
    "fb":  32,   # FetchBuffer
    "iq":  48,   # IssueQueue
    "rob": 128,  # ROB
    "sb":  16,   # StoreBuffer
    "sq":  16,   # AXIStoreQueue
}

# 图例使用的人类友好名称
QUEUE_LABELS = {
    "fb":  "FetchBuffer",
    "iq":  "IssueQueue",
    "rob": "ROB",
    "sb":  "StoreBuffer",
    "sq":  "AXIStoreQueue",
}


def find_csv(case_name: str) -> str:
    """根据脚本自身位置定位 build/sim-data/<case>.csv，找不到则报错退出。"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(script_dir, "build", "sim-data", f"{case_name}.csv")

    if not os.path.isfile(csv_path):
        print(
            f"[ERROR] 未找到仿真数据文件: {csv_path}\n"
            f"        请先运行 'TC={case_name} xmake r Core' 生成 CSV。",
            file=sys.stderr,
        )
        sys.exit(1)
    return csv_path


def load_csv(csv_path: str):
    """读取 CSV 并把每列转换为 list。"""
    cycles, fb, iq, rob, sb, sq, commits, ipc = [], [], [], [], [], [], [], []
    with open(csv_path, "r", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            cycles.append(int(row["cycle"]))
            fb.append(int(row["fb"]))
            iq.append(int(row["iq"]))
            rob.append(int(row["rob"]))
            sb.append(int(row["sb"]))
            sq.append(int(row["sq"]))
            commits.append(int(row["commits"]))
            ipc.append(float(row["ipc"]))

    if not cycles:
        print(f"[ERROR] CSV 文件为空: {csv_path}", file=sys.stderr)
        sys.exit(1)

    return {
        "cycle": cycles,
        "fb":  fb,
        "iq":  iq,
        "rob": rob,
        "sb":  sb,
        "sq":  sq,
        "commits": commits,
        "ipc":     ipc,
    }


def plot(data, case_name: str, save_path: str = None,
         xlim: tuple = None):
    """绘制占用曲线（上）与 IPC 曲线（下）。

    xlim: (lo, hi) 若给定则强制设定横轴范围，即使区间内无数据也保留空白。
    """
    # 延迟 import，避免仅仅查看 --help 也需要 matplotlib
    import matplotlib.pyplot as plt

    cycles = data["cycle"]

    fig, (ax_occ, ax_ipc) = plt.subplots(2, 1, figsize=(12, 8), sharex=True)

    # ---- 上子图：各队列占用率 ----
    # 使用 fraction(0..1) 显示，可以让容量相差悬殊的队列放在同一个坐标轴下比较
    for key in ("fb", "iq", "rob", "sb", "sq"):
        depth = QUEUE_DEPTHS[key]
        frac = [v / depth for v in data[key]]
        ax_occ.plot(cycles, frac,
                    label=f"{QUEUE_LABELS[key]} (depth={depth})", linewidth=1.2)

    ax_occ.set_ylabel("Occupancy (fraction)")
    ax_occ.set_ylim(0.0, 1.05)
    title = f"Per-cycle occupancy & IPC — case '{case_name}'"
    if xlim is not None:
        title += f"  [cycles {xlim[0]}..{xlim[1]}]"
    ax_occ.set_title(title)
    ax_occ.grid(True, alpha=0.3)
    ax_occ.legend(loc="upper right", fontsize=9)

    # ---- 下子图：累计平均 IPC ----
    ax_ipc.plot(cycles, data["ipc"], color="tab:red", linewidth=1.2, label="Cumulative IPC")
    ax_ipc.set_xlabel("Cycle")
    ax_ipc.set_ylabel("IPC")
    ax_ipc.grid(True, alpha=0.3)
    ax_ipc.legend(loc="lower right", fontsize=9)

    # 统一强制横轴范围：即使请求区间有部分或全部无数据也保留横轴跨度
    if xlim is not None:
        ax_occ.set_xlim(xlim[0], xlim[1])
        ax_ipc.set_xlim(xlim[0], xlim[1])

    fig.tight_layout()

    if save_path:
        fig.savefig(save_path, dpi=150)
        print(f"[INFO] 已保存图像到: {save_path}")
    else:
        plt.show()


def slice_by_range(data, lo: int, hi: int):
    """按 cycle ∈ [lo, hi] 过滤 data 的每一列。区间无数据时返回空列表组成的 dict。"""
    keep_idx = [i for i, c in enumerate(data["cycle"]) if lo <= c <= hi]
    return {k: [v[i] for i in keep_idx] for k, v in data.items()}


def main():
    parser = argparse.ArgumentParser(
        description="绘制 difftest 单个测试用例的每周期占用与 IPC"
    )
    parser.add_argument("case", help="测试用例名（不含 .bin/.csv 后缀），例如 and")
    # 1~2 个可选的区间参数，顺序无关
    parser.add_argument(
        "range", nargs="*", type=int,
        help="可选的 cycle 区间端点。"
             "传 1 个 → [该值, 末尾]；传 2 个 → [min, max]（两个参数顺序无关）。",
    )
    parser.add_argument(
        "-o", "--output",
        help="保存到文件（.png 等）。省略则弹出交互窗口。",
        default=None,
    )
    args = parser.parse_args()

    if len(args.range) > 2:
        parser.error("最多只接受 2 个区间参数")

    csv_path = find_csv(args.case)
    data = load_csv(csv_path)

    # 解析用户请求的 cycle 区间（允许参数乱序）
    xlim = None
    if len(args.range) >= 1:
        cmin = min(data["cycle"])
        cmax = max(data["cycle"])
        if len(args.range) == 1:
            lo, hi = args.range[0], cmax
        else:
            lo, hi = sorted(args.range)
        # 只过滤出落在 [lo, hi] 内的数据，但横轴仍保留 [lo, hi] 范围
        data = slice_by_range(data, lo, hi)
        xlim = (lo, hi)
        if not data["cycle"]:
            print(
                f"[WARN] cycle 区间 [{lo}, {hi}] 内无任何数据，"
                f"CSV 实际范围为 [{cmin}, {cmax}]，仍按请求区间输出空白图。",
                file=sys.stderr,
            )

    plot(data, args.case, save_path=args.output, xlim=xlim)


if __name__ == "__main__":
    main()
