# GModLua — Lua 5.1 Full Runtime Candidate

Date: 2026-08-19

This is the first consolidated pure-Swift ARM64 Lua 5.1 runtime candidate for GModCore.
It is deliberately packaged as one milestone rather than many tiny feature drops.

## Implemented and compile-tested

### Language / parser
- Lua 5.1 keywords and grammar used by the current runtime
- locals/globals, multiple assignment
- functions, closures, upvalues
- methods (`:`), field/index access
- multiple return values
- varargs (`...`)
- if / elseif / else
- while / repeat-until
- numeric for / generic for
- do/end, break
- operator precedence
- arithmetic, comparison, boolean operators
- concatenation and length
- long bracket strings/comments
- shebang line handling
- GLua aliases/extensions already used by GModCore: `continue`, `&&`, `||`, `!`, `!=`, `//`, `/* ... */`

### Runtime types
- nil, boolean, number
- byte-oriented Lua string
- table
- Lua function / native Swift function
- userdata
- thread/coroutine

### Tables / metatables
- raw and normal indexing
- object identity table keys
- `__index`, `__newindex`
- `__call`, `__tostring`
- arithmetic metamethods
- comparison metamethods
- concat / length / unary minus
- metatable access APIs

### Functions / environments
- lexical closures
- `getfenv` / `setfenv`
- `_G`
- protected calls (`pcall`, `xpcall`)
- `load`, `loadstring`, `loadfile`, `dofile`
- in-runtime `string.dump` / `loadstring` round trip

### Coroutines
- create / resume / yield
- wrap / status / running
- nested yield/resume across Lua/Swift call stacks

### Standard libraries
- base library
- coroutine
- package / require / module / package.seeall
- math
- string
- Lua pattern matcher used by find/match/gmatch/gsub
- table
- os (sandbox-safe)
- io (sandbox-safe, partial host limitations)
- debug surface

### GMod-facing integration
- SERVER / CLIENT / MENU realm enum
- realm-prefixed logging
- fileLoader hook ready to be replaced by GMod VFS
- comprehensive one-shot smoke test for iPad

## Local verification performed

The pure-Swift runtime and GMLuaRuntime wrapper compile successfully together.
The comprehensive smoke test currently produces successful output for:
- arithmetic/control flow
- multiple return + vararg + pcall
- closures/methods
- metatable arithmetic/comparison/call/tostring
- environments
- loadstring + dump round trip
- nested coroutines
- Lua patterns
- package/require/module
- math/table/string libraries
- binary strings including NUL
- userdata/newproxy
- debug surface
- xpcall/error handling

## Important: why this is still called a candidate

Do NOT call this "Lua 5.1 conformance certified" yet.

The remaining conformance work is primarily:
1. Run the official Lua 5.1 basic test suite end-to-end and reach `final OK`.
2. Fix any semantic differences revealed by those tests.
3. Strengthen Lua-style GC behavior:
   - weak-key/weak-value tables
   - finalization ordering / `__gc`
   - collectgarbage step/count semantics
4. Strengthen debug hooks and exact stack/local/upvalue information.
5. Complete exact IO stream semantics and edge cases.
6. Decide whether PUC Lua 5.1 binary-chunk interoperability is required.
   The current `string.dump` is an internal GModLua round-trip representation, not PUC Lua bytecode.
7. Tail-call elimination / deep recursion compatibility may need a VM-style execution backend if tests expose Swift-stack limitations.

These are deliberately documented instead of silently pretending the implementation is already bit-for-bit PUC Lua.

## Repository installation

Copy/overwrite the included `Sources/` tree into the GModCore repository.
The current GModCore `Package.swift` already has a pure-Swift `GModLua` target, so no Package.swift change is expected for this bundle.
