/// Committed keyboard input only. Native IME composition stays in UITextInput
/// until the user accepts a candidate; Lua owns the focused TextEntry value.
public enum GModPlayableClientTextEdit: Sendable, Equatable {
    case insert(String)
    case deleteBackward
    case submit
}
