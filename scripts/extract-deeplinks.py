#!/usr/bin/env python3
import argparse
import os
import random
import sqlite3
import sys
from pathlib import Path
from urllib.parse import urlencode


def parse_guid(guid: str):
    parts = guid.split(";", 2)
    if len(parts) != 3:
        return None
    _, kind, ident = parts
    if kind not in ("-", "+"):
        return None
    if not ident:
        return None
    return kind, ident


def clean_body(text: str, max_len: int) -> str:
    text = " ".join(text.split())
    if len(text) > max_len:
        return text[: max_len - 1] + "…"
    return text


def build_url(kind: str, ident: str, body: str | None):
    if kind == "-":
        params = {"address": ident}
    elif kind == "+":
        params = {"groupid": ident}
    else:
        return None
    if body is not None:
        params["body"] = body
    return "imessage:open?" + urlencode(params)


def get_random_message_body(conn: sqlite3.Connection, chat_guid: str):
    cur = conn.execute(
        """
        SELECT m.text
        FROM message m
        INNER JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        INNER JOIN chat c ON cmj.chat_id = c.ROWID
        WHERE c.guid = ?
          AND m.text IS NOT NULL
          AND length(m.text) > 0
        ORDER BY RANDOM()
        LIMIT 1
        """,
        (chat_guid,),
    )
    row = cur.fetchone()
    return row[0] if row else None


def main():
    parser = argparse.ArgumentParser(description="Extract random iMessage deep links from chat.db")
    parser.add_argument("--db", default=str(Path.home() / "Library/Messages/chat.db"))
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--with-body-ratio", type=float, default=0.4)
    parser.add_argument("--max-body-len", type=int, default=120)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--include-sms", action="store_true")
    parser.add_argument("--include-groups", action="store_true")
    parser.add_argument("--out", default=str(Path.home() / "Desktop/imessage-deeplinks.txt"))
    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    db_path = Path(args.db).expanduser()
    if not db_path.exists():
        print(f"error: chat.db not found at {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row

    where = ["guid IS NOT NULL"]
    if not args.include_sms:
        where.append("service_name = 'iMessage'")

    query = f"""
    SELECT guid, service_name
    FROM chat
    WHERE {' AND '.join(where)}
    """
    chats = conn.execute(query).fetchall()
    if not chats:
        print("error: no chats found", file=sys.stderr)
        sys.exit(1)

    random.shuffle(chats)
    selected = chats[: max(1, min(args.limit, len(chats)))]

    urls = []
    with_body = 0
    skipped_groups = 0

    for row in selected:
        guid = row["guid"]
        parsed = parse_guid(guid)
        if not parsed:
            continue
        kind, ident = parsed
        if kind == "+" and not args.include_groups:
            skipped_groups += 1
            continue

        body = None
        if random.random() < args.with_body_ratio:
            msg = get_random_message_body(conn, guid)
            if msg:
                body = clean_body(msg, args.max_body_len)
                with_body += 1

        url = build_url(kind, ident, body)
        if url:
            urls.append(url)

    out_path = Path(args.out).expanduser()
    out_path.write_text("\n".join(urls) + ("\n" if urls else ""), encoding="utf-8")

    print(f"wrote {len(urls)} deep links to {out_path}")
    print(f"  with body: {with_body}")
    if skipped_groups:
        print(f"  skipped groups: {skipped_groups}")


if __name__ == "__main__":
    main()
