//
//  File.swift
//  
//

import Foundation

public enum PxTransportType: String {
    case fcm
    case fcmData = "fcm.data"
    case onesignal
    case apns
}

public enum PxEvents: String {
    case clicked
    case delivered
}

public enum PxSdkState: String {
    case empty       // initialize()  -> initialized
    case initialized // activate()    -> activating -> activated
    case activating  // automatic     -> activated
    case activated   // deactivate()  -> deactivated             || activate() -> activated
    case deactivated // initialize()  -> initialized [reinit]    || activate() -> activating -> activated
}

enum PxError: Error {
    case sdkStateTransitionError(String)
}
