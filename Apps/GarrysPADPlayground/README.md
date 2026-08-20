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
shows GMod's original HTML/CSS/JS home, then presents `gm_construct` and
`gm_flatgrass`. Selecting a world shows the original GMod loading document,
reads that BSP directly from the ZIP, resolves its VMT/VTF materials from the
nested VPKs, and starts the paired Sandbox SERVER/CLIENT session. Home UI
sounds also come from the nested GMod VPK. The on-screen left joystick moves,
the right pad looks, **JUMP** jumps, and **Open Spawn Menu** opens the live
Sandbox VGUI.

If the ZIP is missing, invalid, duplicated, or lacks either stock BSP, startup
stays on a diagnostic screen instead of silently falling back to unrelated
content.

## Creating the ZIP on the Windows PC

Run `Tools/ContentPack/New-GarrysPADContentPack.ps1` from the repository, then
copy its output to Files/iCloud Drive and add that ZIP to the App Playground's
Resources. The recommended filename is:

`GarrysPAD_Content_Playable.zip`

Use the packer's default `Playable` profile. The currently verified stock pack
is about 4.88 GB. The smaller `Playground` profile remains useful only for ZIP
transfer and home/BSP diagnostics; it deliberately omits the VPK families and
therefore cannot provide the real world textures or UI sounds.

The direct reader mounts the ZIP64 directory in place. Maps and HTML are read
as stored ZIP entries, while nested VPK directory/chunk files are read by exact
byte range; the iPad does not create a second multi-gigabyte extracted copy.
The audited Lua/VGUI/font startup closure is still supplied by `GModApp`.
