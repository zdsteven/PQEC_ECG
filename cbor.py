import argparse
import glob
import os
import re
import sys
from datetime import datetime
from pathlib import Path

import cbor2


DEFAULT_DIRECTORY = Path(r"E:\Edge下载\Downloads")
MAX_TEXT_BYTES = 16 * 1024
DBG_FIELDS = (
    "START",
    "FIRST_R",
    "LAST_R",
    "LAST_CORE",
    "CRC_READY",
    "R_EMPTY",
    "CORE_STALL",
    "RESET_RELEASE",
)
CDBG_FIELDS = (
    "CPU_MAIN",
    "CPU_DMA_START",
    "CPU_PREFIX_READY",
    "CPU_PREFIX_DONE",
    "CPU_DMA_DONE",
    "CPU_WRITER",
    "CPU_CRC_TFE",
    "CPU_CRC_LINE_POP",
)

# These names are descriptive hints derived from the observed trace shape.
# The raw opcode/kind pair is always printed so an unknown record is not hidden
# behind an over-confident interpretation.
EVENT_HINTS = {
    (90, 8): "TRACE_BEGIN",
    (90, 9): "TRACE_END",
    (91, 2): "SPAN_BEGIN",
    (91, 1): "SPAN_END",
    (20, 3): "BINARY_BLOCK_20",
    (21, 3): "BINARY_BLOCK_21",
    (16, 7): "SERIAL_CONFIG",
    (16, 4): "SERIAL_DATA",
    (92, 7): "WAIT_CONDITION",
    (1, 5): "TIMER_MARK",
    (8, 3): "CONTROL_8",
    (9, 3): "CONTROL_9",
}


def get_latest_cbor(directory: Path):
    files = glob.glob(str(directory / "*.cbor"))
    if not files:
        return None
    return Path(max(files, key=os.path.getmtime))


def load_cbor(path: Path):
    with path.open("rb") as stream:
        return cbor2.load(stream)


def decode_text(blob):
    if isinstance(blob, str):
        return blob
    if not isinstance(blob, bytes) or len(blob) > MAX_TEXT_BYTES:
        return None
    try:
        text = blob.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if not text:
        return ""
    printable = sum(ch.isprintable() or ch in "\r\n\t" for ch in text)
    if printable < int(len(text) * 0.9):
        return None
    return text


def iter_text_values(obj):
    text = decode_text(obj)
    if text is not None:
        yield text
        return
    if isinstance(obj, dict):
        for key, value in obj.items():
            yield from iter_text_values(key)
            yield from iter_text_values(value)
    elif isinstance(obj, (list, tuple)):
        for value in obj:
            yield from iter_text_values(value)
    elif isinstance(obj, cbor2.CBORTag):
        yield from iter_text_values(obj.value)


def is_trace_record(value):
    return (
        isinstance(value, (list, tuple))
        and len(value) >= 3
        and all(isinstance(value[index], int) for index in range(3))
    )


def iter_trace_records(obj):
    if isinstance(obj, (list, tuple)):
        for index, value in enumerate(obj):
            if is_trace_record(value):
                yield index, value


def format_trace_arg(value):
    if isinstance(value, bytes):
        text = decode_text(value)
        if text is not None:
            return "text=" + repr(text)
        return f"binary[{len(value):,} bytes]"
    if isinstance(value, str):
        return "text=" + repr(value)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return str(value)
    if value is None:
        return "null"
    if isinstance(value, (list, tuple, dict)):
        return f"<{type(value).__name__} {len(value)} items>"
    return f"<{type(value).__name__}>"


def describe_event(opcode, kind, args):
    if (opcode, kind) == (16, 7) and len(args) >= 4:
        return (
            f"baud={args[0]} parity={args[1]} "
            f"data_bits={args[2]} stop_bits={args[3]}"
        )
    if (opcode, kind) == (92, 7) and len(args) >= 2:
        return f"timeout={args[0]} condition={format_trace_arg(args[1])}"
    return " ".join(format_trace_arg(value) for value in args) or "-"


def print_timeline(obj):
    records = list(iter_trace_records(obj))
    if not records:
        print("未识别到顶层追踪事件记录。")
        return

    print()
    print("=" * 100)
    print("CBOR 测试流程时间线")
    print("=" * 100)
    print("事件名是基于当前样本的提示；opcode/kind 原值始终保留。大块二进制仅显示长度。")
    print()
    print(f"{'#':>3} {'时间(ms)':>10} {'间隔(ms)':>10} {'opcode/kind':>12} {'事件':<18} 详情")
    print("-" * 100)

    previous_tick = None
    first_tick = None
    last_tick = None
    binary_blocks = 0
    binary_bytes = 0
    start_ticks = []
    done_ticks = []

    for index, record in records:
        opcode, kind, tick = record[:3]
        args = list(record[3:])
        if first_tick is None:
            first_tick = tick
        last_tick = tick
        delta = 0 if previous_tick is None else tick - previous_tick
        previous_tick = tick
        name = EVENT_HINTS.get((opcode, kind), "UNKNOWN")
        detail = describe_event(opcode, kind, args)
        print(
            f"{index:>3} {tick:>10,} {delta:>10,} "
            f"{opcode:>5}/{kind:<6} {name:<18} {detail}"
        )

        for value in args:
            if isinstance(value, bytes):
                text = decode_text(value)
                if text is None:
                    binary_blocks += 1
                    binary_bytes += len(value)
                else:
                    upper = text.upper()
                    if "MATMUL_START" in upper:
                        start_ticks.append(tick)
                    if "MATMUL_DONE" in upper:
                        done_ticks.append(tick)

    print("-" * 100)
    if first_tick is not None:
        print(
            f"追踪范围: {first_tick:,} -> {last_tick:,} ms, "
            f"跨度 {last_tick - first_tick:,} ms"
        )
    print(f"跳过二进制块: {binary_blocks} 个，共 {binary_bytes:,} bytes")
    if start_ticks and done_ticks:
        coarse = done_ticks[-1] - start_ticks[-1]
        print(
            f"串口记录粗粒度 START->DONE 窗口: {coarse} ms；"
            "该整数毫秒时间线不能替代平台精确 elapsed time。"
        )


def extract_latest_matmul_text(obj):
    combined = "\n".join(iter_text_values(obj))
    upper = combined.upper()
    start = upper.rfind("MATMUL_START")
    if start < 0:
        return ""
    done = upper.find("MATMUL_DONE", start)
    if done < 0:
        return combined[start:].strip()
    return combined[start : done + len("MATMUL_DONE")].strip()


def parse_all_params(text):
    data = {}

    pattern = r"(?<![A-Z0-9_])([A-Z])=([0-9A-F\.]+)"
    for key, value in re.findall(pattern, text, re.IGNORECASE):
        key = key.upper()
        if "." in value:
            values = []
            for part in value.split("."):
                try:
                    values.append(int(part, 16))
                except ValueError:
                    pass
            if values:
                data[key] = values if len(values) > 1 else values[0]
        else:
            try:
                data[key] = int(value, 16)
            except ValueError:
                pass

    crc_match = re.search(r"MATMUL_CRC32=\s*([0-9A-F]+)", text, re.IGNORECASE)
    if crc_match:
        data["CRC32"] = crc_match.group(1).upper()

    compact = re.sub(r"\s+", "", text.upper())
    dbg_match = re.search(r"DBG=([0-9A-F]{8}(?:,[0-9A-F]{8}){7})", compact)
    if dbg_match:
        values = [int(value, 16) for value in dbg_match.group(1).split(",")]
        data.update(dict(zip(DBG_FIELDS, values)))
    cdbg_match = re.search(r"CDBG=([0-9A-F]{8}(?:,[0-9A-F]{8}){7})", compact)
    if cdbg_match:
        values = [int(value, 16) for value in cdbg_match.group(1).split(",")]
        data.update(dict(zip(CDBG_FIELDS, values)))
    return data


def print_matmul_analysis(text):
    print()
    print("=" * 100)
    print("最新 MATMUL 串口记录")
    print("=" * 100)
    if not text:
        print("未找到 MATMUL_START。")
        return
    print(text)

    data = parse_all_params(text)
    if "CRC32" in data:
        print(f"\nCRC32: {data['CRC32']}")

    params = {key: value for key, value in data.items() if key != "CRC32"}
    if not params:
        return

    print()
    print(f"{'参数':<12} {'十六进制':<12} {'十进制':>12} {'时间(ms, 20ns/cycle)':>22}")
    print("-" * 64)
    for key in DBG_FIELDS:
        if key not in params:
            continue
        value = params[key]
        print(f"{key:<12} 0x{value:08X} {value:>12,} {value * 20 / 1_000_000:>22.6f}")

    if any(field in params for field in CDBG_FIELDS):
        print()
        print(f"{'CPU参数':<18} {'十六进制':<12} {'十进制':>12} {'时间(ms, 32.97872MHz)':>24}")
        print("-" * 72)
        for key in CDBG_FIELDS:
            if key not in params:
                continue
            value = params[key]
            print(
                f"{key:<18} 0x{value:08X} {value:>12,} "
                f"{value / 32978.72:>24.6f}"
            )

    if all(field in data for field in DBG_FIELDS):
        print()
        print("DBG 阶段差值:")
        debug_diffs = (
            ("FIRST_R - START", data["FIRST_R"] - data["START"]),
            ("LAST_R - FIRST_R", data["LAST_R"] - data["FIRST_R"]),
            ("LAST_CORE - LAST_R", data["LAST_CORE"] - data["LAST_R"]),
            ("CRC_READY - LAST_CORE", data["CRC_READY"] - data["LAST_CORE"]),
            ("CRC_READY - START", data["CRC_READY"] - data["START"]),
        )
        for label, cycles in debug_diffs:
            print(f"  {label:<25} {cycles:>9,} cycles = {cycles * 20 / 1_000_000:.6f} ms")
        read_gaps = data["LAST_R"] - data["FIRST_R"] - 159999
        print(
            f"  {'R span non-transfer':<25} {read_gaps:>9,} cycles = "
            f"{read_gaps * 20 / 1_000_000:.6f} ms"
        )

    if all(field in data for field in CDBG_FIELDS):
        print()
        print("CDBG 阶段差值:")
        cpu_diffs = (
            ("DMA start - main", data["CPU_DMA_START"] - data["CPU_MAIN"]),
            ("prefix ready - DMA start", data["CPU_PREFIX_READY"] - data["CPU_DMA_START"]),
            ("prefix write", data["CPU_PREFIX_DONE"] - data["CPU_PREFIX_READY"]),
            ("DMA done - prefix done", data["CPU_DMA_DONE"] - data["CPU_PREFIX_DONE"]),
            ("CRC TFE wait", data["CPU_CRC_TFE"] - data["CPU_WRITER"]),
            ("CRC line pop", data["CPU_CRC_LINE_POP"] - data["CPU_CRC_TFE"]),
        )
        for label, cycles in cpu_diffs:
            print(
                f"  {label:<27} {cycles:>9,} cycles = "
                f"{cycles / 32978.72:.6f} ms"
            )


def parse_args():
    parser = argparse.ArgumentParser(
        description="解析线上评测 CBOR 的流程时间线、串口文本和 MATMUL 调试字段。"
    )
    parser.add_argument(
        "file",
        nargs="?",
        type=Path,
        help="指定 .cbor 文件；省略时读取下载目录中最新文件。",
    )
    parser.add_argument(
        "--directory",
        type=Path,
        default=DEFAULT_DIRECTORY,
        help=f"自动查找目录（默认: {DEFAULT_DIRECTORY}）。",
    )
    parser.add_argument(
        "--no-timeline",
        action="store_true",
        help="只显示 MATMUL 串口与 DBG，不显示完整事件时间线。",
    )
    return parser.parse_args()


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    args = parse_args()
    path = args.file or get_latest_cbor(args.directory)
    if path is None:
        print(f"未在 {args.directory} 找到 .cbor 文件。", file=sys.stderr)
        return 1
    path = path.resolve()
    if not path.is_file():
        print(f"CBOR 文件不存在: {path}", file=sys.stderr)
        return 2

    obj = load_cbor(path)
    print(f"文件: {path.name}")
    print(f"路径: {path}")
    print(f"大小: {path.stat().st_size:,} bytes")
    print(
        "修改时间: "
        + datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")
    )
    if isinstance(obj, dict) and "version" in obj:
        print(f"CBOR version: {obj['version']}")
    elif isinstance(obj, list) and obj and isinstance(obj[0], dict):
        print(f"CBOR metadata: {obj[0]}")

    if not args.no_timeline:
        print_timeline(obj)
    print_matmul_analysis(extract_latest_matmul_text(obj))
    return 0


if __name__ == "__main__":
    sys.exit(main())
