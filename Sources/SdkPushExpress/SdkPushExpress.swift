// The Swift Programming Language
// https://docs.swift.org/swift-book


import Foundation
import UserNotifications
import os

public final class PushExpressManager: NSObject {
    public static let shared = PushExpressManager()
    
    internal let logger = Logger(subsystem: "com.pushexpress.sdk", category: "mainflow")
    private let pxSdkVer: String = "0.0.1"
    private let pxUrlPrefix: String = "https://core.push.express/api/r"
    
    internal var sdkState: PxSdkState = PxSdkState.empty
    private var updateInterval: TimeInterval = 120
    
    private let pxTransportType: PxTransportType = PxTransportType.apns
    private var pxAppId: String = ""
    private var pxTtToken: String = ""
    private var pxIcToken: String = ""
    private var pxIcId: String = ""
    private var pxExtId: String = ""
    
    private let preferencesPxAppIdKey: String = "px_app_id"
    private let preferencesPxTtTokenKey: String = "px_tt_token"
    private let preferencesPxIcTokenKey: String = "px_ic_token"
    private let preferencesPxIcIdKey: String = "px_ic_id"
    private let preferencesPxExtIdKey: String = "px_ext_id"
    
    public var externalId: String {
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
            self.logger.debug("Transport token was set to \(newValue)")
        }
    }
    
    public override init() {
        self.pxAppId = UserDefaults.standard.string(forKey: preferencesPxAppIdKey) ?? ""
        self.pxTtToken = UserDefaults.standard.string(forKey: preferencesPxTtTokenKey) ?? ""
        self.pxIcToken = UserDefaults.standard.string(forKey: preferencesPxIcTokenKey) ?? ""
        self.pxIcId = UserDefaults.standard.string(forKey: preferencesPxIcIdKey) ?? ""
        self.pxExtId = UserDefaults.standard.string(forKey: preferencesPxExtIdKey) ?? ""
        
        if self.pxAppId != "" && self.pxIcToken != "" {
            self.sdkState = PxSdkState.initialized
        }
    }
    
    public func initialize(appId: String, foreground: Bool = true) throws {
        try initializeIcToken(appId: appId)
        
        if foreground {
            UNUserNotificationCenter.current().delegate = PushExpressManager.shared
            
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error = error {
                    self.logger.debug("Notification request authorization failed: \(error)")
                    // TODO: send info about failed notification request
                    return
                }
                // TODO: registerForRemoteNotifications()???
            }
        }
        self.logger.debug("Initialized, notification perms requested")
    }
    
    private func isInitialized() -> Bool {
        return self.pxAppId != "" && self.pxIcToken != ""
    }
    
    private func initializeIcToken(appId: String) throws {
        let needReinitialize = self.pxAppId != "" && appId != "" && appId != self.pxAppId
        
        if (!isInitialized() || needReinitialize) {
            if ![PxSdkState.empty, PxSdkState.deactivated, PxSdkState.initialized].contains(self.sdkState) {
                self.logger.debug("Can't start initialization from \(self.sdkState.rawValue) state")
                throw PxError.sdkStateTransitionError("Can't start initialization from \(self.sdkState.rawValue) state")
            }
            
            let newIcToken = UUID().uuidString.lowercased()
            UserDefaults.standard.setValue(appId, forKey: preferencesPxAppIdKey)
            UserDefaults.standard.setValue(newIcToken, forKey: preferencesPxIcTokenKey)
            UserDefaults.standard.setValue("", forKey: preferencesPxIcIdKey)
            UserDefaults.standard.setValue("", forKey: preferencesPxExtIdKey)
            self.pxAppId = appId
            self.pxIcToken = newIcToken
            self.pxIcId = ""
            self.pxExtId = ""
            
            self.sdkState = PxSdkState.initialized
            self.logger.debug("Initialized with appId \(appId), icToken \(newIcToken), reinit \(needReinitialize)")
        } else {
            self.logger.debug("Already initialized with appId \(appId), icToken \(self.pxIcToken) and no need for reinit")
        }
    }
    
    public func activate() throws {
        if !self.isInitialized() {
            self.logger.debug("Can't activate, initialize first!")
            // throw only if not initialized, otherwise do our best silently
            throw PxError.sdkStateTransitionError("Can't activate, initialize first!")
        }
        
        if self.sdkState != PxSdkState.activated && self.sdkState != PxSdkState.activating {
            self.sdkState = PxSdkState.activating
            getOrCreateAppInstance()
        } else if self.sdkState == PxSdkState.activated {
            self.logger.debug("Already activated with appId \(self.pxAppId), extId \(self.pxExtId), icId \(self.pxIcId)")
        } else {
            self.logger.debug("Activating now with appId \(self.pxAppId), extId \(self.pxExtId) ...")
        }
    }
    
    public func deactivate() throws {
        if self.sdkState != PxSdkState.activated {
            self.logger.debug("Can't deactivate: not activated")
            throw PxError.sdkStateTransitionError("Can't deactivate: not activated")
        }
        
        // TODO: cancel updating flow on deactivate
        // TODO: call POST /deactivate
        // TODO: check deactivating state
        
        UserDefaults.standard.setValue("", forKey: preferencesPxIcIdKey)
        UserDefaults.standard.setValue("", forKey: preferencesPxExtIdKey)
        self.pxIcId = ""
        self.pxExtId = ""
        self.sdkState = PxSdkState.deactivated
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
            
            UserDefaults.standard.setValue(id, forKey: preferencesPxIcIdKey)
            self.pxIcId = id
            // TODO: thread-safety?
            self.sdkState = PxSdkState.activated
            self.logger.debug("Activated with appId \(self.pxAppId), extId \(self.pxExtId), icId \(self.pxIcId)")

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
    
    func updateAppInstance() {
        let urlSuff = "/v2/apps/\(pxAppId)/instances/\(pxIcId)/info"
        guard let url = URL(string: "\(pxUrlPrefix)\(urlSuff)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (platformType, platformVer) = getPlatformAndMajorVersion()
        let platformName = "\(platformType)_\(platformVer)"
        
        let params: [String: Any] = [
            "transport_type": self.pxTransportType.rawValue,
            "transport_token": UserDefaults.standard.string(forKey: "idOfNotificationToken") ?? "",
            "platform_type": platformType,
            "platform_name": platformName,
            "agent_name": "px_swift_sdk_\(pxSdkVer)",
            "ext_id": pxExtId,
            "lang": getSettedLanguage(),
            "county": getCountry(),
            "tz_sec": getTimeZoneOffsetInSeconds(),
            "tz_name": getTimeZoneName(),
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
    
    /*private func retryUpdateAppInstance() {
        let initialDelay = Double.random(in: 1...5)
        let maxDelay = 120.0
        var delay = initialDelay
        
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.updateAppInstance()
            delay = min(delay * 2, maxDelay)
        }
    }*/
    
    private func schedulePeriodicUpdate() {
        if self.sdkState != PxSdkState.activated {
            self.logger.debug("Deactivated, stop periodic updates")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + updateInterval) { [weak self] in
            self?.updateAppInstance()
            self?.schedulePeriodicUpdate()
        }
    }
    
    public func sendNotificationEvent(msgId: String, event: PxEvents) {
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
    
    public func sendLifecycleEvent(event: PxEvents) {
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

