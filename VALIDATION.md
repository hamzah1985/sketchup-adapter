# Source publication checks — 4 November 2026

The 74 public runtime source files are byte-identical to the production adapter
checkpoint recorded in `COMPATIBILITY.json`. Its measured native results and
known limitations are historical checkpoint evidence; native plugin workflows
were not rerun as part of this source publication.

Checks run from a clean extracted source package on Windows:

- Python 3.11: 51 unittest cases passed, including registry handling, temporary
  installation, exact backups, failure rollback, archive integrity, asynchronous
  recovery and geometry-related portable contracts.
- All shipped Ruby runtime files passed syntax checks under Ruby 3.2.11.
- The independent RBS container known-answer and malformed-input checks passed.
- Of 28 authored Ruby fixture files, 27 passed on the first run. The remaining
  `tests/topology_smoke.rb` process crashed once, then passed on immediate rerun
  with 16 tests and 73 assertions. The intermittent process crash remains
  unresolved; this suite is not claimed to be uniformly stable.
- All recorded source archive member hashes were checked against the extracted
  files. No active IngeTrazo installation or user plugin profile was modified.

No new universal plugin compatibility claim follows from these checks. The
adapter still needs tuning and reproducible failure reports are welcome.
