import Foundation
import SwiftUI

enum ProductStateTone {
    case info
    case warning
    case error

    var color: Color {
        switch self {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    var systemImage: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }
}

enum ProductStateActionKind: Equatable {
    case runSetupWizard
    case openAccountsSettings
    case reconnectSettings
    case refreshNow
    case resetDateRange
    case exportAllTime
    case disableDemoMode
    case openSettings
}

struct ProductStateAction: Equatable {
    let title: String
    let kind: ProductStateActionKind
}

struct ProductStateCard: Equatable {
    let title: String
    let message: String
    let detail: String?
    let tone: ProductStateTone
    let primaryAction: ProductStateAction
    let secondaryAction: ProductStateAction?
}
