import Foundation

protocol RootViewPresenter {

    // MARK: General

    var rootViewController: UIViewController { get }
    func showBlogDetails(for blog: Blog)
    func getMeScenePresenter() -> ScenePresenter
    func currentlySelectedScreen() -> String!
    func currentlyVisibleBlog() -> Blog?

    // MARK: Reader

    var readerTabViewController: ReaderTabViewController? { get }
    func showReaderTab()
    func showReaderTab(forPost: NSNumber!, onBlog: NSNumber!)
    func switchToDiscover()
    func switchToSavedPosts()
    func resetReaderDiscoverNudgeFlow()
    func resetReaderTab()
    func navigateToReaderSearch()
    func switchToTopic(where predicate: (ReaderAbstractTopic) -> Bool)
    func switchToMyLikes()
    func switchToFollowedSites()
    func navigateToReaderSite(_ topic: ReaderSiteTopic)
    func navigateToReaderTag( _ topic: ReaderTagTopic)
    func navigateToReader(_ pushControlller: UIViewController?)

    // MARK: My Site

    var mySitesCoordinator: MySitesCoordinator! { get }
    func showMySitesTab()
    func showPages(for blog: Blog)
    func showPosts(for blog: Blog)
    func showMedia(for blog: Blog)

    // MARK: Notifications

    func showNotificationsTab()
    func showNotificationsTabForNote(withID notificationID: String!)
    func switchNotificationsTabToNotificationSettings()
    func popNotificationsTabToRoot()

}

extension RootViewPresenter {
    func currentOrLastBlog() -> Blog? {
        if let blog = currentlyVisibleBlog() {
            return blog
        }
        let context = ContextManager.shared.mainContext
        return Blog.lastUsedOrFirst(in: context)
    }
}
