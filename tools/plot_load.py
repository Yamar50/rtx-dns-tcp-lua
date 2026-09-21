#!/usr/bin/env python3
"""Plot exported CPU measurements. Optional host dependency: Matplotlib."""
import argparse
import csv
import json
import os
from pathlib import Path
import tempfile

os.environ.setdefault('MPLCONFIGDIR', str(Path(tempfile.gettempdir()) / 'rtx-dns-matplotlib'))
import matplotlib
matplotlib.use('Agg')
from matplotlib import pyplot as plt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--summary', type=Path, required=True)
    parser.add_argument('--samples', type=Path, required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--revision', required=True, help='relay revision actually used for this run')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--preview', action='store_true', help='explicitly mark an unfinished run as preliminary')
    args = parser.parse_args()
    summary = json.loads(args.summary.read_text())
    run = next((row for row in summary['completed'] if row['label'] == args.label), None)
    preliminary = run is None
    if preliminary:
        if not args.preview:
            parser.error('run is unfinished; use --preview only for a marked preliminary chart')
        row = next(row for row in summary['unfinished'] if row['label'] == args.label)
        start, duration, rate, size = row['epoch'], row['duration'], row['rate'], row['size']
    else:
        start, duration = run['start_epoch'], run['planned_duration_seconds']
        rate, size = run['rate'], run['response_bytes']
    with args.samples.open(newline='') as stream:
        samples = [{key: float(value) for key, value in row.items()} for row in csv.DictReader(stream)]
    samples = [row for row in samples if start + 5 <= row['epoch'] <= start + duration]
    if not samples:
        parser.error('no complete five-second samples fall within this stage')
    minutes = [(row['epoch'] - start) / 60 for row in samples]
    plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 11,
                         'axes.spines.top': False, 'axes.spines.right': False})
    fig, axes = plt.subplots(2, 1, figsize=(11, 6.6), sharex=True, gridspec_kw={'height_ratios': [2, 1]})
    fig.subplots_adjust(left=.08, right=.97, top=.79, bottom=.13, hspace=.18)
    fig.suptitle('RTX830 | DNS TCP relay', x=.08, y=.965, ha='left', fontsize=21, weight='bold')
    fig.text(.08, .901, f'{rate:g} requests/s  |  {size:,} byte DNS responses  |  {duration/60:g} minutes scheduled', color='#445166')
    status = 'IN PROGRESS - preliminary measurements' if preliminary else (
        f"{run['stats'].get('success', 0):,} / {run['planned']:,} successful requests")
    fig.text(.08, .848, status, fontsize=12, weight='bold', color='#986200' if preliminary else '#164f46')
    for key, label, color in [('CPU0', 'CPU0', '#215bc4'), ('CPU', 'Overall CPU', '#526275'), ('CPU1', 'CPU1', '#1c9468')]:
        axes[0].plot(minutes, [row[key] for row in samples], label=label, color=color, lw=1.3)
    axes[0].set_ylabel('CPU usage (%)')
    axes[0].set_ylim(-2, 100)
    axes[0].legend(loc='upper right', frameon=False, ncol=3)
    axes[1].plot(minutes, [row['memory'] for row in samples], color='#8754af', lw=1.8)
    axes[1].set_ylabel('Memory used (%)')
    axes[1].set_ylim(0, 100)
    axes[1].set_xlabel('Minutes from load start')
    axes[1].set_xlim(0, duration / 60)
    for ax in axes:
        ax.grid(axis='y', color='#dfe4eb', lw=.7)
        ax.set_axisbelow(True)
    peak = max(row['CPU0'] for row in samples)
    low, high = min(row['memory'] for row in samples), max(row['memory'] for row in samples)
    fig.text(.08, .032, f'CPU: 5-second averages sampled every 5 seconds. Observed CPU0 maximum: {peak:g}%. '
             f'Memory: {low:g}-{high:g}%. Samples: {len(samples)}.', fontsize=9, color='#445166')
    fig.text(.08, .009, f'Relay revision tested: {args.revision}. CPU sampling excludes the first five seconds.',
             fontsize=8, color='#667080')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=160, facecolor='white')
    plt.close(fig)
    print(args.output)


if __name__ == '__main__':
    main()
