import Foundation

func countedLabel(
    _ count: Int,
    singular: String,
    plural: String? = nil
) -> String {
    let noun = count == 1 ? singular : plural ?? singular + "s"
    return "\(count) \(noun)"
}
