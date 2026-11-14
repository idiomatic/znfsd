# SQLite

The SQLite amalgamation, built into znfsd by `zig build`.

| | |
| --- | --- |
| Version | 3.54.1 |
| Source | <https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip> |
| SHA3-256 of the zip | `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30` |
| License | Public domain ([sqlite.org/copyright.html](https://www.sqlite.org/copyright.html)) |

Only `sqlite3.c` and `sqlite3.h` are kept. To update, download the current amalgamation from <https://www.sqlite.org/download.html>, check its SHA3-256 against the page (`openssl dgst -sha3-256`), replace both files, and update this table.
