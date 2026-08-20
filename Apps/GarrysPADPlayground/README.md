# Garry's PAD in Swift Playgrounds

This is the thin App Playground host. The game runtime remains the `GModApp`
library product in this repository; the large user-owned game content stays in
one local ZIP and is never committed to GitHub.

## One-time setup on iPad

1. In Swift Playgrounds, create a new **App** named `GarrysPAD`.
2. Add the Swift package `https://github.com/Ikaring45/GModCore` and enable its
   `GModApp` product.
3. Replace the generated `ContentView.swift` with the file beside this README.
4. Add exactly one `GarrysPAD_Content_*.zip` to the App Playground's Resources
   using the project navigator. Do not unzip it.
5. Run the app.

At launch the app reads the ZIP64 directory without extracting the archive,
shows the GMod-styled HTML home screen, then presents `gm_construct` and
`gm_flatgrass`. Selecting a world reads that BSP directly from the ZIP and
starts the paired Sandbox SERVER/CLIENT session. The on-screen left joystick
moves, the right pad looks, and **Open Spawn Menu** opens the live Sandbox VGUI.

If the ZIP is missing, invalid, duplicated, or lacks either stock BSP, startup
stays on a diagnostic screen instead of silently falling back to unrelated
content.

## Creating the ZIP on the Windows PC

Run `Tools/ContentPack/New-GarrysPADContentPack.ps1` from the repository, then
copy its output to Files/iCloud Drive and add that ZIP to the App Playground's
Resources. The recommended filename is:

`GarrysPAD_Content_Playground.zip`

Use the packer's `-Profile Playground` option. This is currently about 93 MB
for the stock installation, versus roughly 4.84 GB for the future-facing VPK
`Playable` profile.

The current direct reader consumes stored maps and home images without a
second multi-gigabyte extraction. Deflated text entries and the full VPK-backed
audio/material mount remain the next importer stage; the audited Lua, VGUI,
fonts, and material startup closure is still supplied by the `GModApp` package.
