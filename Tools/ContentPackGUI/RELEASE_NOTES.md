# Garry's PAD ZIP Builder 1.0.0 — Windows

Download `GarrysPAD-ZIP-Builder-1.0.0-Windows.zip`, extract the entire folder, and run `GarrysPAD-ZIP-Builder.exe`. Keep the Scripts folder beside the EXE.

Windows GUI for the existing owned-installation content pack workflow:

- Installation folder and ZIP destination pickers.
- Playable (recommended), Playground and CompleteBase profiles.
- Read-only plan, ZIP creation, and separate SHA-256 payload verification.
- Background worker process, live bounded logs, log export and explicit overwrite confirmation.
- No administrator rights or additional .NET runtime installer required on Windows 10/11 with .NET Framework 4.8 and Windows PowerShell 5.1.

This is an unsigned executable. No game assets are included. Use a legally owned installation; do not redistribute the generated game-content ZIP.

Validation: built with Windows .NET Framework compiler; GUI construction, argument quoting and packaged-script presence self-test passed. Missing-installation error handling was exercised under Windows PowerShell 5.1. Full multi-GB real-game packaging, visible GUI interaction and physical iPad import have not been validated in this run.

This tool creates the content ZIP, not independently attested physics manifests. It does not make unfinished prop/physgun support complete.
