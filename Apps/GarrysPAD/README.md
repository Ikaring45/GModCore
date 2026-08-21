# Garry's PAD iPad host

`GarrysPAD.xcodeproj` is the installable iPadOS shell for the package at the
repository root. The application target links the local `GModApp` package
product and presents `GModMainView` as its SwiftUI lifecycle root.

Large GMod content packs are intentionally not application resources. On first
launch, `GModMainView` opens the system Files picker and retains a
security-scoped bookmark to the selected ZIP. Keeping the archive in Files or
iCloud Drive avoids copying and signing several gigabytes into every app build.

The checked-in defaults are intentionally generic:

- iPad only, with an iPadOS 16.0 deployment floor;
- bundle identifier `org.example.GarrysPAD`;
- release-candidate marketing version `0.1.53`, build `53`;
- Automatic signing in the project; and
- an accent-color catalog while final App Store icon artwork remains a release
  asset.

Open `GarrysPAD.xcodeproj`, select a development team, and replace the generic
bundle identifier before installing on a physical iPad. CI overrides signing
only for its unsigned generic-device build. Simulator builds use Xcode's local
ephemeral signing, so neither a development team nor a secret is required.

The shared `GarrysPAD` scheme contains `GarrysPADUITests`. Its launch smoke
starts the real app and waits for the accessibility root wrapped around
`GModMainView`, so a library-only build cannot satisfy the host gate.
