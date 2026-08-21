import Foundation
import GModLua

enum GMLuaColorConversion {
    static func install(into state: LuaState) {
        state.register("ColorToHSV") { [unowned state] arguments in
            guard let first = arguments.first,
                  case let .table(color) = first else {
                let actual = arguments.first?.typeName ?? "no value"
                throw LuaError.runtime(
                    "bad argument #1 to 'ColorToHSV' (table expected, got \(actual))"
                )
            }

            let red = try component("r", from: color, state: state)
            let green = try component("g", from: color, state: state)
            let blue = try component("b", from: color, state: state)

            let maximum = max(red, max(green, blue))
            let minimum = min(red, min(green, blue))
            let chroma = maximum - minimum
            let value = maximum / 255
            let saturation = maximum == 0 ? 0 : chroma / maximum

            let hue: Double
            if chroma == 0 {
                // GMod returns the canonical zero hue for every achromatic
                // Color; hue is otherwise undefined in HSV.
                hue = 0
            } else if maximum == red {
                var redHue = 60 * ((green - blue) / chroma)
                if redHue < 0 { redHue += 360 }
                hue = redHue
            } else if maximum == green {
                hue = 60 * (((blue - red) / chroma) + 2)
            } else {
                hue = 60 * (((red - green) / chroma) + 4)
            }

            return [.number(hue), .number(saturation), .number(value)]
        }
    }

    private static func component(
        _ name: String,
        from color: LuaTable,
        state: LuaState
    ) throws -> Double {
        let value = try state.rawTableValue(
            for: .string(LuaString(name)),
            in: color
        )
        guard case let .number(component) = value,
              component.isFinite,
              component >= 0,
              component <= 255 else {
            throw LuaError.runtime(
                "bad argument #1 to 'ColorToHSV' " +
                    "(Color field '\(name)' must be a finite number in [0, 255])"
            )
        }
        return component
    }
}
