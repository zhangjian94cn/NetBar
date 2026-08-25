import Foundation

enum NetBarResourceBundle {
    static func installedBundle(in mainBundle: Bundle) -> Bundle? {
        guard let url = mainBundle.url(
            forResource: "NetBar_NetBar",
            withExtension: "bundle"
        ) else {
            return nil
        }
        return Bundle(url: url)
    }

    static var current: Bundle {
        installedBundle(in: .main) ?? .module
    }
}
