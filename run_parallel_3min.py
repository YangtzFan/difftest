#!/usr/bin/env python3

import os
import sys
import time
import signal
import shutil
import subprocess
from typing import List, Dict


COMMAND_FILE = sys.argv[1] if len(sys.argv) >= 2 else "command.txt"

TIMEOUT_SEC = int(os.environ.get("TIMEOUT_SEC", "180"))
KILL_AFTER_SEC = int(os.environ.get("KILL_AFTER_SEC", "5"))
REFRESH_SEC = float(os.environ.get("REFRESH_SEC", "1"))


def read_commands(path: str) -> List[str]:
    commands = []

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")

            if not line.strip():
                continue

            if line.lstrip().startswith("#"):
                continue

            commands.append(line)

    return commands


def format_time(seconds: int) -> str:
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


def truncate_text(text: str, max_width: int) -> str:
    if max_width <= 3:
        return text[:max_width]

    if len(text) <= max_width:
        return text

    return text[: max_width - 3] + "..."


def save_cursor() -> None:
    sys.stdout.write("\0337")


def restore_cursor() -> None:
    sys.stdout.write("\0338")


def update_cell(row: int, col: int, text: str, total_rows: int) -> None:
    """
    row 从 0 开始。

    当前光标默认停在表格最后一行的下一行。
    通过 ANSI escape sequence 定位到指定行和列，只覆盖指定字段。
    """
    save_cursor()

    up_lines = total_rows - row
    sys.stdout.write(f"\033[{up_lines}A")

    # ANSI 列从 1 开始
    sys.stdout.write(f"\033[{col + 1}G")
    sys.stdout.write(text)

    restore_cursor()
    sys.stdout.flush()


def terminate_process_group(proc: subprocess.Popen) -> None:
    """
    结束整个进程组，避免只杀掉 shell，而留下 xmake/verilator 子进程。
    """
    if proc.poll() is not None:
        return

    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    deadline = time.time() + KILL_AFTER_SEC

    while time.time() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.1)

    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main() -> int:
    if not os.path.isfile(COMMAND_FILE):
        print(f"Error: command file not found: {COMMAND_FILE}", file=sys.stderr)
        return 1

    commands = read_commands(COMMAND_FILE)
    total = len(commands)

    if total == 0:
        print(f"No valid commands found in {COMMAND_FILE}", file=sys.stderr)
        return 1

    terminal_width = shutil.get_terminal_size((120, 20)).columns

    # 形如：
    # [1/56]  RUNNING  00:00  SIM=...
    index_width = len(f"[{total}/{total}]")

    index_col = 0
    status_col = index_width + 2
    time_col = status_col + 9
    cmd_col = time_col + 8

    max_cmd_width = max(20, terminal_width - cmd_col - 1)

    tasks: List[Dict[str, object]] = []
    timeout_commands: List[str] = []

    print(f"Total commands: {total}")
    print(f"Timeout       : {TIMEOUT_SEC}s")
    print()

    for index, cmd in enumerate(commands):
        display_cmd = truncate_text(cmd, max_cmd_width)
        index_text = f"[{index + 1}/{total}]"

        print(f"{index_text:<{index_width}}  {'RUNNING':<7}  {'00:00'}  {display_cmd}")

        proc = subprocess.Popen(
            cmd,
            shell=True,
            executable="/bin/bash",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )

        tasks.append(
            {
                "index": index,
                "cmd": cmd,
                "proc": proc,
                "start_time": time.time(),
                "state": "running",
                "exit_code": None,
                "final_elapsed": None,
            }
        )

    sys.stdout.flush()

    remaining = total

    try:
        while remaining > 0:
            now = time.time()

            for task in tasks:
                if task["state"] != "running":
                    continue

                index = int(task["index"])
                cmd = str(task["cmd"])
                proc: subprocess.Popen = task["proc"]  # type: ignore
                start_time = float(task["start_time"])

                elapsed = int(now - start_time)

                # 仅 RUNNING 状态持续更新时间。
                update_cell(
                    row=index,
                    col=time_col,
                    text=format_time(elapsed),
                    total_rows=total,
                )

                # 先判断是否已经自然结束。
                if proc.poll() is not None:
                    exit_code = proc.returncode
                    final_elapsed = int(time.time() - start_time)

                    task["exit_code"] = exit_code
                    task["final_elapsed"] = final_elapsed
                    task["state"] = "done" if exit_code == 0 else "failed"

                    remaining -= 1

                    if exit_code == 0:
                        update_cell(index, status_col, "DONE   ", total)
                    else:
                        update_cell(index, status_col, "FAILED ", total)

                    # DONE / FAILED 后停止计时，固定为最终耗时。
                    update_cell(index, time_col, format_time(final_elapsed), total)
                    continue

                # 再判断是否超时。
                if elapsed >= TIMEOUT_SEC:
                    terminate_process_group(proc)

                    task["state"] = "timeout"
                    task["exit_code"] = proc.returncode
                    task["final_elapsed"] = TIMEOUT_SEC

                    remaining -= 1
                    timeout_commands.append(cmd)

                    update_cell(index, status_col, "TIMEOUT", total)
                    update_cell(index, time_col, format_time(TIMEOUT_SEC), total)

            if remaining > 0:
                time.sleep(REFRESH_SEC)

    except KeyboardInterrupt:
        print()
        print("Interrupted. Killing all running commands...")

        for task in tasks:
            if task["state"] == "running":
                proc: subprocess.Popen = task["proc"]  # type: ignore
                terminate_process_group(proc)

        return 130

    print()
    print()
    print("========== TIMEOUT COMMANDS ==========")

    if not timeout_commands:
        print("No timeout commands.")
        return 0

    for cmd in timeout_commands:
        print(cmd)

    return 1


if __name__ == "__main__":
    sys.exit(main())
