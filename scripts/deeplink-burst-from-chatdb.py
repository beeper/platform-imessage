#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def run(cmd, check=True):
    print("+", " ".join(cmd))
    return subprocess.run(cmd, check=check)


def main():
    parser = argparse.ArgumentParser(
        description="Generate deep links from chat.db and send them in a burst"
    )
    parser.add_argument("--db", default=str(Path.home() / "Library/Messages/chat.db"))
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--with-body-ratio", type=float, default=0.4)
    parser.add_argument("--max-body-len", type=int, default=120)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--include-sms", action="store_true")
    parser.add_argument("--include-groups", action="store_true")
    parser.add_argument("--out", default=None, help="Persist generated URLs to this file")
    parser.add_argument("--dry-run", action="store_true")

    # Burst options (passed through to deeplink-burst.swift)
    parser.add_argument("--mode", default="queueReply")
    parser.add_argument("--count", type=int, default=50)
    parser.add_argument("--delay-ms", type=int, default=20)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--wait-seconds", type=float, default=5.0)
    parser.add_argument("--bundle-id", default="com.apple.MobileSMS")
    parser.add_argument("--pid", type=int, default=None)
    parser.add_argument("--shuffle", action="store_true")
    args = parser.parse_args()

    scripts_dir = Path(__file__).resolve().parent
    extractor = scripts_dir / "extract-deeplinks.py"
    burst = scripts_dir / "deeplink-burst.swift"

    if not extractor.exists():
        print(f"error: missing {extractor}", file=sys.stderr)
        sys.exit(1)
    if not burst.exists():
        print(f"error: missing {burst}", file=sys.stderr)
        sys.exit(1)

    if args.out:
        out_path = Path(args.out).expanduser()
    else:
        fd, temp_path = tempfile.mkstemp(prefix="imessage-deeplinks-", suffix=".txt")
        os.close(fd)
        out_path = Path(temp_path)

    extract_cmd = [
        sys.executable,
        str(extractor),
        "--db",
        args.db,
        "--limit",
        str(args.limit),
        "--with-body-ratio",
        str(args.with_body_ratio),
        "--max-body-len",
        str(args.max_body_len),
        "--out",
        str(out_path),
    ]
    if args.seed is not None:
        extract_cmd += ["--seed", str(args.seed)]
    if args.include_sms:
        extract_cmd.append("--include-sms")
    if args.include_groups:
        extract_cmd.append("--include-groups")

    run(extract_cmd)

    if args.dry_run:
        print(f"Dry run. URLs saved to {out_path}")
        return

    burst_cmd = [
        "swift",
        str(burst),
        "--mode",
        args.mode,
        "--count",
        str(args.count),
        "--delay-ms",
        str(args.delay_ms),
        "--timeout",
        str(args.timeout),
        "--wait-seconds",
        str(args.wait_seconds),
        "--bundle-id",
        args.bundle_id,
        "--urls-file",
        str(out_path),
    ]
    if args.pid is not None:
        burst_cmd += ["--pid", str(args.pid)]
    if args.shuffle:
        burst_cmd.append("--shuffle")

    run(burst_cmd)

    if not args.out:
        try:
            out_path.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    main()
