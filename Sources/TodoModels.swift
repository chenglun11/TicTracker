//
//  TodoModels.swift
//  TicTracker
//
//  Created on 2026-03-04.
//

import Foundation

enum TaskPriority: String, Codable, CaseIterable {
    case low = "低"
    case medium = "中"
    case high = "高"

    var sortOrder: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}

struct TodoTask: Codable, Identifiable {
    let id: UUID
    var title: String
    var description: String
    var isCompleted: Bool
    var dueDate: Date?
    var priority: TaskPriority
    var createdAt: Date
    var completedAt: Date?
    var notificationID: String?

    init(id: UUID = UUID(), title: String, description: String = "",
         isCompleted: Bool = false, dueDate: Date? = nil,
         priority: TaskPriority = .medium, createdAt: Date = Date(),
         completedAt: Date? = nil, notificationID: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.priority = priority
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.notificationID = notificationID
    }
}
