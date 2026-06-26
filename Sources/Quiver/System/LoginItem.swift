import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService. Requires a real (bundled) app — works from
/// `Quiver.app`, not from `swift run`. Errors are surfaced to the caller.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
