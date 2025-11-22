//
//  Database:DBHelper.swift
//  MyHealthApp
//
//  Created by raven on 11/22/25.
//

import Foundation
import Foundation
import SQLite3

class DBHelper {
    static let shared = DBHelper()
    var db: OpaquePointer?
    let dbPath: String = "myhealth.sqlite"
    
    init() {
        self.db = openDatabase()
        self.createTable()
    }

    func openDatabase() -> OpaquePointer? {
        let fileURL = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent(dbPath)
        var db: OpaquePointer?
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK { return nil }
        return db
    }

    func createTable() {
        // Legacy Schema: id (PK), entrydate (Text), distance (Real)
        let sql = "CREATE TABLE IF NOT EXISTS WalkingData(id INTEGER PRIMARY KEY AUTOINCREMENT, entrydate TEXT, distance REAL);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - The UPSERT Logic
    func addDistanceToDate(dateStr: String, amountToAdd: Double) {
        // 1. Check if a row exists for this date
        let checkSQL = "SELECT distance FROM WalkingData WHERE entrydate = ?;"
        var checkStmt: OpaquePointer?
        var currentDistance: Double = 0.0
        var rowExists = false
        
        if sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(checkStmt, 1, (dateStr as NSString).utf8String, -1, nil)
            
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                rowExists = true
                currentDistance = sqlite3_column_double(checkStmt, 0)
            }
        }
        sqlite3_finalize(checkStmt)
        
        if rowExists {
            // 2a. UPDATE: Add new amount to existing amount
            let newTotal = currentDistance + amountToAdd
            let updateSQL = "UPDATE WalkingData SET distance = ? WHERE entrydate = ?;"
            var updateStmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                sqlite3_bind_double(updateStmt, 1, newTotal)
                sqlite3_bind_text(updateStmt, 2, (dateStr as NSString).utf8String, -1, nil)
                sqlite3_step(updateStmt)
            }
            sqlite3_finalize(updateStmt)
            print("Updated \(dateStr): \(currentDistance) -> \(newTotal)")
            
        } else {
            // 2b. INSERT: Create new row
            let insertSQL = "INSERT INTO WalkingData (entrydate, distance) VALUES (?, ?);"
            var insertStmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(insertStmt, 1, (dateStr as NSString).utf8String, -1, nil)
                sqlite3_bind_double(insertStmt, 2, amountToAdd)
                sqlite3_step(insertStmt)
            }
            sqlite3_finalize(insertStmt)
            print("Inserted \(dateStr): \(amountToAdd)")
        }
    }
    
    // Helper to read data back for UI
    func readAll() -> [WalkData] {
        let sql = "SELECT entrydate, distance FROM WalkingData ORDER BY entrydate DESC;"
        var stmt: OpaquePointer?
        var result: [WalkData] = []
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dateStr = String(cString: sqlite3_column_text(stmt, 0))
                let val = sqlite3_column_double(stmt, 1)
                // Mocking an ID and Date object for the UI model
                result.append(WalkData(id: dateStr, startDate: Date(), value: val))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }
}
