import Foundation

extension Bundle {
    var displayName: String {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as! String
    }

    var displayVersion: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as! String
        return "\(version) (\(build))"
    }
}
