import Foundation

public enum AgentWorktreeLocator {
    public static func root(
        containing directoryURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidate = directoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue {
            candidate.deleteLastPathComponent()
        }

        while true {
            if fileManager.fileExists(
                atPath: candidate.appendingPathComponent(".git").path
            ) {
                return candidate
            }
            guard !candidate.path.isEmpty, candidate.path != "/" else {
                return nil
            }
            candidate.deleteLastPathComponent()
        }
    }
}
