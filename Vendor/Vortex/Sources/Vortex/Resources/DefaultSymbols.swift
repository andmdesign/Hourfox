//
// DefaultSymbols.swift
// Vortex
// https://www.github.com/twostraws/Vortex
// See LICENSE for license information.
//
// Tempo: в оригинале картинки берутся из каталога ассетов, а его без Xcode не собрать.
// Заменены на SF Symbols — Tempo всё равно передаёт свои символы.

import SwiftUI

extension Image {
    public static let circle = Image(systemName: "circle.fill")
    public static let confetti = Image(systemName: "square.fill")
    public static let sparkle = Image(systemName: "sparkle")
}
