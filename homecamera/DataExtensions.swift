//
//  DataExtensions.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-18.
//

import Foundation

extension Data {
    mutating func replaceSubrange<T>(_ range: Range<Data.Index>, with value: T) {
        Swift.withUnsafeBytes(of: value) {
            self.replaceSubrange(range, with: $0)
        }
    }

    mutating func append<Other>(value: Other) {
        Swift.withUnsafeBytes(of: value) {
            self += $0
        }
    }
}
