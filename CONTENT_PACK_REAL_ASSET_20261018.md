# Owned content ZIP diagnosis

User supplied Desktop/GarrysPAD_Content_Playable.zip (4,891,114,971 bytes).
Original manifest verification passed: 2,298 payloads, 4,889,835,075 bytes.
Original ZIP SHA256:
9108990b91d3f327cbfd1025a2252c5decab9cfd4551a46678d7eb5a1e9d5b9a

However, VPK entries use ZIP method 8. Windows PowerShell 5.1/.NET Framework
ZipArchive NoCompression can emit DEFLATE rather than STORED; the Swift nested
VPK range reader requires method 0. The verification script's hash PASS did not
prove compatibility. GUI 1.0.0/1.1.0 need a producer correction; do not call them
fixed by the app runtime changes.

Convert-ToStoredContentPack.py streams into a separate exclusive-created ZIP,
preserving payload bytes and the manifest. Original ZIP is untouched.
Desktop/GarrysPAD_Content_Playable_Stored.zip: 4,890,908,306 bytes; complete
manifest/hash verification passed. SHA256:
ae25f3a82e0af2175f9ac69e47fe4d70e693c833c87d9117229f45ae276b4123

Opt-in real-asset test now crosses VPK mounting and finds the owned
models/props_junk/wood_crate001a.mdl, but fails because the selected model has
Studio version 44; current decoder supports only version 48. This remains a
real failing compatibility gate, not a fabricated physics body or attestation.
Do not add 44 to the supported set without format/layout evidence.

No game assets were committed or published. No Windows GMod/Oracle was launched.
Physical iPad loading, model rendering and prop/physgun acceptance remain open.

## v44 identity boundary follow-up

Added SourceStudioFileIdentity for the bounded 80-byte identity prefix of v44
and v48 (magic, version, checksum, name and exact file length). It is deliberately
separate from SourceStudioModel: v44 is not added to renderable versions. This
lets real PHY checks proceed without falsely decoding v44 bones/sequences as v48.

Format evidence, read as definitions only, independent implementation:
- Crowbar SourceMdlFile44.ReadMdlHeader00 at commit
  0d46f3b6a694b74453db407c72c12a9685d8eb1d:
  https://github.com/ZeqMacaw/Crowbar/blob/0d46f3b6a694b74453db407c72c12a9685d8eb1d/Crowbar/Core/GameModel/SourceModel44/SourceMdlFile44.vb
- Valve v48 studiohdr_t at c8f4c6351162fbff83bfa5a428d45d1e6eed3824:
  https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/public/studio.h

Observed result on the supplied repaired ZIP: wood_crate001a MDL version 44,
MDL 1,604 bytes, PHY 1,208 bytes, one structurally decoded collision ledge.
Real-asset identity/PHY checksum/shape test and identity-validation regression
both passed on Windows. The collision remains explicitly unattested. No
production model-validation/attestation requirement was weakened, and the full
renderable-model decoder still supports only v48.
