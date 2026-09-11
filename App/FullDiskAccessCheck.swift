import Foundation

enum FullDiskAccessCheck {
    enum Status: Equatable, Sendable {
        case required, available, missingPreferences, unavailable
    }

    // Check the data the engine needs, not a TCC database or an unrelated protected folder.
    static func checkRequiredLocation(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Status {
        let directory = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Preferences")
        do {
            do {
                let handle = try FileHandle(forUpdating: directory.appendingPathComponent("com.apple.Safari.plist"))
                try handle.close()
            } catch {
                guard isMissing(error as NSError) else { throw error }
                _ = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            }
            return .available
        } catch {
            let error = error as NSError
            if isAccessDenied(error) { return .required }
            return isMissing(error) ? .missingPreferences : .unavailable
        }
    }

    static func isAccessDenied(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EACCES) || error.code == Int(EPERM)) { return true }
        if error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoPermissionError || error.code == NSFileWriteNoPermissionError) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isAccessDenied) ?? false
    }

    private static func isMissing(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return true }
        if error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isMissing) ?? false
    }
}
