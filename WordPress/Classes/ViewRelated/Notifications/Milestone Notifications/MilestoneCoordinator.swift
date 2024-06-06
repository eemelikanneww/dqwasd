import SwiftUI
import UIKit

protocol MilestoneCoordinatorDelegate: AnyObject {
    func previousNotificationTapped(notification: Notification?)
    func nextNotificationTapped(notification: Notification?)
}

final class MilestoneCoordinator {
    private let notification: Notification
    private weak var coordinatorDelegate: MilestoneCoordinatorDelegate?

    init(notification: Notification, coordinatorDelegate: MilestoneCoordinatorDelegate?) {
        self.notification = notification
        self.coordinatorDelegate = coordinatorDelegate
    }

    func createHostingController() -> MilestoneHostingController<MilestoneView> {
        let hostingController = MilestoneHostingController(
            rootView: MilestoneView(
                milestoneImageURL: notification.iconURL,
                accentColor: .DS.Foreground.brand(isJetpack: AppConfiguration.isJetpack),
                title: "Happy aniversary with WordPress! "
            ),
            milestoneCoordinator: self,
            notification: notification
        )
        hostingController.navigationItem.largeTitleDisplayMode = .never
        hostingController.hidesBottomBarWhenPushed = true
        return hostingController
    }
}

extension MilestoneCoordinator: CommentDetailsNotificationDelegate {
    func previousNotificationTapped(current: Notification?) {
        coordinatorDelegate?.previousNotificationTapped(notification: current)
    }

    func nextNotificationTapped(current: Notification?) {
        coordinatorDelegate?.nextNotificationTapped(notification: current)
    }

    func commentWasModerated(for notification: Notification?) {}
}
