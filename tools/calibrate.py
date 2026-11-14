#!/usr/bin/env python3
"""根据导出的候选照片对特征标定分组参数，输出 GroupingProfile JSON。

用法：
    # 1. 对每个样本文件夹导出候选对（不会改任何照片）
    picpicker --folder ~/Pictures/2026-11 --dry-run --dump-pairs ~/cal/2026-11.tsv

    # 2. 标定；多个文件夹可以一起喂，也可以指定一份“确认无重复”的基准
    tools/calibrate.py ~/cal/*.tsv --golden ~/cal/golden.tsv -o ~/.config/picpicker/grouping.json

标签来源（按优先级）：
    1. 人工标签文件：TSV 里带着人工认定结果（第 11 列为 same / different）。
    2. --golden：已确认“一张重复都没有”的文件夹，里面出现的任何成组都是错误。
    3. 目录内的“组号-文件名”：上一次运行时写下的组号，不同组号 = 不同照片。
       （导出时必须带上 root 列，见 README 的“重新标定”一节。）

没有上述任何一种标签时，脚本只做统计、不猜阈值。
"""

import argparse
import collections
import datetime
import json
import math
import os
import re
import sys

COLUMNS = ["root", "dist", "hash", "gap", "luma", "edge", "grouped", "a", "b", "burst"]
GROUP_PREFIX = re.compile(r"^(\d{1,3})-(.+)$")
CAMERA_PREFIX = re.compile(r"^(DSC|IMG|TSY|FHZ|WYL|LYZ|ZRY|EN7W|DSCF|_?TSY_|_?DSC_|IMG_)")


def load_rows(paths, labels=None):
    rows = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            header = handle.readline().rstrip("\n").split("\t")
            missing = [c for c in COLUMNS if c not in header]
            if missing:
                sys.exit(f"{path}: 缺少列 {missing}，请用新版 --dump-pairs 导出")
            index = {name: i for i, name in enumerate(header)}
            extra_label = header.index("label") if "label" in header else None
            for line in handle:
                parts = line.rstrip("\n").split("\t")
                row = {
                    "file": os.path.basename(path),
                    "root": parts[index["root"]],
                    "dist": float(parts[index["dist"]]),
                    "hash": float(parts[index["hash"]]),
                    "gap": float(parts[index["gap"]]),
                    "luma": float(parts[index["luma"]]),
                    "edge": float(parts[index["edge"]]),
                    "grouped": int(parts[index["grouped"]]),
                    "a": parts[index["a"]],
                    "b": parts[index["b"]],
                    "burst": parts[index["burst"]].strip() == "burst",
                }
                if extra_label is not None and index["label"] < len(parts):
                    label = parts[index["label"]].strip()
                    if label in ("same", "different"):
                        row["label"] = label
                rows.append(row)
    if labels:
        join_labels(rows, labels)
    return rows


def join_labels(rows, labels_path):
    """把 label_pairs.py 产出的标签并进候选对。"""
    labels = json.load(open(labels_path, encoding="utf-8"))
    for row in rows:
        key = f"{row['root']}|{row['a']}|{row['b']}"
        entry = labels.get(key)
        if not entry:
            continue
        label = entry.get("label")
        if label in ("same", "different"):
            row["label"] = label


def basename(path):
    return path.rsplit("/", 1)[-1]


def group_prefix(path):
    match = GROUP_PREFIX.match(basename(path))
    if not match:
        return None
    if not CAMERA_PREFIX.match(match.group(2)):
        return None
    return match.group(1)


def same_folder(a, b):
    return a.rsplit("/", 1)[0] == b.rsplit("/", 1)[0]


def tag(rows, golden_roots, strict):
    """返回 (positive, negative, unknown)。positive = 确实该合并。"""
    positive, negative, unknown = [], [], []
    for row in rows:
        if "label" in row:
            (positive if row["label"] == "same" else negative).append(row)
            continue
        if row["root"] in golden_roots:
            negative.append(row)
            continue
        if strict and same_folder(row["a"], row["b"]):
            pa, pb = group_prefix(row["a"]), group_prefix(row["b"])
            if pa and pb:
                (positive if pa == pb else negative).append(row)
                continue
        unknown.append(row)
    return positive, negative, unknown


def solve(rows, margin):
    rows = [r for r in rows if r.get("label") in ("same", "different")]
    if not rows:
        return None
    """在 (luma, edge) 平面找一条“亮度阈值 + 梯度相对余量”的分界线。

    形式：ok = luma >= T and edge >= T - allowance。
    目标：先让所有错误合并为 0，再尽量少漏掉真实重复。
    """
    best = None
    positives = [r for r in rows if r["label"] == "same"]
    for T10 in range(600, 996):
        threshold = T10 / 1000
        # 候选余量只取到需要的最小值，太大会误合并。
        for allowance in (0.0, 0.05, 0.10, 0.15, 0.20):
            bad = [
                r for r in rows
                if r["label"] == "different" and r["luma"] >= threshold and r["edge"] >= threshold - allowance
            ]
            if bad:
                continue
            missed = [
                r for r in positives
                if not (r["luma"] >= threshold and r["edge"] >= threshold - allowance)
            ]
            # 与错误样本的边界留出 margin，避免贴着噪声取阈值。
            if any(r["luma"] >= threshold - margin for r in rows if r["label"] == "different"):
                continue
            score = (len(missed), threshold)
            if best is None or score < best[0]:
                best = (score, threshold, allowance)
    return best


def sweep(rows, relaxation):
    """打印不同阈值下的“误合并 / 漏合并”权衡，方便按活动性质挑一个点。"""
    positives = [r for r in rows if r.get("label") == "same"]
    negatives = [r for r in rows if r.get("label") == "different"]
    print()
    print(f"{'阈值':>6} {'梯度线':>7} {'误合并':>7} {'漏合并':>7} {'召回率':>7}  误合并里最像的样本")
    for step in range(100, 996, 5):
        threshold = step / 1000
        allowance = 0.10
        line = threshold - allowance
        def need(row):
            return threshold - (relaxation if row["burst"] else 0.0)

        needed = [need(r) for r in positives]
        fp = [r for r in negatives if r["luma"] >= need(r) and r["edge"] >= need(r) - allowance]
        fn = [
            r for r, need in zip(positives, needed)
            if not (r["luma"] >= need and r["edge"] >= need - allowance)
        ]
        recall = (len(positives) - len(fn)) / len(positives) if positives else 1.0
        worst = max((r["luma"] for r in fp), default=None)
        note = f"luma 最高 {worst:.3f}" if worst is not None else ""
        print(f"{threshold:6.3f} {line:7.3f} {len(fp):7d} {len(fn):7d} {recall:7.0%}  {note}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tsv", nargs="+", help="--dump-pairs 导出的 TSV")
    parser.add_argument("--golden", nargs="*", default=[], help="确认无重复的文件夹（TSV 文件）")
    parser.add_argument("--base", default=None, help="现有 profile，未标定的字段沿用它的值")
    parser.add_argument("--labels", default=None, help="label_pairs.py 产出的标签 JSON")
    parser.add_argument("-o", "--output", default=None, help="输出 JSON 路径（默认打印到 stdout）")
    parser.add_argument("--margin", type=float, default=0.02, help="与错误样本保持的最小余量（默认 0.02）")
    parser.add_argument("--loose", action="store_true", help="不做“同目录组号”推断，只统计")
    parser.add_argument("--sweep", action="store_true", help="只打印阈值权衡表，不写 profile")
    parser.add_argument("--relaxation", type=float, default=0.03, help="权衡表里连拍对的放宽量")
    args = parser.parse_args()

    rows = load_rows(args.tsv, labels=args.labels)
    golden_roots = {r["root"] for r in load_rows(args.golden)} if args.golden else set()
    positive, negative, unknown = tag(rows, golden_roots, strict=not args.loose)
    labelled = positive + negative

    print(f"候选对 {len(rows)}：正样本 {len(positive)}，负样本 {len(negative)}，无标签 {len(unknown)}")
    if not positive or not negative:
        sys.exit("标签不足，无法标定（需要至少一组正样本和一组负样本）")

    if args.sweep:
        sweep(labelled, args.relaxation)
        return

    profile = {
        "version": 1,
        "source": ", ".join(sorted({r["file"] for r in labelled})),
        "calibratedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    }
    if args.base and os.path.exists(args.base):
        profile = json.load(open(args.base, encoding="utf-8"))
        profile["source"] = ", ".join(sorted({r["file"] for r in labelled}))
        profile["calibratedAt"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")

    pair = profile.setdefault("pair", {})
    solved = solve(labelled, args.margin)
    if solved is None:
        sys.exit("找不到既能排除所有负样本、又能保留正样本的分界线；检查标签或放宽容差")
    _, threshold, allowance = solved
    pair["lumaRequirement"] = round(threshold, 3)
    pair["edgeAllowance"] = round(allowance, 3)

    # 连拍放宽量：取“连拍对里最差的真实重复”与“负样本里最强的连拍对”之间的中点。
    burst_pos = [r for r in positive if r["burst"]]
    burst_neg = [r for r in negative if r["burst"]]
    if burst_pos:
        weakest = min(r["luma"] for r in burst_pos)
        strongest_neg = max((r["luma"] for r in burst_neg), default=None)
        relax = max(0.0, round(threshold - weakest + args.margin, 3))
        if strongest_neg is not None:
            relax = max(0.0, round(min(relax, strongest_neg - threshold + args.margin), 3))
        profile.setdefault("burst", {})["relaxation"] = relax
        print(f"连拍放宽量 {relax}（最弱连拍正样本 luma {weakest:.3f}）")

    print(f"亮度要求 {threshold:.3f}，梯度余量 {allowance:.3f}")
    print(f"  → 等价于“亮度 ≥ {threshold:.3f} 且 梯度 ≥ {threshold - allowance:.3f}”")

    text = json.dumps(profile, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        target = os.path.expanduser(args.output)
        os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(text)
        print(f"已写入 {target}")
    else:
        print(text)


if __name__ == "__main__":
    main()
