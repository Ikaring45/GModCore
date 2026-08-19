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
  Source SDK source file or game asset is vendored in this working tree. This
  statement is provenance, not a legal conclusion about derivative works.
- Installed GMod/HL2 content was read locally for format diagnostics only. The
  diagnostic did not copy game assets into this repository.

## Upstream license gate

The pinned upstream `LICENSE` is the **SOURCE 1 SDK LICENSE**. It limits the
stated use grant to development of a modified Valve game running on Valve's
Source 1 engine. It also says a distribution of the SDK, substantial portions,
or modifications must be free of charge and include upstream `LICENSE`,
`thirdpartylegalnotices.txt`, the copyright notice, and the additional legal
provisions. The third-party notice file contains additional component-specific
conditions.

This project targets an independent ARM64/iPad compatibility engine rather
than Valve's Source 1 binary. Therefore the current Source bundle is **not
release-cleared solely by the existence of the public SDK repository**.
Before any independent release, a qualified license review must decide whether
the implementation is within the user's permissions and whether the upstream
license/notice files and additional obligations apply. Do not infer that
permission from technical test success.

## Release checklist

1. Pin and record every upstream revision used for implementation decisions.
2. Review the final diff for copied or closely translated upstream expression,
   not only for vendored files.
3. Obtain the required legal/ownership confirmation for the intended iPad
   distribution model.
4. If the release contains the SDK, substantial portions, or modifications,
   include the exact pinned upstream `LICENSE` and
   `thirdpartylegalnotices.txt`, preserve notices, and satisfy all distribution
   conditions identified by review.
5. Keep proprietary GMod/HL2 assets outside the repository and require users to
   supply lawfully owned content through the compatibility filesystem.
6. Keep raw Windows-oracle output separate from golden tests and label capture
   authentication status.

Until this checklist is completed, Source compatibility work may be tested as
an isolated engineering branch but must not be described as release-ready.
