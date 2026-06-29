//
//  Item.swift
//  Demo06
//
//  Created by Daniel Eduardo Palomino Pacahuala on 29/06/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
