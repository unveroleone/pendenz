import SwiftUI

// A button that is a row of a form or sits in one: red when it takes something away, blue when
// it starts something. The Mac draws such a button with a gray bezel, on which it reads as
// switched off, and fills a destructive one with a dim red that its red text is hard to read
// on. Without the bezel the colour says what the button is, as it does on the iPhone.
private struct FormAction: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
            .foregroundStyle(color)
    }
}

extension View {
    func formAction(_ color: Color) -> some View {
        modifier(FormAction(color: color))
    }
}

extension View {
    // For a switch and a date picker only. The system fills a switch that is on and the chosen
    // day with the tint and draws white on it. The app tint is the label color, white in dark
    // mode, so these two take a gray that carries white. Set on the whole form, the gray would
    // also reach menus, links and the sheets they open, and their text would read as switched off.
    func selectionTint() -> some View {
        tint(Color(.selection))
    }
}
