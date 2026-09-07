# ExportLC-13-ImportCommit

Writes only the valid staged rows into 01_ExportLCs, materialises each new LC's checklist, and audits the import. Rejected rows are never committed.

See `definition.json`. Set the `SiteUrl` parameter before enabling.
