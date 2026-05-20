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


def create_schema(conn: sqlite3.Connection):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS authors (
            id   INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE
        );
        CREATE INDEX IF NOT EXISTS authors_name ON authors(name);

        CREATE TABLE IF NOT EXISTS entries (
            id              INTEGER PRIMARY KEY,
            version         TEXT NOT NULL,
            version_full    TEXT NOT NULL,
            category        TEXT NOT NULL,
            text            TEXT NOT NULL,
            breaking        INTEGER NOT NULL DEFAULT 0,
            prs             TEXT
        );
        CREATE INDEX IF NOT EXISTS entries_prs ON entries(prs);

        CREATE TABLE IF NOT EXISTS entry_authors (
            entry_id  INTEGER NOT NULL REFERENCES entries(id),
            author_id INTEGER NOT NULL REFERENCES authors(id),
            PRIMARY KEY (entry_id, author_id)
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
            version,
            category,
            text,
            content='entries',
            content_rowid='id'
        );

        CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
            INSERT INTO entries_fts(rowid, version, category, text)
            VALUES (new.id, new.version, new.category, new.text);
        END;

        CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
            INSERT INTO entries_fts(entries_fts, rowid, version, category, text)
            VALUES ('delete', old.id, old.version, old.category, old.text);
        END;
    """)


def get_or_create_author(conn: sqlite3.Connection, name: str) -> int:
    row = conn.execute("SELECT id FROM authors WHERE name = ?", (name,)).fetchone()
    if row:
        return row[0]
    cur = conn.execute("INSERT INTO authors(name) VALUES (?)", (name,))
    return cur.lastrowid


def import_data(conn: sqlite3.Connection, data: dict):
    conn.execute("DELETE FROM entry_authors")
    conn.execute("DELETE FROM entries")
    conn.execute("DELETE FROM entries_fts")
    conn.execute("DELETE FROM authors")

    entry_rows = []
    author_links = []  # (entry index, author name)
    for version_full, categories in data.items():
        version = normalize_version(version_full)
        for category, entries in categories.items():
            category = category.strip().rstrip(":")
            for entry in entries:
                if "text" not in entry:
                    continue
                text = entry["text"].strip()
                breaking = 1 if entry.get("breaking change") else 0
                refs = entry.get("references", [])
                prs = ",".join(str(r) for r in refs)
                idx = len(entry_rows)
                entry_rows.append((version, version_full, category, text, breaking, prs))
                for a in entry.get("authors", []):
                    author_links.append((idx, " ".join(a)))

    conn.executemany(
        "INSERT INTO entries(version, version_full, category, text, breaking, prs) "
        "VALUES (?,?,?,?,?,?)",
        entry_rows
    )
    # fetch the inserted ids in order
    first_id = conn.execute("SELECT min(id) FROM entries").fetchone()[0]
    # entry at index i has id = first_id + i (rows inserted in order)
    for idx, name in author_links:
        entry_id = first_id + idx
        author_id = get_or_create_author(conn, name)
        conn.execute(
            "INSERT OR IGNORE INTO entry_authors(entry_id, author_id) VALUES (?,?)",
            (entry_id, author_id)
        )

    print(f"Imported {len(entry_rows)} entries across {len(data)} versions.", file=sys.stderr)


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


def get_entry_authors(conn: sqlite3.Connection, entry_id: int) -> list[str]:
    rows = conn.execute(
        "SELECT a.name FROM authors a"
        " JOIN entry_authors ea ON ea.author_id = a.id"
        " WHERE ea.entry_id = ?",
        (entry_id,)
    ).fetchall()
    return [r[0] for r in rows]


def search(conn: sqlite3.Connection, raw: str, limit: int = 20):
    fts_query, author, pr, ver = parse_query(raw)

    extra = []
    params = []
    if fts_query:
        params.append(fts_query)
    if author:
        extra.append(
            "EXISTS (SELECT 1 FROM entry_authors ea JOIN authors a ON a.id = ea.author_id"
            " WHERE ea.entry_id = e.id AND lower(a.name) LIKE lower('%' || ? || '%'))"
        )
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
            SELECT e.id, e.version, e.category, e.text, e.breaking, e.prs,
                   snippet(entries_fts, 2, '[', ']', '\u2026', 20) AS snip
            FROM entries_fts f
            JOIN entries e ON e.id = f.rowid
            WHERE entries_fts MATCH ? {where_extra}
            ORDER BY rank
            LIMIT {limit}
        """
    else:
        sql = f"""
            SELECT e.id, e.version, e.category, e.text, e.breaking, e.prs,
                   e.text AS snip
            FROM entries e
            WHERE 1=1 {where_extra}
            ORDER BY e.version DESC
            LIMIT {limit}
        """

    cur = conn.execute(sql, params)
    rows = cur.fetchall()
    for entry_id, version, category, text, breaking, prs, snip in rows:
        flag = " [BREAKING]" if breaking else ""
        print(f"[{version}] {category}{flag}")
        print(f"  {snip[:200]}")
        authors = get_entry_authors(conn, entry_id)
        if authors:
            print(f"  authors: {', '.join(authors)}")
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
