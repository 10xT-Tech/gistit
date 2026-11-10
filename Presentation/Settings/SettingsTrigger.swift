//
//  SettingsTrigger.swift
//  EnglishHelper — Presentation
//
//  Adds the Settings gear to a screen's toolbar (the sheet itself is hosted once at the root), and
//  puts the screen's large title in the same row as the gear (`.inlineLarge`) — a separate title row
//  would push every main screen a row lower, its bottom behind the tab bar. Applied inside each
//  tab's NavigationStack so all five main screens look the same.
//

import SwiftUI

struct SettingsTrigger: ViewModifier {
    @Environment(AppUIState.self) private var ui

    func body(content: Content) -> some View {
        content
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { ui.showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Loc.t("Настройки", "Settings"))
            }
        }
    }
}

extension View {
    func settingsTrigger() -> some View { modifier(SettingsTrigger()) }
}
