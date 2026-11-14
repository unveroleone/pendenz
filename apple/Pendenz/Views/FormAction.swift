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
