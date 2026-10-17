# Garry's PAD Content Builder 1.1.1 — Windows

Critical archive compatibility fix: Windows PowerShell 5.1/.NET Framework could
write method-8 DEFLATE entries for NoCompression. Nested VPK range reads in the
iPad runtime require method-0 STORED entries. The builder now streams STORED
payloads directly with Zip64 offsets/sizes and CRC32, avoiding that runtime
behavior entirely. Includes StoredZip64Writer.cs; keep it beside the scripts.

Windows PowerShell 5.1 round-trip tests passed for empty, binary and Unicode
entries; independent Python validation confirms method 0 and correct CRCs.
Full multi-GB generation with the new writer remains unverified. Previously
repaired owned ZIP passed all 2,298 payload hashes but is not new-writer proof.

English-first redesign with a GMod-inspired charcoal palette, blue g badge,
cleaner typography, spacious fields, a highlighted Build ZIP action and
console-style logs. Dialogs, status messages and the bundled guide are English.

Download the Windows ZIP, extract the whole folder and run
`GarrysPAD-ZIP-Builder.exe`. Keep the Scripts folder beside it.

Original content selection, plan, ZIP creation and SHA-256 verification scripts
are unchanged. No game assets bundled. Use a legally owned installation and do
not redistribute generated game archives.

Windows 10/11, .NET Framework 4.8 and Windows PowerShell 5.1. Unsigned executable;
no administrator rights required. No physics attestation generation.

Validation: Windows build and GUI/argument/script self-test passed; rendered
previews visually inspected. Full multi-GB packaging and physical iPad import
have not been validated in this run.
