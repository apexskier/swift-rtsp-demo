//
//  DataExtensions.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-18.
//

import Foundation

extension Data {
    mutating func replace<T>(at: Data.Index, with value: T) {
        Swift.withUnsafeBytes(of: value) {
            self.replaceSubrange(at..<at.advanced(by: MemoryLayout<T>.stride), with: $0)
        }
    }

    mutating func append<Other>(value: Other) {
        Swift.withUnsafeBytes(of: value) {
            self += $0
        }
    }
}
