#!/usr/bin/env python3
"""Import OCaml changelog JSON into a SQLite FTS5 database."""

import json
import sqlite3
import sys
import re
import os

CHANGELOG_JSON = "changelog.json"
DB_FILE = "changelog.db"


def normalize_version(v: str) -> str:
    """Extract a short version string like '5.4.0' or 'working'."""
    if v.lower().startswith("working"):
        return "working"
    m = re.search(r'(\d+\.\d+(?:\.\d+)?)', v)
    return m.group(1) if m else v


def format_authors(authors) -> str:
    if not authors:
        return ""
    parts = []
    for a in authors:
        parts.append(" ".join(a))
    return ", ".join(parts)


def create_schema(conn: sqlite3.Connection):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS entries (
            id              INTEGER PRIMARY KEY,
            version         TEXT NOT NULL,
            version_full    TEXT NOT NULL,
            category        TEXT NOT NULL,
            text            TEXT NOT NULL,
            breaking        INTEGER NOT NULL DEFAULT 0,
            authors         TEXT,
            prs             TEXT
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
            version,
            category,
            text,
            authors,
            content='entries',
            content_rowid='id'
        );

        CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
            INSERT INTO entries_fts(rowid, version, category, text, authors)
            VALUES (new.id, new.version, new.category, new.text, new.authors);
        END;

        CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
            INSERT INTO entries_fts(entries_fts, rowid, version, category, text, authors)
            VALUES ('delete', old.id, old.version, old.category, old.text, old.authors);
        END;
    """)


def import_data(conn: sqlite3.Connection, data: dict):
    conn.execute("DELETE FROM entries")
    conn.execute("DELETE FROM entries_fts")

    rows = []
    for version_full, categories in data.items():
        version = normalize_version(version_full)
        for category, entries in categories.items():
            category = category.strip().rstrip(":")
            for entry in entries:
                if "text" not in entry:
                    continue
                text = entry["text"].strip()
                breaking = 1 if entry.get("breaking change") else 0
                authors = format_authors(entry.get("authors", []))
                refs = entry.get("references", [])
                prs = ",".join(str(r) for r in refs)
                rows.append((version, version_full, category, text, breaking, authors, prs))

    conn.executemany(
        "INSERT INTO entries(version, version_full, category, text, breaking, authors, prs) "
        "VALUES (?,?,?,?,?,?,?)",
        rows
    )
    print(f"Imported {len(rows)} entries across {len(data)} versions.", file=sys.stderr)


FILTER_RE = re.compile(r'(from|pr|ver):([^\s]+)')


def parse_query(raw: str):
    author = None
    pr = None
    ver = None
    for m in FILTER_RE.finditer(raw):
        key, val = m.group(1), m.group(2)
        if key == 'from':
            author = val
        elif key == 'pr':
            pr = val
        elif key == 'ver':
            ver = val
    fts = FILTER_RE.sub('', raw).strip()
    return fts, author, pr, ver


def search(conn: sqlite3.Connection, raw: str, limit: int = 20):
    fts_query, author, pr, ver = parse_query(raw)

    extra = []
    params = []
    if fts_query:
        params.append(fts_query)
    if author:
        extra.append("lower(e.authors) LIKE lower('%' || ? || '%')")
        params.append(author)
    if pr:
        extra.append(
            "(',' || e.prs || ',' LIKE '%,' || ? || ',%'"
            " OR e.prs = ? OR e.prs LIKE ? || ',%' OR e.prs LIKE '%,' || ?)"
        )
        params += [pr, pr, pr, pr]
    if ver:
        extra.append("e.version LIKE ? || '%'")
        params.append(ver)

    where_extra = (" AND " + " AND ".join(extra)) if extra else ""

    if fts_query:
        sql = f"""
            SELECT e.version, e.category, e.text, e.breaking, e.authors, e.prs,
                   snippet(entries_fts, 2, '[', ']', '\u2026', 20) AS snip
            FROM entries_fts f
            JOIN entries e ON e.id = f.rowid
            WHERE entries_fts MATCH ? {where_extra}
            ORDER BY rank
            LIMIT {limit}
        """
    else:
        sql = f"""
            SELECT e.version, e.category, e.text, e.breaking, e.authors, e.prs,
                   e.text AS snip
            FROM entries e
            WHERE 1=1 {where_extra}
            ORDER BY e.version DESC
            LIMIT {limit}
        """

    cur = conn.execute(sql, params)
    rows = cur.fetchall()
    for version, category, text, breaking, authors, prs, snip in rows:
        flag = " [BREAKING]" if breaking else ""
        print(f"[{version}] {category}{flag}")
        print(f"  {snip[:200]}")
        if authors:
            print(f"  authors: {authors}")
        if prs:
            links = " ".join(
                f"https://github.com/ocaml/ocaml/pull/{r}"
                for r in prs.split(",") if r
            )
            print(f"  refs: {links}")
        print()


def main():
    import argparse
    p = argparse.ArgumentParser(description="OCaml changelog search tool")
    sub = p.add_subparsers(dest="cmd")

    imp = sub.add_parser("import", help="Import changelog.json into changelog.db")
    imp.add_argument("--json", default=CHANGELOG_JSON)
    imp.add_argument("--db", default=DB_FILE)

    srch = sub.add_parser("search", help="Search the changelog")
    srch.add_argument("query", nargs="+")
    srch.add_argument("--db", default=DB_FILE)
    srch.add_argument("--limit", type=int, default=20)

    args = p.parse_args()

    if args.cmd == "import":
        with open(args.json) as f:
            data = json.load(f)
        conn = sqlite3.connect(args.db)
        create_schema(conn)
        with conn:
            import_data(conn, data)
        conn.close()
        print(f"Database written to {args.db}", file=sys.stderr)

    elif args.cmd == "search":
        if not os.path.exists(args.db):
            print(f"Database {args.db} not found. Run 'make changelog-import' first.", file=sys.stderr)
            sys.exit(1)
        conn = sqlite3.connect(args.db)
        query = " ".join(args.query)
        search(conn, query, args.limit)
        conn.close()

    else:
        p.print_help()


if __name__ == "__main__":
    main()
