//
//  LSRouterControlCenter.swift
//  TUILiveKit
//
//  Created by jeremiawang on 2024/11/20.
//

import Combine
import TUICore
import RTCCommon
import RTCRoomEngine
import LiveStreamCore
import TUILiveComponent

class LSRouterControlCenter {
    private var coreView: LiveCoreView?
    private var rootRoute: LSRoute
    private var routerManager: LSRouterManager
    private var manager: LiveStreamManager?
    
    private weak var rootViewController: UIViewController?
    private var cancellableSet = Set<AnyCancellable>()
    private var presentedRouteStack: [LSRoute] = []
    private var presentedViewControllerMap: [LSRoute: UIViewController] = [:]

    init(rootViewController: UIViewController, rootRoute: LSRoute, routerManager: LSRouterManager, manager: LiveStreamManager? = nil, coreView: LiveCoreView? = nil) {
        self.rootViewController = rootViewController
        self.rootRoute = rootRoute
        self.routerManager = routerManager
        self.manager = manager
        self.coreView = coreView
        routerManager.setRootRoute(route: rootRoute)
    }
    
    func handleScrollToNewRoom(manager: LiveStreamManager, coreView: LiveCoreView) {
        self.manager = manager
        self.coreView = coreView
        self.presentedViewControllerMap.removeAll()
    }
    
    deinit {
        print("deinit \(type(of: self))")
    }
}

// MARK: - Subscription
extension LSRouterControlCenter {
    func subscribeRouter() {
        routerManager.subscribeRouterState(StateSelector(keyPath: \LSRouterState.routeStack))
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] routeStack in
                guard let self = self else { return }
                self.comparePresentedVCWith(routeStack: routeStack)
            }
            .store(in: &cancellableSet)
    }
}

// MARK: - Route Handler
extension LSRouterControlCenter {
    private func comparePresentedVCWith(routeStack: [LSRoute]) {
        if routeStack.isEmpty {
            handleExitAction()
            return
        }
        
        if routeStack.count > presentedRouteStack.count + 1 {
            if let lastRoute = routeStack.last {
                handleRouteAction(route: lastRoute)
            }
            return
        }
        
        handleDismisAndRouteToAction(routeStack: routeStack)
    }
    
    private func handleExitAction() {
        presentedRouteStack.removeAll()
        presentedViewControllerMap.removeAll()
        exitLiveKit()
    }
    
    private func exitLiveKit() {
        if let navigationController = rootViewController?.navigationController {
            navigationController.popViewController(animated: true)
        } else {
            rootViewController?.dismiss(animated: true)
        }
    }
    
    private func handleRouteAction(route: LSRoute) {
        if route == rootRoute {
            rootViewController?.presentedViewController?.dismiss(animated: true)
        }
        
        if tryToPresentCachedViewController(route: route) {
            return
        }
                
        if let view = getRouteDefaultView(route: route) {
            var presentedViewController: UIViewController = UIViewController()
            switch route {
            case .alert(_):
                presentedViewController = presentAlert(alertView: view)
            default:
                presentedViewController = presentPopup(view: view, route: route)
            }
            presentedRouteStack.append(route)
            presentedViewControllerMap[route] = presentedViewController
        } else {
            routerManager.router(action: .dismiss())
        }
    }
    
    private func tryToPresentCachedViewController(route: LSRoute) -> Bool {
        var isSuccess = false
        if presentedViewControllerMap.keys.contains(route) {
            if let rootViewController = rootViewController,
               let presentedController = presentedViewControllerMap[route] {
                let presentingViewController = getPresentingViewController(rootViewController)
                presentingViewController.present(presentedController, animated: supportAnimation(route: route))
                presentedRouteStack.append(route)
                isSuccess = true
            }
        }
        return isSuccess
    }
    
    private func handleDismisAndRouteToAction(routeStack: [LSRoute]) {
        while routeStack.last != presentedRouteStack.last {
            if presentedRouteStack.isEmpty {
                break
            }
            
            if let route = presentedRouteStack.popLast(), let vc = presentedViewControllerMap[route] {
                if let dismissEvent = routerManager.routerState.dismissEvent {
                    vc.dismiss(animated: supportAnimation(route: route)) { [weak self] in
                        guard let self = self else { return }
                        dismissEvent()
                        self.routerManager.clearDismissEvent()
                    }
                } else {
                    vc.dismiss(animated: supportAnimation(route: route))
                }
                if isTempPanel(route: route) {
                    presentedViewControllerMap[route] = nil
                }
            }
        }
    }
}

// MARK: - Presenting ViewController
extension LSRouterControlCenter {
    private func getPresentingViewController(_ rootViewController: UIViewController) -> UIViewController {
        if let vc = rootViewController.presentedViewController {
            return getPresentingViewController(vc)
        } else {
            return rootViewController
        }
    }
}

// MARK: - Default Route View
extension LSRouterControlCenter {
    private func getRouteDefaultView(route: LSRoute) -> UIView? {
        guard let coreView = coreView, let manager = manager else { return nil }
        var view: UIView?
        switch route {
        case .liveLinkControl:
            view = AnchorLinkControlPanel(manager: manager, routerManager: routerManager, coreView: coreView)
        case .connectionControl:
            view = LSCoHostManagerPanel(manager: manager.coHostManager, coreView: coreView)
        case .featureSetting(let settingPanelModel):
            view = LSSettingPanel(settingPanelModel: settingPanelModel)
        case .audioEffect:
            let audioEffect = AudioEffectView()
            audioEffect.backButtonClickClosure = { [weak self] _ in
                guard let self = self else { return }
                self.routerManager.router(action: .dismiss())
            }
            view = audioEffect
        case .linkType(let data):
            view = LinkMicTypePanel(data: data, routerManager: routerManager, manager: manager)
        case .listMenu(let data):
            let actionPanel = ActionPanel(panelData: data)
            actionPanel.cancelActionClosure = { [weak self] in
                guard let self = self else { return }
                self.routerManager.router(action: .dismiss())
            }
            view = actionPanel
        case .linkSetting:
            view = VideoLinkSettingPanel(manager: manager, routerManager: routerManager, coreView: coreView)
        case .battleCountdown(let countdownTime):
            let countdownView = LSBattleCountDownView(countdownTime: countdownTime, manager: manager.battleManager, coreView: coreView)
            countdownView.timeEndClosure = { [weak self] in
                guard let self = self else { return }
                self.routerManager.router(action: .dismiss())
            }
            countdownView.cancelClosure = { [weak self] in
                guard let self = self else { return }
                self.routerManager.router(action: .dismiss())
            }
            view = countdownView
        case .alert(let info):
            view = LSAlertPanel(alertInfo: info)
        case .streamDashboard:
            view = StreamDashboardPanel(roomId: manager.roomState.roomId,
                                        trtcCloud: TUIRoomEngine.sharedInstance().getTRTCCloud())
        case .beauty:
            if BeautyView.checkIsNeedDownloadResource() {
                return nil
            }
            let beautyView = BeautyView.shared()
            beautyView.backClosure = { [weak self] in
                guard let self = self else { return }
                routerManager.router(action: .dismiss())
            }
            view = beautyView
        case .giftView:
            let giftPanel = GiftListPanel(roomId: manager.roomState.roomId, provider: manager)
            giftPanel.setGiftList(TUIGiftStore.shared.giftList)
            view = giftPanel
        case .userManagement(let user, let type):
            if type == .userInfo {
                view = UserInfoPanelView(user: user, manager: manager)
            } else {
                view = UserManagePanelView(user: user, manager: manager, routerManager: routerManager, coreView: coreView, type: type)
            }
        default:
            break
        }
        return view
    }
}

// MARK: - Route Staus
extension LSRouterControlCenter {
    private func isTempPanel(route: LSRoute) -> Bool {
        switch route {
        case .battleCountdown(_),
                .alert(_),
                .streamDashboard,
                .featureSetting(_),
                .userManagement(_, _):
            return true
        default:
            return false
        }
    }
    
    private func supportBlurView(route: LSRoute) -> Bool {
        switch route {
        case .beauty, .battleCountdown(_),
                .featureSetting(_), .alert(_),
                .streamDashboard,
                .giftView,
                .listMenu(_),
                .userManagement(_, _):
            return false
        default:
            return true
        }
    }
    
    private func supportAnimation(route: LSRoute) -> Bool{
        switch route {
        case .alert(_):
            return false
        default:
            return true
        }
    }
    
    private func getSafeBottomViewBackgroundColor(route: LSRoute) -> UIColor {
        var safeBottomViewBackgroundColor = UIColor.g2
        switch route {
        case .listMenu(_):
            safeBottomViewBackgroundColor = .white
        case .battleCountdown(_):
            safeBottomViewBackgroundColor = .clear
        case .streamDashboard, .featureSetting(_), .giftView, .beauty:
            safeBottomViewBackgroundColor = .bgOperateColor
        default:
            break
        }
        return safeBottomViewBackgroundColor
    }
}

// MARK: - Popup
extension LSRouterControlCenter {
    private func presentPopup(view: UIView, route: LSRoute) -> UIViewController {
        let safeBottomViewBackgroundColor = getSafeBottomViewBackgroundColor(route: route)
        let menuContainerView = MenuContainerView(contentView: view, safeBottomViewBackgroundColor: safeBottomViewBackgroundColor)
        let popupViewController = PopupViewController(contentView: menuContainerView,
                                                  supportBlurView: supportBlurView(route: route))
        menuContainerView.blackAreaClickClosure = { [weak self] in
            guard let self = self else { return }
            self.routerManager.router(action: .dismiss())
        }
        guard let rootViewController = rootViewController else { return UIViewController()}
        let presentingViewController = getPresentingViewController(rootViewController)
        presentingViewController.present(popupViewController, animated: true)
        return popupViewController
    }
}

// MARK: - Alert
extension LSRouterControlCenter {
    private func presentAlert(alertView: UIView) -> UIViewController {
        let alertContainerView = LSAlertContainerView(contentView: alertView)
        let alerViewController = PopupViewController(contentView: alertContainerView,
                                                 supportBlurView: false)
        guard let rootViewController = rootViewController else { return UIViewController()}
        let presentingViewController = getPresentingViewController(rootViewController)
        presentingViewController.present(alerViewController, animated: false)
        
        return alerViewController
    }
}


