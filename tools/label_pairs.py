#!/usr/bin/env python3
"""用本机视觉模型给候选照片对打离线标签，供 calibrate.py 使用。

这一步只在标定时跑一次，结果缓存在 JSON 里；PicPicker 运行时不需要模型。

    tools/label_pairs.py --pairs ~/cal/*.tsv --out ~/cal/labels.json \\
        --vlm http://127.0.0.1:8080 --vlm-model Qwen3-VL-4B --min-luma 0.86

每对照片正反各问一次，两次结论一致才记录（same / different）；
不一致的记为 uncertain，标定时会被忽略。
"""

import argparse
import base64
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    sys.exit("需要 Pillow：python3 -m pip install pillow")

PROMPT = (
    "下面两张照片可能来自同一次按快门。请只比较画面内容：允许轻微裁剪、缩放、亮度或颜色差异、降噪、重新压缩；"
    "人物或物体的姿势、位置、朝向完全一致才回答 YES；只是同一个场景但姿势、位置已经变了回答 NO；不确定时回答 NO。"
    "只输出 YES 或 NO。"
)


def load_rows(paths):
    seen = set()
    rows = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            header = handle.readline().rstrip("\n").split("\t")
            index = {name: i for i, name in enumerate(header)}
            if "root" not in index:
                sys.exit(f"{path}: 缺少 root 列，请用新版 --dump-pairs 导出")
            for line in handle:
                parts = line.rstrip("\n").split("\t")
                key = (parts[index["root"]], parts[index["a"]], parts[index["b"]])
                if key in seen:
                    continue
                seen.add(key)
                rows.append({
                    "root": parts[index["root"]],
                    "a": parts[index["a"]],
                    "b": parts[index["b"]],
                    "luma": float(parts[index["luma"]]),
                    "edge": float(parts[index["edge"]]),
                })
    return rows


def data_url(path, size):
    # RAW 用系统解码器转一次，避免 Pillow 拿到不可比的渲染结果。
    if os.path.splitext(path)[1].lower() in (".dng", ".nef", ".cr3", ".arw", ".raf", ".orf", ".rw2"):
        converted = os.path.join(
            tempfile.gettempdir(),
            "picpicker-calib-" + hashlib.sha1(path.encode()).hexdigest()[:12] + ".jpg",
        )
        subprocess.run(
            ["sips", "-s", "format", "jpeg", "-Z", str(size), path, "--out", converted],
            capture_output=True,
            check=True,
        )
        path = converted
    image = Image.open(path).convert("RGB")
    image.thumbnail((size, size))
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=75)
    return "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode()


def ask(endpoint, model, first, second):
    body = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": PROMPT},
                {"type": "image_url", "image_url": {"url": first}},
                {"type": "image_url", "image_url": {"url": second}},
            ],
        }],
        "temperature": 0,
        "max_tokens": 8,
        "stream": False,
    }
    request = urllib.request.Request(
        endpoint.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        payload = json.load(response)
    text = payload["choices"][0]["message"]["content"].upper()
    if "YES" in text:
        return True
    if "NO" in text:
        return False
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pairs", nargs="+", required=True, help="--dump-pairs 导出的 TSV")
    parser.add_argument("--out", required=True, help="标签缓存 JSON")
    parser.add_argument("--vlm", default="http://127.0.0.1:8080/v1", help="OpenAI 兼容地址")
    parser.add_argument("--vlm-model", default="Qwen3-VL-4B")
    parser.add_argument("--min-luma", type=float, default=0.86, help="只标注亮度相关不低于该值的照片对")
    parser.add_argument("--max-luma", type=float, default=1.0)
    parser.add_argument("--pixels", type=int, default=1024, help="发给模型的图片最长边")
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()

    rows = [r for r in load_rows(args.pairs) if args.min_luma <= r["luma"] <= args.max_luma]
    cache = {}
    if os.path.exists(args.out):
        cache = json.load(open(args.out, encoding="utf-8"))
    print(f"待标注 {len(rows)} 对，已有缓存 {len(cache)} 条")

    lock = threading.Lock()
    done = 0

    def work(row):
        nonlocal done
        key = f"{row['root']}|{row['a']}|{row['b']}"
        if key in cache:
            return
        first = os.path.join(row["root"], row["a"])
        second = os.path.join(row["root"], row["b"])
        try:
            a = data_url(first, args.pixels)
            b = data_url(second, args.pixels)
            forward = ask(args.vlm, args.vlm_model, a, b)
            backward = ask(args.vlm, args.vlm_model, b, a)
        except Exception as error:  # 网络/解码失败就当没标签
            with lock:
                cache[key] = {"label": "error", "error": str(error)[:80]}
            return
        if forward is None or backward is None:
            label = "error"
        elif forward != backward:
            label = "uncertain"
        else:
            label = "same" if forward else "different"
        with lock:
            cache[key] = {"label": label, "luma": row["luma"], "edge": row["edge"]}
            done += 1
            if done % 10 == 0:
                json.dump(cache, open(args.out, "w", encoding="utf-8"), ensure_ascii=False)
                print(f"  {done}/{len(rows)}…", flush=True)

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        list(pool.map(work, rows))

    json.dump(cache, open(args.out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    counts = {}
    for value in cache.values():
        counts[value["label"]] = counts.get(value["label"], 0) + 1
    print(f"完成：{counts}")


if __name__ == "__main__":
    main()
