//
//  LogLine.swift
//  BeaverTail
//

import Foundation

/// Explicit line wrapper that locks text to its original file position index
struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let originalIndex: Int
    let text: String
}
