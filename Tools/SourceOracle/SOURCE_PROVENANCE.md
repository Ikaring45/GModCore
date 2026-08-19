# Source compatibility provenance and release gate

## Inspected references

- Upstream: `https://github.com/ValveSoftware/source-sdk-2013`
- Pinned inspection commit: `c8f4c6351162fbff83bfa5a428d45d1e6eed3824`
- Public declarations and behavior references consulted include
  `src/public/filesystem.h`, `src/public/filesystem_init.cpp`,
  `src/public/bspfile.h`, `src/public/vtf/vtf.h`,
  `src/public/bitmap/imageformat.h`, `src/public/const.h`,
  `src/public/in_buttons.h`, `src/public/coordsize.h`,
  `src/game/server/entitylist.cpp`, `src/game/server/physics_main.cpp`,
  `src/game/shared/gamemovement.cpp`, and
  `src/utils/vbsp/materialpatch.cpp`.
- The `Source*.swift` files are newly authored Swift compatibility code. No
  Source SDK source file is vendored in this working tree. This statement is
  provenance, not a legal conclusion about derivative works.
- Project-authorized base GMod game files are intentionally vendored in the
  dedicated resource and map bundles. Their logical paths, sizes, and hashes are
  fixed by the tracked manifests and validators. Workshop, download-cache, and
  addon content are outside that authorization and are not included.
- Installed GMod/HL2 content is otherwise read in place by diagnostic and Oracle
  tooling. Those tools do not copy unapproved game content into the repository
  or modify the installed game tree.

## Project-specific written authorization

The project owner has confirmed that Valve Corporation granted separate written
permission for Garry's PAD to consult the Source SDK while developing an
independent Source-compatible implementation for iPadOS, including distribution
of source code and binaries through GitHub, the App Store, and similar channels.
That permission expressly covers an implementation which does not run on the
Source 1 binary. The authorization is confidential and is intentionally not
stored or reproduced in this repository. Required attribution and notice terms
are managed by the project owner.

This confirmed project-specific authorization is the operative rights basis for
continuing technical work. Do not stop or reject Source compatibility work solely
because the public SDK license, read in isolation, describes Source 1 game mods.

## Public upstream license context

The pinned upstream `LICENSE` is the **SOURCE 1 SDK LICENSE**. It limits the
stated use grant to development of a modified Valve game running on Valve's
Source 1 engine. It also says a distribution of the SDK, substantial portions,
or modifications must be free of charge and include upstream `LICENSE`,
`thirdpartylegalnotices.txt`, the copyright notice, and the additional legal
provisions. The third-party notice file contains additional component-specific
conditions.

This project targets an independent ARM64/iPad compatibility engine rather
than Valve's Source 1 binary. The public repository alone would not establish
that broader permission; the separate written authorization recorded above is
what permits this project scope. Technical test success is still not evidence
that release packaging has satisfied the owner-managed attribution and notice
conditions.

## Release checklist

1. Pin and record every upstream revision used for implementation decisions.
2. Review the final diff for copied or closely translated upstream expression,
   not only for vendored files.
3. Preserve the project owner's confirmation of the separate written
   authorization outside the public repository; do not commit the confidential
   permission itself.
4. If the release contains the SDK, substantial portions, or modifications,
   include the exact pinned upstream `LICENSE` and
   `thirdpartylegalnotices.txt`, preserve notices, and satisfy all distribution
   conditions identified by review.
5. Include only game files specifically authorized by the project owner, in a
   dedicated resource/test bundle with origin, size, and hash manifests. Do not
   broaden that authorization to Workshop, cache, or addon content.
6. Keep raw Windows-oracle output separate from golden tests and label capture
   authentication status.

Source compatibility implementation and selective integration may proceed on
independent engineering branches. A public release must still use the approved
asset manifest and the attribution/notice package managed by the project owner.
