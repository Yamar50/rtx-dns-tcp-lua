#!/usr/bin/env python3
"""Summarize completed load stages and CPU samples without publishing raw logs."""
import argparse
import json
from pathlib import Path
import re
import statistics


def cpu_samples(text):
    blocks = re.split(r"^SAMPLE (\d+)\s*$", text, flags=re.MULTILINE)
    result = []
    for index in range(1, len(blocks), 2):
        fields = {}
        for key in ("CPU", "CPU0", "CPU1"):
            match = re.search(r"^" + key + r":\s+(\d+)%\(5sec\)", blocks[index + 1], re.MULTILINE)
            if match:
                fields[key] = int(match[1])
        match = re.search(r"メモリ:\s+(\d+)%", blocks[index + 1])
        if match:
            fields["memory"] = int(match[1])
        if len(fields) == 4:
            result.append(dict(epoch=int(blocks[index]) / 1000, **fields))
    return result


def summarize(records, samples):
    starts, results = {}, []
    for record in records:
        if record["event"] == "stage_start":
            starts[record["label"]] = record
        elif record["event"] == "stage_result":
            start = starts.pop(record["label"])
            window = [sample for sample in samples
                      if start["epoch"] + 5 <= sample["epoch"] <= start["epoch"] + start["duration"]]
            metrics = {}
            for key in ("CPU", "CPU0", "CPU1", "memory"):
                values = [sample[key] for sample in window]
                metrics[key] = dict(min=min(values), max=max(values), mean=round(statistics.mean(values), 3)) if values else None
            stats, errors = record["stats"], record["errors"]
            passed = (stats.get("success", 0) == start["planned"]
                      and not errors and not stats.get("generator_skips", 0)
                      and not stats.get("capacity_drops", 0))
            results.append(dict(label=record["label"], start_epoch=start["epoch"],
                planned_duration_seconds=start["duration"], rate=start["rate"], response_bytes=start["size"],
                planned=start["planned"], stats=stats, errors=errors, all_success=passed,
                p50_ms=record["p50_ms"], p95_ms=record["p95_ms"], p99_ms=record["p99_ms"],
                latency_population="received DNS responses, excluding transport errors",
                cpu_samples=len(window), cpu_5sec_percent=metrics))
    return dict(completed=results, unfinished=list(starts.values()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stages", type=Path, nargs="+", required=True)
    parser.add_argument("--cpu", type=Path, required=True)
    args = parser.parse_args()
    records = [json.loads(line) for path in args.stages for line in path.read_text().splitlines() if line.strip()]
    print(json.dumps(summarize(records, cpu_samples(args.cpu.read_text())), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
