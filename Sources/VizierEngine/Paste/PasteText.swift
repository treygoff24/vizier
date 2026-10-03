/// What a take pastes: its text followed by one space, so back-to-back takes into the same field
/// stay separate words ("well. I", not "well.I"). Text that already ends in whitespace, such as a
/// paragraph break, gets nothing more.
public enum PasteText {
    public static func separated(_ text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return text }
        return text + " "
    }
}
