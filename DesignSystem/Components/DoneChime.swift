//
//  DoneChime.swift
//  EnglishHelper — DesignSystem
//
//  The sound of a long job done (cards from photos): a short two-note chime (`Resources/done.caf`,
//  our own) with the success haptic. Played as a system sound: it follows the Ring/Silent switch and
//  the volume and mixes with whatever is playing — no audio session is touched, so a live Online
//  session is never disturbed. On silent, only the haptic.
//
//      .doneChime(when: model.phase == .done)
//

import SwiftUI
import AudioToolbox

public enum DoneChime {
    private static let sound: SystemSoundID? = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "done", withExtension: "caf") else { return nil }
        var id: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError ? id : nil
    }()

    public static func play() {
        if let sound { AudioServicesPlaySystemSound(sound) }
    }
}

public extension View {
    /// The chime and the success haptic when `done` turns true.
    func doneChime(when done: Bool) -> some View {
        sensoryFeedback(.success, trigger: done) { _, isDone in isDone }
            .onChange(of: done) { _, isDone in
                if isDone { DoneChime.play() }
            }
    }
}

private final class BundleToken {}
