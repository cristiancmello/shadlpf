#!/usr/bin/env python3
"""
Split a FLAC (or any audio) file using a WhisperX SRT file.

Usage:
    python split_audio.py <audio_file> <srt_file> [output_dir]
                          [--pad-start MS] [--pad-end MS]

Examples:
    python split_audio.py audio.flac timestamps.srt
    python split_audio.py audio.flac timestamps.srt clips/
    python split_audio.py audio.flac timestamps.srt clips/ --pad-start 200 --pad-end 200
    python split_audio.py audio.flac timestamps.srt clips/ --pad-start 0 --pad-end 0
"""

import re
import sys
import os
from pathlib import Path

try:
    from pydub import AudioSegment
except ImportError:
    print("ERROR: pydub not installed. Run: pip install pydub")
    print("You may also need ffmpeg: https://ffmpeg.org/download.html")
    sys.exit(1)


# ── Padding defaults ──────────────────────────────────────────────────────────

PADDING_START_MS: float = 150   # ms added BEFORE each segment start
PADDING_END_MS:   float = 150   # ms added AFTER  each segment end


# ── SRT parsing ───────────────────────────────────────────────────────────────

def srt_ts_to_ms(ts: str) -> float:
    """Convert 'HH:MM:SS,mmm' to milliseconds."""
    h, m, rest = ts.split(":")
    s, ms = rest.split(",")
    return (int(h) * 3600 + int(m) * 60 + int(s)) * 1000 + int(ms)


def parse_srt(path: str) -> list:
    """Parse a standard SRT file into a list of segments."""
    text = Path(path).read_text(encoding="utf-8")
    blocks = re.split(r"\n\s*\n", text.strip())
    segments = []

    for block in blocks:
        lines = [l for l in block.strip().splitlines() if l.strip()]
        if len(lines) < 3:
            continue
        ts = re.match(
            r"(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})",
            lines[1],
        )
        if not ts:
            continue
        label = " ".join(lines[2:]).strip()
        segments.append({
            "start": srt_ts_to_ms(ts.group(1)),
            "end":   srt_ts_to_ms(ts.group(2)),
            "label": label,
        })

    return segments


# ── Audio splitting ───────────────────────────────────────────────────────────

def safe_filename(text: str, max_len: int = 60) -> str:
    name = re.sub(r'[\\/*?:"<>|]', "", text)
    name = re.sub(r"\s+", "_", name)
    return name[:max_len].strip("_") or "segment"


def split_audio(audio_path, segments, output_dir, pad_start, pad_end):
    os.makedirs(output_dir, exist_ok=True)

    print(f"\nLoading audio: {audio_path}")
    audio = AudioSegment.from_file(audio_path)
    ext   = Path(audio_path).suffix.lstrip(".") or "flac"
    total = len(segments)
    width = len(str(total))

    print(f"Splitting into {total} segments  "
          f"(pad-start={pad_start}ms  pad-end={pad_end}ms)\n")

    for i, seg in enumerate(segments, start=1):
        start_ms = max(0,          seg["start"] - pad_start)
        end_ms   = min(len(audio), seg["end"]   + pad_end)
        duration = (end_ms - start_ms) / 1000

        filename = f"{i:0{width}}_{safe_filename(seg['label'])}.{ext}"
        out_path = os.path.join(output_dir, filename)

        audio[start_ms:end_ms].export(out_path, format=ext)

        # Salva o texto completo do segmento num .txt sidecar.
        # O nome do arquivo e truncado (max 60 chars), mas o .txt guarda
        # a transcricao completa para uso pelo prosody_lowpass.sh.
        txt_path = os.path.join(output_dir, filename.rsplit(".", 1)[0] + ".txt")
        Path(txt_path).write_text(seg["label"], encoding="utf-8")

        print(f"  [{i:{width}}/{total}] {filename}  ({duration:.2f}s)")

    print(f"\nDone! {total} segments saved to '{output_dir}/'")


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Split audio using a WhisperX SRT file.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("audio",      help="Input audio file (flac, mp3, wav, ...)")
    parser.add_argument("srt",        help="WhisperX SRT file")
    parser.add_argument("output_dir", nargs="?", default="output_segments",
                        help="Directory to save the segment files")
    parser.add_argument("--pad-start", type=float, default=PADDING_START_MS,
                        metavar="MS",
                        help="Milliseconds added BEFORE each segment start")
    parser.add_argument("--pad-end",   type=float, default=PADDING_END_MS,
                        metavar="MS",
                        help="Milliseconds added AFTER each segment end")

    args = parser.parse_args()

    print("Parsing SRT...")
    segments = parse_srt(args.srt)
    print(f"  {len(segments)} segments found.")

    if not segments:
        print("ERROR: No segments found. Check the SRT file.")
        sys.exit(1)

    split_audio(
        audio_path=args.audio,
        segments=segments,
        output_dir=args.output_dir,
        pad_start=args.pad_start,
        pad_end=args.pad_end,
    )
