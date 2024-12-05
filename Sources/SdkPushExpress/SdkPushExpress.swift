import Foundation
import UserNotifications
import os
import UIKit

public final class PushExpressManager: NSObject {
    public static let shared = PushExpressManager()
    
    internal let logger = Logger(subsystem: "com.pushexpress.sdk", category: "mainflow")
    private let pxSdkVer: String = "1.1.2"
    private let pxUrlPrefix: String = "https://core.push.express/api/r"
    private let pxTagsMaxKeys: Int = 64
    
    internal var sdkState: PxSdkState = .empty
    private var updateInterval: TimeInterval = 120
    
    private var lastAppState: UIApplication.State = UIApplication.State.inactive
    private var currAppState: UIApplication.State = UIApplication.State.inactive
    
    private let pxTransportType: PxTransportType = .apns
    private var pxAppId: String = ""
    private var pxTtToken: String = ""
    private var pxIcToken: String = ""
    private var pxIcId: String = ""
    private var pxExtId: String = ""
    private var pxOnscreenCount: Int = 0
    private var pxOnscreenSec: Int = 0
    private var pxOnscreenStartTs: Int = 0
    private var pxOnscreenStopTs: Int = 0
    
    private let preferencesPxAppIdKey: String = "px_app_id"
    private let preferencesPxTtTokenKey: String = "px_tt_token"
    private let preferencesPxIcTokenKey: String = "px_ic_token"
    private let preferencesPxIcIdKey: String = "px_ic_id"
    private let preferencesPxExtIdKey: String = "px_ext_id"
    private let preferencesPxOnscreenCount: String = "px_onscreen_count"
    private let preferencesPxOnscreenSec: String = "px_onscreen_sec"
    private let preferencesPxOnscreenStartTs: String = "px_onscreen_start_ts"
    private let preferencesPxOnscreenStopTs: String = "px_onscreen_stop_ts"
    
    private var pxTags: [String: String] = [:]
    
    public private(set) var notificationsPermissionGranted: Bool = false
    public var foregroundNotifications: Bool = true
    
    private var appInstanceId: String {
        get { return pxIcId }
        set {
            UserDefaults.standard.setValue(newValue, forKey: preferencesPxIcIdKey)
            self.pxIcId = newValue
        }
    }
    
    public private(set) var externalId: String {
        get { return pxExtId }
        set {
            UserDefaults.standard.setValue(newValue, forKey: preferencesPxExtIdKey)
            self.pxExtId = newValue
            self.logger.debug("External ID was set to \(newValue)")
        }
    }
    
    public var transportToken: String {
        get { return pxTtToken }
        set {
            UserDefaults.standard.setValue(newValue, forKey: preferencesPxTtTokenKey)
            pxTtToken = newValue
            updateAppInstance()
            self.logger.debug("Transport token was set to \(newValue)")
        }
    }
    
    public var tags: [String: String] {
        get { return self.pxTags }
        set {
            if newValue.count > pxTagsMaxKeys {
                self.logger.error("Too much tags, only first \(self.pxTagsMaxKeys) will be kept")
                let sortedKeys = newValue.keys.sorted().prefix(pxTagsMaxKeys)
                var truncatedMap = [String: String]()
                for key in sortedKeys {
                    truncatedMap[key] = newValue[key]
                }
                self.pxTags = truncatedMap
            } else {
                self.pxTags = newValue
            }
        }
    }
    
    public override init() {
        self.pxAppId = UserDefaults.standard.string(forKey: preferencesPxAppIdKey) ?? ""
        self.pxTtToken = UserDefaults.standard.string(forKey: preferencesPxTtTokenKey) ?? ""
        self.pxIcToken = UserDefaults.standard.string(forKey: preferencesPxIcTokenKey) ?? ""
        self.pxIcId = UserDefaults.standard.string(forKey: preferencesPxIcIdKey) ?? ""
        self.pxExtId = UserDefaults.standard.string(forKey: preferencesPxExtIdKey) ?? ""
        self.pxOnscreenCount = max(UserDefaults.standard.integer(forKey: preferencesPxOnscreenCount) ?? 0, 0)
        self.pxOnscreenSec = max(UserDefaults.standard.integer(forKey: preferencesPxOnscreenSec) ?? 0, 0)
        
        let nowTs = Int(Date().timeIntervalSince1970)
        self.pxOnscreenStartTs = min(nowTs, max(UserDefaults.standard.integer(forKey: preferencesPxOnscreenStartTs) ?? 0, 0))
        self.pxOnscreenStopTs = min(nowTs, max(UserDefaults.standard.integer(forKey: preferencesPxOnscreenStopTs) ?? 0, 0))
        self.pxOnscreenStartTs = self.pxOnscreenStartTs == 0 ? nowTs : self.pxOnscreenStartTs
        self.pxOnscreenStopTs = self.pxOnscreenStopTs == 0 ? nowTs : self.pxOnscreenStopTs
        
        if self.pxAppId != "" && self.pxIcToken != "" {
            self.sdkState = .initialized
        }
        
        super.init()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lifecycleNotificationReceiver),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lifecycleNotificationReceiver),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lifecycleNotificationReceiver),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    @objc func lifecycleNotificationReceiver(notification: NSNotification) {
        self.logger.debug("Lifecycle notification received: \(notification.name.rawValue)")
        self.lastAppState = self.currAppState
        
        if notification.name == UIApplication.didBecomeActiveNotification {
            self.currAppState = UIApplication.State.active
            self.sendLifecycleEvent(event: .onscreen)
        }
        else if notification.name == UIApplication.didEnterBackgroundNotification {
            self.currAppState = UIApplication.State.background
            self.sendLifecycleEvent(event: .background)
        }
        else if notification.name == UIApplication.willTerminateNotification {
            self.currAppState = UIApplication.State.inactive
            self.sendLifecycleEvent(event: .closed)
        }
        
        if calcAndUpdateOnscreenData() {
            updateAppInstance()
        }
    }
    
    private func calcAndUpdateOnscreenData() -> Bool {
        var logMsg = "Trying to update onscreen data: lastAppState \(self.lastAppState.rawValue), " +
        "currAppState \(self.currAppState.rawValue), onscreenCount \(self.pxOnscreenCount), " +
        "onscreenSec \(self.pxOnscreenSec), onscreenStartTime \(self.pxOnscreenStartTs), " +
        "onscreenStopTime \(self.pxOnscreenStopTs)"
        self.logger.debug("\(logMsg)")
        
        var updated = false
        if self.currAppState == UIApplication.State.active {
            if self.lastAppState != self.currAppState {
                self.pxOnscreenCount += 1
                self.pxOnscreenStartTs = Int(Date().timeIntervalSince1970)
                self.lastAppState = self.currAppState
                updated = true
            } else {
                let currActiveTs = Int(Date().timeIntervalSince1970)
                if currActiveTs > 0 && self.pxOnscreenStartTs > 0 && currActiveTs >= self.pxOnscreenStartTs {
                    self.pxOnscreenSec += Int(currActiveTs - self.pxOnscreenStartTs)
                    self.pxOnscreenStartTs = currActiveTs
                    updated = true
                } else {
                    self.logger.error("Something wrong with lifecycle and timestamps, see logs above")
                }
            }
        }
        else if self.lastAppState == UIApplication.State.active {
            self.pxOnscreenStopTs = Int(Date().timeIntervalSince1970)
            if self.pxOnscreenStopTs > 0 && self.pxOnscreenStartTs > 0 && self.pxOnscreenStopTs >= self.pxOnscreenStartTs {
                self.pxOnscreenSec += Int(self.pxOnscreenStopTs - self.pxOnscreenStartTs)
                updated = true
            } else {
                self.logger.error("Something wrong with lifecycle and timestamps, see logs above")
            }
            self.lastAppState = self.currAppState
        }
        
        if updated {
            UserDefaults.standard.setValue(self.pxOnscreenCount, forKey: preferencesPxOnscreenCount)
            UserDefaults.standard.setValue(self.pxOnscreenSec, forKey: preferencesPxOnscreenSec)
            
            logMsg = "Updated onscreen data: lastAppState \(self.lastAppState.rawValue), " +
            "currAppState \(self.currAppState.rawValue), onscreenCount \(self.pxOnscreenCount), " +
            "onscreenSec \(self.pxOnscreenSec), onscreenStartTime \(self.pxOnscreenStartTs), " +
            "onscreenStopTime \(self.pxOnscreenStopTs)"
            self.logger.debug("\(logMsg)")
        }
        
        return updated
    }
    
    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    public func requestNotificationsPermission(registerForRemoteNotifications: Bool = true) {
        let application = UIApplication.shared
        // Check if the device supports push notifications
        if application.isRegisteredForRemoteNotifications {
            self.logger.debug("Notifications permission already granted, register APNS")
            self.notificationsPermissionGranted = true
            if registerForRemoteNotifications {
                application.registerForRemoteNotifications()
            }
        } else {
            let notificationSettings = UNUserNotificationCenter.current()
            notificationSettings.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if granted {
                    self.logger.debug("Notifications permission just granted, register APNS")
                    self.notificationsPermissionGranted = true
                    if registerForRemoteNotifications {
                        DispatchQueue.main.async {
                            application.registerForRemoteNotifications()
                        }
                    }
                } else {
                    self.logger.debug("Notifications permission request failed: \(error)")
                }
            }
        }
    }
    
    public func initialize(appId: String) throws {
        try initializeIcToken(appId: appId)
        
        UNUserNotificationCenter.current().delegate = PushExpressManager.shared
        
        requestNotificationsPermission(registerForRemoteNotifications: true)
        self.logger.debug("Initialization finished")
    }
    
    public func initialize(appId: String, essentialsOnly: Bool) throws {
        try initializeIcToken(appId: appId)
        
        UNUserNotificationCenter.current().delegate = PushExpressManager.shared
        
        if !essentialsOnly {
            requestNotificationsPermission(registerForRemoteNotifications: true)
        }
        self.logger.debug("Initialization finished")
    }
    
    private func isInitialized() -> Bool {
        return self.pxAppId != "" && self.pxIcToken != ""
    }
    
    private func initializeIcToken(appId: String) throws {
        let needReinitialize = self.pxAppId != "" && appId != "" && appId != self.pxAppId
        
        if (!isInitialized() || needReinitialize) {
            if sdkState != .empty && sdkState != .deactivated && sdkState != .initialized {
                self.logger.error("Can't start initialization from \(self.sdkState.rawValue) state")
                throw PxError.sdkStateTransitionError("Can't start initialization from \(self.sdkState.rawValue) state")
            }
            
            let newIcToken = UUID().uuidString.lowercased()
            UserDefaults.standard.setValue(appId, forKey: preferencesPxAppIdKey)
            UserDefaults.standard.setValue(newIcToken, forKey: preferencesPxIcTokenKey)
            self.pxAppId = appId
            self.pxIcToken = newIcToken
            self.appInstanceId = ""
            self.externalId = ""
            
            self.sdkState = .initialized
            self.logger.debug("Initialized with appId \(appId), icToken \(newIcToken), reinit \(needReinitialize)")
        } else {
            // Do not set sdkState to .initialized here! It can be in any state, not only .empty/.deactivated
            // Just log and return =)
            self.logger.debug("Already initialized with appId \(appId), icToken \(self.pxIcToken) and no need for reinit")
        }
    }
    
    public func activate(extId: String = "", force: Bool = false) throws {
        if self.sdkState == .initialized || self.sdkState == .deactivated {
            self.sdkState = .activating
            
            if !force && self.appInstanceId != "" && self.externalId == extId {
                self.logger.debug("No activation needed, use cached icId \(self.pxIcId) with appId \(self.pxAppId), extId \(self.pxExtId), icToken \(self.pxIcToken)")
                
                self.sdkState = .activated
                self.updateAppInstance()
                self.schedulePeriodicUpdate()
                self.logger.debug("Update flow scheduled")
                return
            }
            
            // externalId can be set only on activating, because it's part of session key
            self.externalId = extId
            getOrCreateAppInstance()
        } else if self.sdkState == .activated {
            self.logger.debug("Already activated icId \(self.pxIcId) with appId \(self.pxAppId), extId \(self.pxExtId), icToken \(self.pxIcToken)")
        } else if self.sdkState == .activating {
            self.logger.debug("Activating now appId \(self.pxAppId), extId \(self.pxExtId), icToken \(self.pxIcToken) ...")
        } else {
            self.logger.error("Can't start activation from \(self.sdkState.rawValue) state!")
            throw PxError.sdkStateTransitionError("Can't start activation from \(self.sdkState.rawValue) state!")
        }
    }
    
    public func deactivate() throws {
        if self.sdkState == .activated {
            self.sdkState = .deactivating
            
            deactivateAppInstance()
        } else if self.sdkState == .deactivated {
            self.logger.debug("Already deactivated appId \(self.pxAppId), extId \(self.pxExtId), icToken \(self.pxIcToken)")
        } else if self.sdkState == .deactivating {
            self.logger.debug("Deactivating now icId \(self.pxIcId) with appId \(self.pxAppId), extId \(self.pxExtId), icToken \(self.pxIcToken) ...")
        } else {
            self.logger.error("Can't start deactivation from \(self.sdkState.rawValue) state!")
            throw PxError.sdkStateTransitionError("Can't start deactivation from \(self.sdkState.rawValue) state!")
        }
    }
    
    private func getOrCreateAppInstance() {
        let urlSuff = "/v2/apps/\(pxAppId)/instances"
        guard let url = URL(string: "\(pxUrlPrefix)\(urlSuff)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let params: [String: String] = [
            "ic_token": self.pxIcToken,
            "ext_id": self.pxExtId,
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: params, options: [])
        self.logger.debug("Preparing \(String(request.httpMethod ?? "")) \(urlSuff): \(params)")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if error != nil {
                self.logger.error("\(String(request.httpMethod ?? "")) \(urlSuff) failed: \(error)")
                self.retryCreateAppInstance()
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let jsonDict = json as? [String: Any],
                  let id = jsonDict["id"] as? String else {
                self.logger.error("Failed to parse data from \(urlSuff): \(data?.base64EncodedString() ?? "")")
                self.retryCreateAppInstance()
                return
            }
            
            self.appInstanceId = id
            // TODO: thread-safety?
            self.sdkState = .activated
            self.logger.debug("Activated icId \(self.pxIcId) with appId \(self.pxAppId), extId \(self.pxExtId), icToken \(self.pxIcToken)")
            
            self.updateAppInstance()
            self.schedulePeriodicUpdate()
            self.logger.debug("Update flow scheduled")
        }
        
        task.resume()
    }
    
    private func retryCreateAppInstance() {
        let initialDelay = Double.random(in: 1...5)
        let maxDelay = 120.0
        var delay = initialDelay
        
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.getOrCreateAppInstance()
            delay = min(delay * 2, maxDelay)
        }
    }
    
    private func deactivateAppInstance() {
        let urlSuff = "/v2/apps/\(pxAppId)/instances/\(pxIcId)/deactivate"
        guard let url = URL(string: "\(pxUrlPrefix)\(urlSuff)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let params: [String: String] = [
            "ic_token": self.pxIcToken,
            "ext_id": self.pxExtId,
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: params, options: [])
        self.logger.debug("Preparing \(String(request.httpMethod ?? "")) \(urlSuff): \(params)")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if error != nil {
                self.logger.error("\(String(request.httpMethod ?? "")) \(urlSuff) failed: \(error)")
                self.retryDeactivateAppInstance()
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let jsonDict = json as? [String: Any],
                  let id = jsonDict["id"] as? String else {
                self.logger.error("Failed to parse data from \(urlSuff): \(data?.base64EncodedString() ?? "")")
                self.retryDeactivateAppInstance()
                return
            }

            self.appInstanceId = ""
            self.externalId = ""
            self.sdkState = .deactivated
        }
        
        self.logger.debug("Deactivated icId \(self.pxIcId) with appId \(self.pxAppId), extId \(self.pxExtId), icToken \(self.pxIcToken)")
        task.resume()
    }
    
    private func retryDeactivateAppInstance() {
        let initialDelay = Double.random(in: 1...5)
        let maxDelay = 120.0
        var delay = initialDelay
        
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.deactivateAppInstance()
            delay = min(delay * 2, maxDelay)
        }
    }
    
    private func updateAppInstance() {
        if self.sdkState != .activated {
            self.logger.debug("Can't update AppInstance data, not activated!")
            return
        }
        
        let urlSuff = "/v2/apps/\(pxAppId)/instances/\(pxIcId)/info"
        guard let url = URL(string: "\(pxUrlPrefix)\(urlSuff)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (platformType, platformVer) = getPlatformAndMajorVersion()
        let platformName = "\(platformType)_\(platformVer)"
        
        let params: [String: Any] = [
            "transport_type": self.pxTransportType.rawValue,
            "transport_token": self.transportToken,
            "platform_type": platformType,
            "platform_name": platformName,
            "agent_name": "px_swift_sdk_\(pxSdkVer)",
            "lang": getSettedLanguage(),
            "county": getCountry(),
            "tz_sec": getTimeZoneOffsetInSeconds(),
            "tz_name": getTimeZoneName(),
            "onscreen_count": self.pxOnscreenCount,
            "onscreen_sec": self.pxOnscreenSec,
            "tags": self.pxTags,
            "notif_perm_granted": self.notificationsPermissionGranted,
            "onscreen_start_ts": Int(self.pxOnscreenStartTs),
            "onscreen_stop_ts": Int(self.pxOnscreenStopTs),
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: params, options: [])
        self.logger.debug("Preparing \(String(request.httpMethod ?? "")) \(urlSuff): \(params)")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if error != nil {
                self.logger.error("\(String(request.httpMethod ?? "")) \(urlSuff) failed: \(error)")
                // Do not retry updates, to simplify logic with schedulePeriodicUpdates (just try to update in fixed intervals)
                // self.retryUpdateAppInstance()
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let jsonDict = json as? [String: Any],
                  let updateInterval = jsonDict["update_interval_sec"] as? TimeInterval else {
                self.logger.error("Failed to parse data from \(urlSuff): \(data?.base64EncodedString() ?? "")")
                // self.retryUpdateAppInstance()
                return
            }
            
            self.updateInterval = updateInterval
            self.logger.debug("AppInstance updated")
        }
        
        task.resume()
    }
    
    private func schedulePeriodicUpdate() {
        if self.sdkState != .activated {
            self.logger.debug("Not activated any more, stop periodic updates")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + updateInterval) { [weak self] in
            self?.calcAndUpdateOnscreenData()
            self?.updateAppInstance()
            self?.schedulePeriodicUpdate()
        }
    }
    
    internal func sendNotificationEvent(msgId: String, event: PxNotificationEvents) {
        if self.sdkState != .activated {
            self.logger.debug("Can't send \(event.rawValue) event, not activated")
            return
        }

        let urlSuff = "/v2/apps/\(pxAppId)/instances/\(pxIcId)/events/notification"
        guard let url = URL(string: "\(pxUrlPrefix)\(urlSuff)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let params: [String: String] = [
            "msg_id": msgId,
            "event": event.rawValue
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: params, options: [])
        self.logger.debug("Preparing \(String(request.httpMethod ?? "")) \(urlSuff): \(params)")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.logger.error("\(String(request.httpMethod ?? "")) \(urlSuff) failed: \(error)")
            }
        }
        
        self.logger.debug("Notification event \(event.rawValue) sended for msgId \(msgId)")
        task.resume()
    }
    
    internal func sendLifecycleEvent(event: PxLifecycleEvents) {
        if self.sdkState != .activated {
            self.logger.debug("Can't send \(event.rawValue) event, not activated")
            return
        }

        let urlSuff = "/v2/apps/\(pxAppId)/instances/\(pxIcId)/events/lifecycle"
        guard let url = URL(string: "\(pxUrlPrefix)\(urlSuff)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let params: [String: String] = [
            "event": event.rawValue
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: params, options: [])
        self.logger.debug("Preparing \(String(request.httpMethod ?? "")) \(urlSuff): \(params)")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.logger.error("\(String(request.httpMethod ?? "")) \(urlSuff) failed: \(error)")
            }
        }
        
        self.logger.debug("Lifecycle event \(event.rawValue) sended")
        task.resume()
    }
    
    // Helper Functions
    
    private func getTimeZoneOffsetInSeconds() -> Int {
        return TimeZone.current.secondsFromGMT()
    }
    
    private func getTimeZoneName() -> String {
        return TimeZone.current.identifier
    }
    
    private func getSettedLanguage() -> String {
        var locale = Locale.preferredLanguages.first ?? ""
        return locale
    }
    
    private func getCountry() -> String {
        var countryCode = ""
        if #available(iOS 16, *) {
            countryCode = Locale.current.region?.identifier ?? ""
        } else {
            countryCode = Locale.current.regionCode ?? ""
        }
        return countryCode
    }
    
    private func getPlatformAndMajorVersion() -> (platform: String, majorVersion: String) {
        var platform = ""
        var majorVersion = ""

        #if os(iOS)
        platform = "ios"
        #elseif os(macOS)
        platform = "macos"
        #elseif os(tvOS)
        platform = "tvos"
        #elseif os(watchOS)
        platform = "watchos"
        #else
        platform = "unknown"
        #endif

        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.majorVersion != -1 { // If majorVersion is -1, it means the version is not available
            majorVersion = "\(os.majorVersion)"
        } else {
            majorVersion = "0"
        }

        return (platform, majorVersion)
    }
}
