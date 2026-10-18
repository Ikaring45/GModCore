import GModLua

enum GMLuaVGUIResourceSchemeFont {
    static func install(_ definition: SourceVGUIScheme.FontDefinition, runtime: GMLuaRuntime) throws -> String {
        let name = definition.registrationName
        if let existing = runtime.surfaceCommandState?.fontDescriptor(named: LuaString(name)) {
            guard existing.font.utf8String == definition.face, existing.size == definition.tall,
                  existing.extended, !existing.rotary,
                  existing.weight == definition.weight, existing.blurSize == definition.blurSize,
                  existing.scanlines == definition.scanlines, existing.antialias == definition.flags["antialias"],
                  existing.underline == definition.flags["underline"], existing.italic == definition.flags["italic"],
                  existing.strikeout == definition.flags["strikeout"], existing.symbol == definition.flags["symbol"],
                  existing.shadow == definition.flags["shadow"], existing.outline == definition.flags["outline"],
                  existing.additive == definition.flags["additive"] else {
                throw SourceVGUIScheme.SchemeError.unsupportedFont(definition.alias)
            }
            return name
        }
        let data = LuaTable()
        try runtime.state.setRawTableValue(.string(LuaString(definition.face)), for: .string("font"), in: data)
        for (key, value) in [("size", definition.tall), ("weight", definition.weight),
                             ("blursize", definition.blurSize), ("scanlines", definition.scanlines)] {
            try runtime.state.setRawTableValue(.number(Double(value)), for: .string(LuaString(key)), in: data)
        }
        for (key, value) in definition.flags {
            try runtime.state.setRawTableValue(.boolean(value), for: .string(LuaString(key)), in: data)
        }
        // Host UTF-8 text boundary, not an authored Scheme field. Do not drop
        // non-ASCII glyphs merely because native Scheme has no GLua extended key.
        try runtime.state.setRawTableValue(.boolean(true), for: .string("extended"), in: data)
        let create = try runtime.executeReturningValues("return surface.CreateFont").first ?? .nilValue
        _ = try runtime.state.call(create, arguments: [.string(LuaString(name)), .table(data)])
        return name
    }
}
