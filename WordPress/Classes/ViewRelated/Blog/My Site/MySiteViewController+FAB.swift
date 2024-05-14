
extension MySiteViewController {

    /// Make a create button coordinator with
    /// - Returns: CreateButtonCoordinator with new post, page, and story actions.
    @objc func makeCreateButtonCoordinator() -> CreateButtonCoordinator {

        let newPage = {
            let presenter = RootViewCoordinator.sharedPresenter
            let blog = presenter.currentOrLastBlog()
            presenter.showPageEditor(forBlog: blog)
        }

        let newPost = { [weak self] in
            let presenter = RootViewCoordinator.sharedPresenter
            presenter.showPostTab(completion: {
                self?.startAlertTimer()
            })
        }

        let newPostFromAudio = { [weak self] in
            // TODO:
        }

        let newStory = {
            let presenter = RootViewCoordinator.sharedPresenter
            let blog = presenter.currentOrLastBlog()
            presenter.showStoryEditor(forBlog: blog)
        }

        let source = "my_site"

        var actions: [ActionSheetItem] = []

        if blog?.supports(.stories) ?? false {
            actions.append(StoryAction(handler: newStory, source: source))
        }

        actions.append(PostAction(handler: newPost, source: source))
        if FeatureFlag.voiceToContent.enabled && (blog?.isHostedAtWPcom ?? false) {
            actions.append(PostFromAudioAction(handler: newPostFromAudio, source: source))
        }
        if blog?.supports(.pages) ?? false {
            actions.append(PageAction(handler: newPage, source: source))
        }

        let coordinator = CreateButtonCoordinator(self, actions: actions, source: source, blog: blog)
        return coordinator
    }
}
