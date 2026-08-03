//
//  ColoredSwitchToggleStyle.swift
//  BeaverTail
//
//  Custom switch toggle style: unlike the built-in `.switch` style (which only tints
//  the ON track and always draws the OFF track in the system's neutral gray), this
//  draws BOTH track states with the supplied colours and keeps a solid white knob that
//  is always visible — so a faint green "on" and faint red "off" both read clearly.
//

import SwiftUI
import AppKit

struct ColoredSwitchToggleStyle: ToggleStyle {
    var onTint: Color
    var offTint: Color

    private let trackWidth: CGFloat = 50.16   // 10% wider than the previous 45.6
    private let trackHeight: CGFloat = 23.294  // 5% taller than the previous 22.185
    private let knobInset: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        let knobHeight = trackHeight - knobInset * 2
        let knobWidth = knobHeight * 1.5  // indicator 50% wider than tall
        return ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? onTint : offTint)
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            Capsule()
                .fill(Color.white)
                .frame(width: knobWidth, height: knobHeight)
                .shadow(color: Color.black.opacity(0.25), radius: 0.5, x: 0, y: 0.5)
                .padding(knobInset)
        }
        .frame(width: trackWidth, height: trackHeight)
        .animation(.easeInOut(duration: 0.18), value: isOn)
        .contentShape(Capsule())
        .onTapGesture { configuration.isOn.toggle() }
    }
}
