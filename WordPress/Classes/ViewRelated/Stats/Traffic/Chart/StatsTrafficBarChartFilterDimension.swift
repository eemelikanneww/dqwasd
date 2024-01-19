import Foundation

enum StatsTrafficBarChartFilterDimension: Int, CaseIterable {
    case views = 0, visitors, likes, comments
}

extension StatsTrafficBarChartFilterDimension {
    var accessibleDescription: String {
        switch self {
        case .views:
            return NSLocalizedString(
                "stats.traffic.accessibilityLabel.views",
                value: "Bar Chart depicting Views for selected period",
                comment: "This description is used to set the accessibility label for the Stats Traffic chart, with Views selected."
            )
        case .visitors:
            return NSLocalizedString(
                "stats.traffic.accessibilityLabel.visitors",
                value: "Bar Chart depicting Visitors for the selected period.",
                comment: "This description is used to set the accessibility label for the Stats Traffic chart, with Visitors selected."
            )
        case .likes:
            return NSLocalizedString(
                "stats.traffic.accessibilityLabel.likes",
                value: "Bar Chart depicting Likes for the selected period.",
                comment: "This description is used to set the accessibility label for the Stats Traffic chart, with Likes selected."
            )
        case .comments:
            return NSLocalizedString(
                "stats.traffic.accessibilityLabel.comments",
                value: "Bar Chart depicting Comments for the selected period.",
                comment: "This description is used to set the accessibility label for the Stats Traffic chart, with Comments selected."
            )
        }
    }
}
