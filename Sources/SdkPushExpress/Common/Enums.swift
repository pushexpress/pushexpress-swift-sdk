//
//  File.swift
//  
//

import Foundation

public enum TransportType: String {
    case fcm
    case fcmData = "fcm.data"
    case onesignal
    case apns
}

public enum Events: String {
    case clicked
    case delivered
}

