import Foundation

struct MonitaskPeriod: Decodable {
    let id: String
    let projectId: String
    let dateStart: Date
    let dateEnd: Date
    let dateLastActive: Date
    let duration: Double

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case projectId = "ProjectId"
        case dateStart = "DateStart"
        case dateEnd = "DateEnd"
        case dateLastActive = "DateLastActive"
        case duration = "Duration"
    }
}

struct MonitaskSettings: Decodable {
    let lastSelectedProjectId: String?

    enum CodingKeys: String, CodingKey {
        case lastSelectedProjectId = "LastSelectedProjectId"
    }
}

struct ProjectInfo: Decodable {
    let projects: [Project]

    enum CodingKeys: String, CodingKey {
        case projects = "Projects"
    }
}

struct Project: Decodable {
    let duration: Double
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case duration = "Duration"
        case id = "Id"
        case name = "Name"
    }
}

struct TrackingSnapshot {
    let isTracking: Bool
    let totalSeconds: Int
    let activeSeconds: Int
    let selectedProjectName: String
    let lastActiveAt: Date?
    let lastUpdated: Date
}
