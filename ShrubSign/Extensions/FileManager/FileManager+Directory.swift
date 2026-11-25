import Foundation
import Darwin

extension FileManager {
    func volumeAvailableCapacity(for url: URL) throws -> Int64 {
        let resourceValues = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let capacity = resourceValues.volumeAvailableCapacity else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: nil)
        }
        return Int64(capacity)
    }

    /// The clone has its own metadata and copy-on-write data, so signing can
    /// change it without touching the source app. Fall back across volumes.
    func copyAppBundle(at source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return clonefile(sourcePath, destinationPath, UInt32(CLONE_NOFOLLOW))
            }
        }
        if result != 0 {
            try copyItem(at: source, to: destination)
        }
    }
}
