#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import sys


def parse_args():
    parser = argparse.ArgumentParser(
        description="将每行一条32位RISC-V机器码的文本文件转换为bin文件"
    )
    parser.add_argument("input", help="输入文本文件")
    parser.add_argument("output", help="输出bin文件")
    parser.add_argument(
        "--endian",
        choices=["little", "big"],
        default="little",
        help="输出字节序，默认 little",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    instructions = []

    try:
        with open(args.input, "r", encoding="utf-8") as f:
            for lineno, line in enumerate(f, start=1):
                s = line.strip()

                if not s:
                    continue

                if len(s) != 8:
                    print(f"[ERROR] 第 {lineno} 行不是 8 位十六进制数: {s}", file=sys.stderr)
                    sys.exit(1)

                try:
                    value = int(s, 16)
                except ValueError:
                    print(f"[ERROR] 第 {lineno} 行包含非法十六进制字符: {s}", file=sys.stderr)
                    sys.exit(1)

                instructions.append(value)

        with open(args.output, "wb") as f:
            for inst in instructions:
                f.write(inst.to_bytes(4, byteorder=args.endian, signed=False))

        print(f"[OK] 已生成: {args.output}")
        print(f"[OK] 指令条数: {len(instructions)}")
        print(f"[OK] 总字节数: {len(instructions) * 4}")
        print(f"[OK] 字节序: {args.endian}")

    except FileNotFoundError:
        print(f"[ERROR] 找不到输入文件: {args.input}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"[ERROR] 文件操作失败: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

