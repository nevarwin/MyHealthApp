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
    
    func dateKey(from date: Date) -> String {
        return formatter.string(from: date)
    }
}
