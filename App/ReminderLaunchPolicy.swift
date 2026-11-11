import AppKit
import Carbon

enum ReminderLaunchPolicy {
    /// Check while AppKit is handling its open-application event. A nil event is not evidence of a login launch.
    static func isLoginEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == kAEOpenApplication else { return false }
        if event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true
            || event.attributeDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true
    }
}
