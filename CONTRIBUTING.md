# Contributing

This adapter is experimental. Reproducible geometry and interaction cases are
especially useful. Include the adapter revision, plugin/version, steps,
expected result, observed result and relevant non-private diagnostics.

## Development checks

Run `python -m unittest discover -s tests -p 'test_*.py'` and
`ruby tests/rbs_container_smoke.rb` from the repository root. The Python release
tests exercise installation into temporary profiles, archive integrity and
rollback; they do not install into your active IngeTrazo profile.

Ruby files ending in `_smoke.rb` and the `*_contracts.rb` fixtures exercise the
compatibility runtime directly. Run each file in its own Ruby process, for
example `ruby tests/decimal_length_input_contracts.rb`. External plugin download
recipes are optional and separate from these authored fixtures.

Keep the Python/Ruby protocol and native geometry behavior in sync. Test
dimensions, topology, selection, cancellation and Undo/Redo on a compatible
IngeTrazo host when a change affects those behaviors. The portable suite alone
does not certify native geometry. Update evidence and known limits together.

Update `public_files.json` when adding or removing runtime source. Run
`python build_release.py` to verify the public runtime inventory and rebuild
the source archive.

## Scope and redistribution

Preserve original vendor sources and authorization behavior. Do not commit
plugin packages, decrypted vendor sources, format keys, activation files,
credentials, user registries, private models or local verification profiles.
Optional walkthrough assets have separate restrictions documented beside
their code. Selection polling should remain read-only. Do not treat the count
of API methods or successful startup as a measure of full compatibility.

Installation changes should preserve exact backups and hash receipts. Keep
adapter changes in the adapter; native IngeTrazo plugins and application files
should not be overwritten by it.
