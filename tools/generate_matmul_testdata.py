#!/usr/bin/env python3
import argparse
import json
import random
import struct
from pathlib import Path


def u32(value):
    return value & 0xFFFFFFFF


def split_u66(value):
    return [
        value & 0xFFFFFFFF,
        (value >> 32) & 0xFFFFFFFF,
        (value >> 64) & 0x3,
    ]


def matmul4x4(a, b):
    c = []
    for row in range(4):
        for col in range(4):
            acc = 0
            for k in range(4):
                acc += a[row * 4 + k] * b[k * 4 + col]
            c.append(acc)
    return c


def write_words_bin(path, words):
    with path.open("wb") as f:
        for word in words:
            f.write(struct.pack("<I", u32(word)))


def write_words_hex(path, words):
    with path.open("w", encoding="utf-8") as f:
        for word in words:
            f.write(f"{u32(word):08x}\n")


def build_vectors(groups, rng, max_value, keep_vectors, include_zero_matrix):
    vectors = []
    source_words = []
    result_words = []

    for group in range(groups):
        if include_zero_matrix and group == 0:
            a = [0] * 16
            b = [0] * 16
        else:
            a = [rng.randrange(max_value + 1) for _ in range(16)]
            b = [rng.randrange(max_value + 1) for _ in range(16)]
        c = matmul4x4(a, b)

        source_words.extend(a)
        source_words.extend(b)
        for value in c:
            result_words.extend(split_u66(value))

        if keep_vectors:
            vectors.append({
                "group": group,
                "A": a,
                "B": b,
                "C_u66": [str(value) for value in c],
                "C_words": [split_u66(value) for value in c],
            })

    return vectors, source_words, result_words


def main():
    parser = argparse.ArgumentParser(
        description="Generate full 4MB 32-bit ExtRAM images for the matrix-multiply task."
    )
    parser.add_argument("--groups", type=int, default=10,
                        help="number of A/B matrix groups")
    parser.add_argument("--seed", type=int, default=1, help="random seed")
    parser.add_argument("--max-value", type=lambda x: int(x, 0), default=0xFFFFFFFF,
                        help="maximum unsigned 32-bit input value, inclusive")
    parser.add_argument("--no-zero-matrix", action="store_true",
                        help="do not force group0 A/B to be all-zero matrices")
    parser.add_argument("--memory-bytes", type=lambda x: int(x, 0), default=4 * 1024 * 1024,
                        help="ExtRAM image size in bytes")
    parser.add_argument("--out-dir", type=Path, default=Path("matmul_testdata"),
                        help="output directory")
    parser.add_argument("--dump-vectors", action="store_true",
                        help="include every A/B/C matrix in matmul_vectors.json")
    args = parser.parse_args()

    if args.memory_bytes <= 0 or args.memory_bytes % 4 != 0:
        raise SystemExit("--memory-bytes must be a positive multiple of 4")
    memory_words = args.memory_bytes // 4
    max_groups = memory_words // 80

    if args.groups <= 0:
        raise SystemExit("--groups must be positive")
    if args.groups > max_groups:
        raise SystemExit(f"--groups={args.groups} does not fit in {args.memory_bytes} bytes; max is {max_groups}")
    if args.max_value < 0 or args.max_value > 0xFFFFFFFF:
        raise SystemExit("--max-value must be in range 0..0xffffffff")

    rng = random.Random(args.seed)
    vectors, source_words, result_words = build_vectors(
        args.groups, rng, args.max_value, args.dump_vectors, not args.no_zero_matrix
    )
    dst_base_word = len(source_words)
    result_end_word = dst_base_word + len(result_words)

    input_image_words = [0] * memory_words
    expected_image_words = [0] * memory_words
    input_image_words[0:len(source_words)] = source_words
    expected_image_words[0:len(source_words)] = source_words
    expected_image_words[dst_base_word:result_end_word] = result_words

    args.out_dir.mkdir(parents=True, exist_ok=True)
    write_words_bin(args.out_dir / "matmul_source_ab.bin", source_words)
    write_words_bin(args.out_dir / "matmul_expected_c.bin", result_words)
    write_words_bin(args.out_dir / "extram_input_4mb.bin", input_image_words)
    write_words_bin(args.out_dir / "extram_expected_4mb.bin", expected_image_words)
    write_words_hex(args.out_dir / "matmul_source_ab.hex", source_words)
    write_words_hex(args.out_dir / "matmul_expected_c.hex", result_words)
    write_words_hex(args.out_dir / "extram_input_4mb.hex", input_image_words)
    write_words_hex(args.out_dir / "extram_expected_4mb.hex", expected_image_words)

    metadata = {
        "groups": args.groups,
        "seed": args.seed,
        "max_value": args.max_value,
        "zero_matrix_group": None if args.no_zero_matrix else 0,
        "memory_bytes": args.memory_bytes,
        "memory_words": memory_words,
        "max_groups_for_memory": max_groups,
        "source_words": len(source_words),
        "result_words": len(result_words),
        "src_base_offset": 0,
        "dst_base_offset": dst_base_word * 4,
        "unused_tail_words": memory_words - result_end_word,
        "bytes_per_source_group": 128,
        "bytes_per_result_group": 192,
        "input_image": "source region filled, result region and unused tail filled with 0",
        "expected_image": "source region preserved, result region filled, unused tail filled with 0",
        "layout": "A0,B0,A1,B1,...,A(n-1),B(n-1),C0,C1,...,C(n-1),zero padding",
    }
    if args.dump_vectors:
        metadata["vectors"] = vectors
    (args.out_dir / "matmul_vectors.json").write_text(
        json.dumps(metadata, indent=2), encoding="utf-8"
    )

    print(f"generated {args.groups} groups in {args.out_dir}")
    print(f"memory size: {args.memory_bytes} bytes ({memory_words} words)")
    print("SRC_BASE offset: 0")
    print(f"DST_BASE offset: {dst_base_word * 4}")
    print(f"unused tail: {memory_words - result_end_word} words")
    print("input image:    extram_input_4mb.bin / extram_input_4mb.hex")
    print("expected image: extram_expected_4mb.bin / extram_expected_4mb.hex")


if __name__ == "__main__":
    main()
