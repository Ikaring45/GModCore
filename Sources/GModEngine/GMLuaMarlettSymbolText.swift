/// The bundled Source Marlett face uses a Microsoft symbol cmap (3,0),
/// covering F030...F039 and F061...F079. Source passes byte characters to
/// that face; CoreText needs their explicit private-use code points. This
/// is deliberately not a generic remapping rule for arbitrary symbol fonts.
public enum GMLuaMarlettSymbolText {
    public static func supports(face: String) -> Bool {
        face.lowercased() == "marlett"
    }

    public static func mapped(_ text: String) -> String? {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 10 { result.append(scalar); continue }
            let byte = value >= 0xF000 ? value - 0xF000 : value
            guard (0x30...0x39).contains(byte) || (0x61...0x79).contains(byte),
                  let mapped = UnicodeScalar(0xF000 + byte) else { return nil }
            result.append(mapped)
        }
        return String(result)
    }
}
