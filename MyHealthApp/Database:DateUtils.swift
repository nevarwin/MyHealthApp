//
//  Database:DateUtils.swift
//  MyHealthApp
//
//  Created by raven on 11/22/25.
//

import Foundation

class DateUtils {
    static let shared = DateUtils()
    let formatter: DateFormatter
    
    init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
    }
    
    // Converts Date object to "20251122"
    func dateKey(from date: Date) -> String {
        return formatter.string(from: date)
    }
    
    // NEW: Converts "20251122" back to Date object
    func date(from string: String) -> Date? {
        return formatter.date(from: string)
    }
}
