import Foundation

public enum PxTransportType: String {
    case fcm
    case fcmData = "fcm.data"
    case onesignal
    case apns
}

public enum PxNotificationEvents: String {
    case clicked
    case delivered
}

public enum PxLifecycleEvents: String {
    case onscreen
    case background
    case closed
}

public enum PxSdkState: String {
    case empty        // initialize()  -> initialized
    case initialized  // activate()    -> activating -> activated
    case activating   // automatic     -> activated
    case activated    // deactivate()  -> deactivating -> deactivated || activate() -> activated
    case deactivating // automatic     -> deactivated
    case deactivated  // initialize()  -> initialized [reinit]        || activate() -> activating -> activated
}

enum PxError: Error {
    case sdkStateTransitionError(String)
}
