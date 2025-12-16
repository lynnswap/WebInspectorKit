import SwiftUI

extension ButtonRole {
    static var closeRole: ButtonRole {
        if #available(iOS 26.0, macOS 26.0, *) {
            return .close
        } else {
            return .cancel
        }
    }

    static var confirmRole: ButtonRole? {
        if #available(iOS 26.0, macOS 26.0, *) {
            return .confirm
        } else {
            return nil
        }
    }
}
