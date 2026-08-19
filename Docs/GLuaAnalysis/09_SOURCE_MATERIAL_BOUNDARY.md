# Source material resolver boundary

The current Apple renderer and GLua runtime do not share one mutable material
search-path registry.

- GLua resolves `Material` and `IMaterial` metadata through the client session's
  mounted VFS. That VFS is the correct future boundary for addon and Workshop
  overlays.
- Metal's `GModMetalSurfaceSourceMaterialResolver` is process-static and reads
  only the immutable `GModGameAssets` bundle. Its cache and decoded-image
  bounds apply only to that exact manifest-backed corpus.
- The bundled corpus is generated from stock Lua literals and the declared
  base-game VPK precedence. It is a release whitelist, not an addon resolver.

Consequently, adding an addon mount to GLua must not be claimed to make its
VMT/VTF assets renderable by Metal. Addon material rendering stays explicitly
unsupported until both layers receive one session-scoped, precedence-aware
resolver with coherent cache invalidation and the existing VMT/VTF allocation
bounds. The bundle-only Metal lookup must not be broadened independently.
