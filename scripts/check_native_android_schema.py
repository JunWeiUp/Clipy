#!/usr/bin/env python3
"""Keep the native Android v6 schema aligned with the shipping Flutter database."""
import re
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def signature(sql):
    with sqlite3.connect(":memory:") as db:
        db.executescript(sql)
        return sorted((kind, name, re.sub(r"\s+", " ", ddl).strip())
                      for kind, name, ddl in db.execute(
                          "SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL")
                      if not name.startswith("sqlite_"))

def main():
    dart = (ROOT / "clipy_android/lib/database/app_database.dart").read_text()
    version = re.search(r"schemaVersion = (\d+)", dart)
    if version is None or version[1] != "6":
        raise SystemExit("Review native Android migrations for the new Dart schema version")
    create = dart[dart.index("  Future<void> _onCreate"):]
    statements = re.findall(
        r"await db.execute\(\s*(?:'''(.*?)'''|'([^'\n]+)')", create, re.S
    )
    if not statements:
        raise SystemExit("Could not read the shipping schema")
    shipped = ";\n".join((a or b).strip() for a, b in statements) + ";"
    native = (ROOT / "clipy_android_native/app/src/main/assets/schema_v6.sql").read_text()
    if signature(shipped) != signature(native):
        raise SystemExit("Native Android schema differs from the shipping Flutter schema")
    print("Native Android base schema matches shipping v6 tables and indexes.")

if __name__ == "__main__":
    main()
