import Foundation
import UserNotifications
import os

public class NotificationManager {
    internal let logger = Logger(subsystem: "com.pushexpress.sdk", category: "bg.notification")
    
    public init() {}
    
    public func handleNotification(request: UNNotificationRequest, contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.logger.debug("Handling background notification")
        guard let content = (request.content.mutableCopy() as? UNMutableNotificationContent) else {
            return contentHandler(request.content)
        }
        
        guard let userInfo = content.userInfo as? [String: Any],
              let msgId = userInfo["px.msg_id"] as? String,
              let title = userInfo["px.title"] as? String,
              let body = userInfo["px.body"] as? String else {
            self.logger.debug("Unknown background notification, just try to display it")
            return contentHandler(request.content)
        }
        
        self.logger.debug("Received background PX notification")
        content.title = title
        content.body = body
        
        PushExpressManager.shared.sendNotificationEvent(msgId: msgId, event: .delivered)

        if let imageUrlString = userInfo["px.image"] as? String,
           let imageUrl = URL(string: imageUrlString) {
            downloadImage(atURL: imageUrl) { attachment, error in
                if let error = error {
                    self.logger.error("Failed to download image: \(error)")
                } else if let attachment = attachment {
                    content.attachments = [attachment]
                }
                contentHandler(content.copy() as! UNNotificationContent)
            }
        } else {
            contentHandler(content.copy() as! UNNotificationContent)
        }
    }
    
    public func downloadImage(atURL url: URL, completion: @escaping (UNNotificationAttachment?, Error?) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            guard let location = location, error == nil else {
                completion(nil, error)
                return
            }
            
            let fileManager = FileManager.default
            let tmpDirectory = NSTemporaryDirectory()
            let uniqueString = ProcessInfo.processInfo.globallyUniqueString
            let tmpFileURL = URL(fileURLWithPath: tmpDirectory).appendingPathComponent("\(uniqueString).jpg")
            
            do {
                try fileManager.moveItem(at: location, to: tmpFileURL)
                let attachment = try UNNotificationAttachment(identifier: uniqueString, url: tmpFileURL, options: nil)
                completion(attachment, nil)
            } catch {
                completion(nil, error)
            }
        }
        task.resume()
    }
}
