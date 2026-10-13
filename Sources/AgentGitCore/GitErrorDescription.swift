import Foundation

public enum GitErrorDescription {
    public static func message(for error: any Error) -> String {
        if let description = (error as? any LocalizedError)?.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        switch error {
        case let error as GitCommandFailure: return error.description
        case let error as GitCommandTimeoutError: return error.description
        case let error as GitCommandOutputLimitError: return error.description
        case let error as GitSubmoduleDiscardError: return error.description
        case let error as GitMutationError:
            return switch error {
            case .invalidScope: "Choose a working tree or staged change for this action."
            case .pathOutsideWorktree: "The selected file is outside this worktree."
            }
        case let error as GitPatchSelectionError:
            return switch error {
            case .noChangedLines: "Select added or deleted lines before applying this action."
            case .nonTextualDiff: "Line actions are only available for text files. Use a file action instead."
            case let .unsupportedFileMode(mode): "Line actions are unavailable for file mode \(mode). Use a file action instead."
            }
        case is GitStatusParseError:
            return "Git returned a status record that could not be read. Refresh the repository and try again."
        case is WorktreeListParseError:
            return "Git returned a worktree list that could not be read. Refresh the project and try again."
        case is GitLogParseError:
            return "Git returned a history record that could not be read. Refresh the history and try again."
        case is UnifiedDiffParseError:
            return "The diff could not be read as text. Refresh the diff or open the file directly."
        case is GitNumstatParseError:
            return "Git returned change statistics that could not be read. Refresh the repository and try again."
        case is CancellationError:
            return "The operation was cancelled."
        default:
            let underlying = error as NSError
            if underlying.userInfo[NSLocalizedDescriptionKey] != nil
                || [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain].contains(underlying.domain) {
                return underlying.localizedDescription
            }
            return "The operation could not be completed. Try again and check the diagnostic log if it keeps failing."
        }
    }
}
