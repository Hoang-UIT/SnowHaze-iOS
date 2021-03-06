//
//  SubscriptionSettingsManager.swift
//  SnowHaze
//
//
//  Copyright © 2017 Illotros GmbH. All rights reserved.
//

import Foundation
import UIKit

class SubscriptionSettingsManager: SettingsViewManager {
	private enum Mode {
		case normal
		case register
		case login
	}

	private var mode = Mode.normal

	private var shouldSetup = false
	private var normalManagerSetup = false
	private var registerManagerSetup = false
	private var loginManagerSetup = false

	override var header: SettingsDetailTableViewHeader {
		switch mode {
			case .normal:
				if normalManagerSetup{
					return normalManager.header
				}
			case .register:
				if registerManagerSetup{
					return registerManager.header
				}
			case .login:
				if loginManagerSetup{
					return loginManager.header
				}
		}
		return super.header
	}

	private var manager: SettingsViewManager {
		switch mode {
			case .normal:
				if !normalManagerSetup && shouldSetup {
					normalManager.setup()
					normalManagerSetup = true
				}
				return normalManager
			case .register:
				if !registerManagerSetup && shouldSetup {
					registerManager.setup()
					registerManagerSetup = true
				}
				return registerManager
			case .login:
				if !loginManagerSetup && shouldSetup {
					loginManager.setup()
					loginManagerSetup = true
				}
				return loginManager
		}
	}

	func isActive(_ query: SettingsViewManager) -> Bool {
		return manager == query
	}

	private lazy var normalManager: DefaultSubscriptionSettingsManager = {
		DefaultSubscriptionSettingsManager(parent: self)
	}()

	private lazy var registerManager: RegisterSubscriptionSettingsManager = {
		RegisterSubscriptionSettingsManager(parent: self)
	}()

	private lazy var loginManager: LoginSubscriptionSettingsManager = {
		LoginSubscriptionSettingsManager(parent: self)
	}()

	override func setup() {
		super.setup()
		shouldSetup = true
		assert(manager == normalManager)
		if !normalManagerSetup {
			normalManager.setup()
			normalManagerSetup = true
		}
	}

	override func html() -> String {
		return manager.html()
	}

	override var assessmentResultColor: UIColor {
		return PolicyAssessor(wrapper: settings).assess([.subscription]).color
	}

	override func updateHeaderColor(animated: Bool) {
		manager.updateHeaderColor(animated: animated)
	}

	override var numberOfSections: Int {
		return manager.numberOfSections
	}

	override func heightForRow(atIndexPath indexPath: IndexPath) -> CGFloat {
		return manager.heightForRow(atIndexPath: indexPath)
	}

	override func numberOfRows(inSection section: Int) -> Int {
		return manager.numberOfRows(inSection: section)
	}

	override func titleForHeader(inSection section: Int) -> String? {
		return manager.titleForHeader(inSection: section)
	}

	override func titleForFooter(inSection section: Int) -> String? {
		return manager.titleForFooter(inSection: section)
	}

	override func heightForFooter(inSection section: Int) -> CGFloat {
		return manager.heightForFooter(inSection: section)
	}

	override func cellForRow(atIndexPath indexPath: IndexPath, tableView: UITableView) -> UITableViewCell {
		return manager.cellForRow(atIndexPath: indexPath, tableView: tableView)
	}

	override func viewForHeader(inSection section: Int) -> UIView? {
		return manager.viewForHeader(inSection: section)
	}

	override func didSelectRow(atIndexPath indexPath: IndexPath, tableView: UITableView) {
		return manager.didSelectRow(atIndexPath: indexPath, tableView: tableView)
	}

	private func reloadData(with animation: UITableView.RowAnimation, change: () -> ()) {
		guard let tableView = self.controller?.tableView else {
			return
		}
		let oldSectionCount = manager.numberOfSections
		change()
		let newSectionCount = manager.numberOfSections
		let reloadSectionCount = min(newSectionCount, oldSectionCount)
		let reloadSections = IndexSet(integersIn: 0 ..< reloadSectionCount)
		let maxSectionCount = max(newSectionCount, oldSectionCount)
		let otherSections = IndexSet(integersIn: reloadSectionCount ..< maxSectionCount)
		tableView.beginUpdates()
		if newSectionCount > oldSectionCount {
			tableView.insertSections(otherSections, with: animation)
		} else if oldSectionCount > newSectionCount {
			tableView.deleteSections(otherSections, with: animation)
		}
		tableView.reloadSections(reloadSections, with: animation)
		tableView.endUpdates()
	}

	func switchToLogin() {
		if case .login = mode {
			return
		}
		reloadData(with: .fade) {
			if case .normal = mode {
				rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
			}
			mode = .login
		}
	}

	func switchToRegister() {
		guard case .normal = mode else {
			return
		}
		reloadData(with: .fade) {
			mode = .register
			rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
		}
	}

	func switchToNormal() {
		if case .normal = mode {
			return
		}
		reloadData(with: .fade) {
			mode = .normal
			rightBarButtonItem = nil
		}
	}

	@objc private func cancel() {
		switchToNormal()
	}

	class func canShow(_ error: V3APIConnection.Error) -> Bool {
		switch error {
			case .network:			return true
			case .noSuchAccount:	return true
			case .emailInUse:		return true
			default: 				return false
		}
	}

	class func show(error: V3APIConnection.Error, in hostVC: UIViewController) {
		let type: AlertType
		switch error {
			case .network:				type = .subscriptionNetworkError
			case .noSuchAccount:		type = .subscriptionNoSuchAccountError
			case .emailInUse:			type = .subscriptionEmailInUseError
			case .clearMasterSecret:	type = .subscriptionLogout
			default:					fatalError("no error message for error \(error) implemented")
		}
		hostVC.present(type.build(), animated: true, completion: nil)
	}
}
