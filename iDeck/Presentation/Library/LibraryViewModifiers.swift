// LibraryViewModifiers.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

extension View {
    /// A library cover as Madeira draws it: the card's full width at 2:3.
    func libraryCoverFrame() -> some View {
        frame(maxWidth: .infinity).aspectRatio(2.0 / 3.0, contentMode: .fit)
    }
}

/// Download controls (Pause, Stop, Resume) share one fixed size side by side.
extension View {
    func downloadControlLabel() -> some View {
        self.lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
    }
}
