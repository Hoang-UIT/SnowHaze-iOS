//
//  TabViewController.swift
//  SnowHaze
//

//  Copyright © 2017 Illotros GmbH. All rights reserved.
//

import UIKit
import WebKit

protocol TabViewControllerDelegate: class {
	func tabViewController(_ controller: TabViewController, openTabForRequest request: URLRequest)
	func showSuggestions(searchString: String)
	func stopShowingSuggestions()
	func showToolBar(degree: CGFloat)
	func stopShowingOverlays()
	func showRenameBar(fallback: String?, prefill: String?, callback: @escaping (String?) -> Void)
	func boundingViews() -> (top: UIView?, bottom: UIView?)
}

class TabViewController: UIViewController {
	@IBOutlet var bookmarkHistoryView: BookmarkHistoryView!
	private let historyStore = HistoryStore.store
	private let bookmarkStore = BookmarkStore.store
	private var lastScrollPosition: CGFloat?
	private var lastScrollUp: Bool?

	weak var delegate: TabViewControllerDelegate?

	@IBOutlet weak var maskContent: UIView!
	@IBOutlet weak var maskImage: UIImageView!


	var tab: Tab? {
		willSet {
			webView = nil
			if let tab = tab {
				tab.controller?.navigationDelegate = nil
				tab.controller?.UIDelegate = nil
			}
		}
		didSet {
			guard let tab = tab else {
				return
			}
			guard let controller = tab.controller else {
				return
			}
			webView = controller.webView
			scale = 1

			controller.UIDelegate = self
			controller.navigationDelegate = self

			bookmarkHistoryView.reloadHistory()
			bookmarkHistoryView.reloadBookmarks()
			if controller.unused {
				webView.isHidden = true
				webView.alpha = 0
				bookmarkHistoryView.isHidden = false
				view.insertSubview(bookmarkHistoryView, at: 1)
			} else {
				webView.isHidden = false
				webView.alpha = 1
				bookmarkHistoryView.isHidden = true
				self.bookmarkHistoryView.removeFromSuperview()
				if webView.url == nil && !webView.isLoading {
					controller.localReload()
				}
			}
		}
	}

	var urlBar: URLBar? {
		didSet {
			stopInput()
			delegate?.stopShowingSuggestions()
		}
	}

	var isMasked: Bool = false {
		didSet {
			guard let tab = tab, oldValue != isMasked else {
				return
			}
			if isMasked {
				webView.isHidden = true
				bookmarkHistoryView.isHidden = true
				maskContent.isHidden = false
				urlBar?.progress = 0
				urlBar?.title = NSLocalizedString("masked tab title", comment: "displayed instead of title for masked tabs in app snapshots")
				let policy = PolicyManager.globalManager()
				let wrapper = policy.settingsWrapper
				let assessment = PolicyAssessor(wrapper: wrapper).assess(PolicyAssessor.allCategories)
				updateSecAssessment(assessment)
				let allWindows = UIApplication.shared.windows
				if !allWindows.isEmpty {
					let windows = allWindows.suffix(from: 1)
					for window in windows {
						if let root = window.rootViewController {
							if root is LockPresenterController {
								continue
							}
						}
						window.isHidden = true
					}
				}
				if let alert = presentedViewController as? UIAlertController {
					alert.view.isHidden = true
				}
			} else {
				webView.isHidden = tab.controller?.unused ?? true
				maskContent.isHidden = true
				bookmarkHistoryView.isHidden = !webView.isHidden
				urlBar?.progress = CGFloat(webView.estimatedProgress)
				urlBar?.attributedTitle = tab.formatedDisplayTitle
				updateSecAssessment()
				let allWindows = UIApplication.shared.windows
				if !allWindows.isEmpty {
					let windows = allWindows.suffix(from: 1)
					for window in windows {
						if let root = window.rootViewController {
							if root is LockPresenterController {
								continue
							}
						}
						window.isHidden = false
					}
				}
				if let alert = presentedViewController as? UIAlertController {
					alert.view.isHidden = false
				}
			}
		}
	}

	private var webView: WKWebView! {
		willSet {
			webView?.scrollView.delegate = nil
			webView?.removeFromSuperview()
		}
		didSet {
			if let webView = webView {
				webView.scrollView.delegate = self
				if #available(iOS 11, *) {
					webView.scrollView.contentInsetAdjustmentBehavior = .never
				}
				webView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
				webView.frame = view.bounds
				webView.allowsBackForwardNavigationGestures = true
				view.addSubview(webView)
				adjustWebviewSize(isIntemediate: isIntermediate(scale: scale))
			}
		}
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .background
		view.clipsToBounds = true

		let mask = #imageLiteral(resourceName: "masked").withRenderingMode(.alwaysTemplate)
		maskImage.image = mask
		maskImage.tintColor = .title

		NotificationCenter.default.addObserver(self, selector: #selector(bookmarkListDidChange(_:)), name: BOOKMARK_LIST_CHANGED_NOTIFICATION, object: bookmarkStore)
		NotificationCenter.default.addObserver(self, selector: #selector(addedHistoryItem(_:)), name: INSERT_HISTORY_NOTIFICATION, object: historyStore)
		NotificationCenter.default.addObserver(self, selector: #selector(deletedHistoryItem(_:)), name: DELETE_HISTORY_NOTIFICATION, object: historyStore)

		NotificationCenter.default.addObserver(self, selector: #selector(reloadStatsView(_:)), name: statsResetNotificationName, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(reloadStatsView(_:)), name: subscriptionPurchasedNotificationName, object: nil)

		bookmarkHistoryView.delegate = self
		bookmarkHistoryView.constrainedWidth = traitCollection.horizontalSizeClass == .compact
		bookmarkHistoryView.constrainedHeight = traitCollection.verticalSizeClass == .compact
		bookmarkHistoryView.hideStats = !PolicyManager.globalManager().keepStats
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		adjustWebviewSize(isIntemediate: isIntermediate(scale: scale))
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
		tab?.controller?.UIDelegate = nil
	}
}

// MARK: Internals
private extension TabViewController {
	func display(_ alert: UIAlertController, domain: String?, fallbackHandler: @escaping () -> Void) -> Bool {
		guard !TabAlertTransitioningDelegate.shared.isBusy else {
			if let controller = tab?.controller {
				TabAlertTransitioningDelegate.shared.notify(controller: controller)
			} else {
				fallbackHandler()
			}
			return false
		}
		if let domain = domain, !domain.isEmpty, tab?.controller?.shouldAllowIgnoreForIncedAlertCount(for: domain) ?? false {
			let ignoreTitle = NSLocalizedString("ignore alerts from this site alert button title", comment: "title of button to ignore further alerts by this site")
			let ignoreAction = UIAlertAction(title: ignoreTitle, style: .default) { _ in
				self.tab?.controller?.blockAlerts(from: domain)
				fallbackHandler()
			}
			alert.addAction(ignoreAction)
		}
		TabAlertTransitioningDelegate.shared.setup(delegate: alert.transitioningDelegate)
		alert.transitioningDelegate = TabAlertTransitioningDelegate.shared
		present(alert, animated: true, completion: nil)
		return true
	}

	private func adjustWebviewSize(isIntemediate: Bool) {
		let bounds = delegate?.boundingViews()
		let topOffset: CGFloat
		if let top = bounds?.top {
			let topRect = top.convert(top.bounds, to: view)
			topOffset = max(topRect.maxY, 0)
		} else {
			topOffset = 0
		}
		let bottomOffset: CGFloat
		if let bottom = bounds?.bottom {
			let bottomRect = bottom.convert(bottom.bounds, to: view)
			bottomOffset = max(view.bounds.maxY - bottomRect.minY, 0)
		} else {
			bottomOffset = 0
		}
		let insets = UIEdgeInsets(top: topOffset, left: 0, bottom: bottomOffset, right: 0)

		if let wv = webView {
			assert(wv.superview == view)
			let oldYOffset = wv.scrollView.bounds.minY + wv.scrollView.contentInset.top
			var tbInsets = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
			let reducedHeight = max(0, urlBar?.minLowerBound(in: view) ?? 0)
			tbInsets.top -= reducedHeight
			var newFrame = view.bounds
			newFrame.origin.y += reducedHeight
			newFrame.size.height -= reducedHeight
			wv.frame = newFrame
			wv.frame.size.width -= insets.left + insets.right
			wv.frame.origin.x += insets.left
			if isIntemediate {
				wv.scrollView.contentInset = tbInsets
				wv.scrollView.scrollIndicatorInsets = tbInsets
			} else {
				wv.scrollView.contentInset = .zero
				wv.scrollView.scrollIndicatorInsets = .zero
				wv.frame.size.height -= tbInsets.top + tbInsets.bottom
				wv.frame.origin.y += tbInsets.top
			}
			if #available(iOS 11, *) {
				let topCorrection = view.safeAreaInsets.top - wv.frame.minY
				if topCorrection > 0 {
					wv.scrollView.contentInset.top += topCorrection
					wv.scrollView.scrollIndicatorInsets.top += topCorrection
				}
				let bottomCorrection = view.safeAreaInsets.bottom - view.bounds.maxY + wv.frame.maxY
				if bottomCorrection > 0 {
					wv.scrollView.contentInset.bottom += bottomCorrection
					wv.scrollView.scrollIndicatorInsets.bottom += bottomCorrection
				}
			}
			wv.scrollView.bounds.origin.y = oldYOffset - wv.scrollView.contentInset.top
			if #available(iOS 11, *) {
				wv.scrollView.adjustedContentInsetDidChange()
			}
		}
		bookmarkHistoryView?.frame = view.bounds
		bookmarkHistoryView?.frame.size.height -= insets.top + insets.bottom
		bookmarkHistoryView?.frame.origin.y += insets.top
	}
}

// MARK: Control
extension TabViewController {
	func webViewForShareAction() -> WKWebView? {
		return tab?.controller?.unused ?? true ? nil : webView
	}

	func stopInput() {
		urlBar?.stopInput()
	}

	func showControls() {
		scale = 1
	}

	func updateSecAssessment(_ assessment: PolicyAssessmentResult? = nil) {
		guard let assessment = assessment ?? tab?.controller?.securityAssessment else {
			return
		}
		urlBar?.securityIconColor = assessment.color
		urlBar?.securityIcon = assessment.image
		urlBar?.securityName = assessment.name + NSLocalizedString("privacy assessment privacy suffix", comment: "privacy term to be appended to privacy assessment name")
	}

	private func isIntermediate(scale: CGFloat) -> Bool {
		return !(scale == 1 || scale == 0)
	}

	private var scale: CGFloat {
		set {
			if newValue != scale {
				urlBar?.scale = newValue
				delegate?.showToolBar(degree: newValue)
				if newValue < 1 {
					stopInput()
				}
				adjustWebviewSize(isIntemediate: isIntermediate(scale: newValue))
			}
		}
		get {
			return urlBar?.scale ?? 1
		}
	}
}

// MARK: Tab Controller UI Delegate
extension TabViewController: TabControllerUIDelegate {
	func tabController(_ controller: TabController, createTabForRequest request: URLRequest) {
		delegate?.tabViewController(self, openTabForRequest: request)
	}

	func tabController(_ controller: TabController, displayJSAlert alert: String, withFrameInfo frameInfo: WKFrameInfo, completionHandler: @escaping () -> Void) -> Bool {
		let alertController = UIAlertController(title: frameInfo.securityOrigin.host, message: alert, preferredStyle: .alert)
		let okText = NSLocalizedString("js alert panel confirmation button title", comment: "Used to confirm message")
		let confirmAction = UIAlertAction(title: okText, style: .default) { _ in completionHandler() }
		alertController.addAction(confirmAction)
		return display(alertController, domain: frameInfo.securityOrigin.host, fallbackHandler: completionHandler)
	}

	func tabController(_ controller: TabController, displayJSConfirmDialogWithQuestion question: String, frameInfo: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) -> Bool {
		let alertController = UIAlertController(title: frameInfo.securityOrigin.host, message: question, preferredStyle: .alert)
		let okText = NSLocalizedString("js confirm panel confirm button title", comment: "Used to accept message")
		let cancelText = NSLocalizedString("js confirm panel cancel button title", comment: "Used to decline message")
		let cancelAction = UIAlertAction(title: cancelText, style: .cancel) { _ in completionHandler(false) }
		alertController.addAction(cancelAction)
		let confirmAction = UIAlertAction(title: okText, style: .default) { _ in completionHandler(true) }
		alertController.addAction(confirmAction)
		return display(alertController, domain: frameInfo.securityOrigin.host, fallbackHandler: { completionHandler(false) })
	}

	func tabController(_ controller: TabController, displayJSPromptWithQuestion question: String, defaultText: String?, frameInfo: WKFrameInfo, completionHandler: @escaping (String?) -> Void) -> Bool {
		let alertController = UIAlertController(title: frameInfo.securityOrigin.host, message: question, preferredStyle: .alert)
		alertController.addTextField { textField in
			textField.placeholder = defaultText
			textField.autocapitalizationType = .words
			textField.autocorrectionType = .yes
		}
		let okText = NSLocalizedString("js text prompt confirm button title", comment: "Used to enter text")
		let cancelText = NSLocalizedString("js text prompt cancel button title", comment: "Used to not enter text")
		let cancelAction = UIAlertAction(title: cancelText, style: .cancel) { _ in completionHandler(nil) }
		alertController.addAction(cancelAction)
		let confirmAction = UIAlertAction(title: okText, style: .default) { _ in completionHandler(alertController.textFields?.first?.text ?? "") }
		alertController.addAction(confirmAction)
		return display(alertController, domain: frameInfo.securityOrigin.host, fallbackHandler: { completionHandler(nil) })
	}

	func tabController(_ controller: TabController, displayAlert alert: UIAlertController, forDomain domain: String?, fallbackHandler: @escaping () -> Void) -> Bool {
		return display(alert, domain: domain, fallbackHandler: fallbackHandler)
	}
}

// MARK: Tab Controller Navigation Delegate
extension TabViewController: TabControllerNavigationDelegate {
	func tabController(_ controller: TabController, didLoadTitle title: String?) {
		urlBar?.attributedTitle = tab?.formatedDisplayTitle
	}

	func tabController(_ controller: TabController, isLoading url: URL?) {
		urlBar?.url = controller.tab.displayURL
		Stats.shared.loading(url, in: controller.tab)
	}

	func tabController(_ controller: TabController, didUpgradeLoadOf url: URL) {
		Stats.shared.upgradedLoad(of: url, in: controller.tab)
	}

	func tabController(_ controller: TabController, estimatedProgress: Double) {
		if estimatedProgress > 0 && urlBar?.progress == 0 {
			stopInput()
			delegate?.stopShowingOverlays()
		}
		urlBar?.progress = CGFloat(estimatedProgress)
	}

	func tabControllerWillStartLoading(_ controller: TabController) {
		stopInput()
		urlBar?.stopInput()
		if webView.isHidden {
			webView.alpha = 0
			webView.isHidden = false
			UIView.animate(withDuration: 0.3, animations: {
				self.webView.alpha = 1
			}, completion: { _ in
				self.bookmarkHistoryView.isHidden = true
				self.bookmarkHistoryView.removeFromSuperview()
			})
		}
	}

	func tabController(_ controller: TabController, securityAssessmentDidUpdate assessment: PolicyAssessmentResult) {
		updateSecAssessment(assessment)
	}

	func tabControllerCanGoForwardBackwardUpdate(_ controller: TabController) {
		urlBar?.canGoBack = controller.canGoBack
		urlBar?.canGoForward = controller.canGoForward
	}

	func tabController(_ controller: TabController, serverTrustDidChange trust: SecTrust?) {
		urlBar?.attributedTitle = tab?.formatedDisplayTitle
	}
}

// MARK: Bookmark History Delegate
extension TabViewController: BookmarkHistoryDelegate {
	var viewControllerForPreviewing: UIViewController {
		return self
	}

	func previewController(for url: URL) -> PagePreviewController? {
		guard let tab = self.tab else {
			return nil
		}
		return PagePreviewController(url: url, tab: tab)
	}

	func load(url: URL) {
		tab?.controller?.load(url: url)
	}

	func load(_ input: String) {
		tab?.controller?.load(userInput: input)
	}

	var historyItems: [[HistoryItem]]? {
		return historyStore.itemsByDate
	}

	func removeHistoryItem(at indexPath: IndexPath) {
		historyStore.removeItem(at: indexPath)
	}

	func removeSection(atIndex index: Int) {
		historyStore.removeSection(at: index)
	}

	func didSelect(historyItem item: HistoryItem) {
		tab?.controller?.load(url: item.url)
	}

	var bookmarks: [Bookmark] {
		return bookmarkStore.items
	}

	func didSelect(bookmark: Bookmark) {
		tab?.controller?.load(url: bookmark.URL)
		bookmark.wasSelected()
	}

	func remove(bookmark: Bookmark) {
		bookmarkStore.remove(item: bookmark)
	}

	func refresh(bookmark: Bookmark) {
		if let tab = tab {
			bookmark.reload(in: tab)
		}
	}

	func rename(bookmark: Bookmark) {
		delegate?.showRenameBar(fallback: bookmark.title, prefill: bookmark.name) { newName in
			bookmark.name = newName?.isEmpty == true ? nil : newName
		}
	}

	func makeBookmark(for url: URL) {
		if let tab = tab {
			bookmarkStore.addItem(for: url, loadWith: tab)
		}
	}

	func numerOfStats(in statsView: StatsView) -> Int {
		return 4
	}

	func titleOfStat(_ index: Int, in statsView: StatsView) -> String {
		switch index {
			case 0:		return NSLocalizedString("https upgrades usage stats name", comment: "name of the https upgrades usage stat")
			case 1:		return NSLocalizedString("blocked trackers usage stats name", comment: "name of the blocked trackers usage stat")
			case 2:		return NSLocalizedString("ephemeral cookies usage stats name", comment: "name of the ephemeral cookies usage stat")
			case 3:		return NSLocalizedString("vpn protected loads usage stats name", comment: "name of the vpn protected loads usage stat")
			default:	fatalError("unexpected index")
		}
	}

	func accessibilityFormatOfStat(_ index: Int, in statsView: StatsView) -> String {
		switch index {
			case 0:		return NSLocalizedString("https upgrades usage stats accessibility format", comment: "format of the accessibility label of the https upgrades usage stat")
			case 1:		return NSLocalizedString("blocked trackers usage stats accessibility format", comment: "format of the accessibility label of the blocked trackers usage stat")
			case 2:		return NSLocalizedString("ephemeral cookies usage stats accessibility format", comment: "format of the accessibility label of the ephemeral cookies usage stat")
			case 3:		return NSLocalizedString("vpn protected loads usage stats accessibility format", comment: "format of the accessibility label of the vpn protected loads usage stat")
			default:	fatalError("unexpected index")
		}
	}

	func countForStat(_ index: Int, in statsView: StatsView) -> Int {
		let stats = Stats.shared
		let count: UInt
		switch index {
			case 0:		count = stats.upgradedLoads
			case 1:		count = stats.blockedTrackers
			case 2:		count = stats.killedCookies
			case 3:		count = stats.protectedSiteLoads
			default:	fatalError("unexpected index")
		}
		return Int(count)
	}

	func colorForStat(_ index: Int, in statsView: StatsView) -> UIColor {
		switch index {
			case 0:		return .httpsStats
			case 1:		return .trackerStats
			case 2:		return .cookieStats
			case 3:		return .vpnStats
			default:	fatalError("unexpected index")
		}
	}

	func dimmStat(_ index: Int, in statsView: StatsView) -> Bool {
		return index == 3 && !SubscriptionManager.shared.hasSubscription
	}

	func statTapped(at index: Int, in statsView: StatsView) {
		if index == 3 && !SubscriptionManager.shared.hasSubscription {
			MainViewController.openSettings(type: .subscription)
		}
	}
}

// MARK: Notifications
extension TabViewController {
	@objc private func bookmarkListDidChange(_ notification: Notification) {
		let new = notification.userInfo?[NEW_BOOKMARKS_INDEX_USER_INFO_KEY] as? [Int]
		let deleted = notification.userInfo?[DELETED_BOOKMARKS_INDEX_USER_INFO_KEY] as? [Int]
		let from = notification.userInfo?[MOVED_BOOKMARKS_FROM_INDEX_USER_INFO_KEY] as? [Int]
		let to = notification.userInfo?[MOVED_BOOKMARKS_TO_INDEX_USER_INFO_KEY] as? [Int]
		bookmarkHistoryView.reloadBookmarks(new: new, deleted: deleted, movedFrom: from, movedTo: to)
	}

	@objc private func addedHistoryItem(_ notification: Notification) {
		guard let info = notification.userInfo else {
			return
		}
		guard let section = info[HISTORY_SECTION_INDEX] as? Int else {
			return
		}
		let index = info[HISTORY_ITEM_INDEX] as? Int
		bookmarkHistoryView.insertHistoryItem(section: section, index: index)
	}

	@objc private func deletedHistoryItem(_ notification: Notification) {
		guard let info = notification.userInfo else {
			return
		}
		guard let section = info[HISTORY_SECTION_INDEX] as? Int else {
			return
		}
		let index = info[HISTORY_ITEM_INDEX] as? Int
		bookmarkHistoryView.deleteHistoryItems(section: section, index: index)
	}

	@objc private func reloadStatsView(_ notification: Notification) {
		bookmarkHistoryView.hideStats = !PolicyManager.globalManager().keepStats
		bookmarkHistoryView.reloadStats()
	}
}

// MARK: UIContentContainer methods
extension TabViewController {
	override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
		super.willTransition(to: newCollection, with: coordinator)
		bookmarkHistoryView.constrainedWidth = newCollection.horizontalSizeClass == .compact
		bookmarkHistoryView.constrainedHeight = newCollection.verticalSizeClass == .compact
	}
}

extension TabViewController: UIScrollViewDelegate {
	func scrollViewDidScroll(_ scrollView: UIScrollView) {
		let hideLength: CGFloat = 150
		let originalScale = scale
		var finalScale = originalScale
		let yOffset = scrollView.bounds.origin.y + scrollView.contentInset.top
		let tooLow = yOffset < 0
		let tooHigh = scrollView.bounds.maxY > scrollView.contentSize.height - scrollView.contentInset.bottom
		let y: CGFloat? = tooLow || tooHigh ? nil : yOffset
		let useNewY = scrollView.isDragging && !scrollView.isZooming
		let newScrollPosition: CGFloat? = useNewY ? y : nil
		if let newPosition = newScrollPosition, let oldPosition = lastScrollPosition {
			let delta = oldPosition - newPosition
			let scrollUp = delta < 0
			if scrollUp == lastScrollUp {
				let allowScaling = scrollView.contentSize.height - scrollView.bounds.height > 2.5 * hideLength || scale < 1
				if allowScaling && abs(delta) < hideLength {
					let diff = delta / hideLength
					finalScale = min(1,max(0,scale + diff))
					finalScale = min(1,max(finalScale, 3 - (yOffset) / 50))
				}
				lastScrollUp = scrollUp
			} else if let _ = lastScrollUp {
				lastScrollUp = nil
			} else {
				lastScrollUp = scrollUp
			}
		}
		finalScale = min(1,max(finalScale, 1 - yOffset / 50))
		if !(originalScale == 1 && scrollView.isDecelerating && urlBar?.isEditing ?? false) {
			scale = finalScale
		}
		lastScrollPosition = newScrollPosition
	}
}

private class TabAlertTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
	static let shared = TabAlertTransitioningDelegate()

	private(set) var proxiedDelegate: UIViewControllerTransitioningDelegate?
	private(set) var waitingControllers = [TabController]()

	func notify(controller: TabController) {
		precondition(isBusy)
		precondition(Thread.isMainThread)
		waitingControllers.append(controller)
	}

	func setup(delegate: UIViewControllerTransitioningDelegate?) {
		precondition(Thread.isMainThread)
		proxiedDelegate = delegate
		isBusy = true
	}

	private(set) var isBusy = false

	func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
		return proxiedDelegate?.animationController?(forPresented: presented, presenting: presenting, source: source)
	}

	func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
		DispatchQueue.main.async {
			let oldWaiting = self.waitingControllers
			self.waitingControllers = []
			self.isBusy = false
			for controller in oldWaiting {
				controller.notifyNextUIEvent()
			}
		}
		return proxiedDelegate?.animationController?(forDismissed: dismissed)
	}
}
