enum WindowClassifier {
    private static let excludedDesktopRotationSubroles: Set<String> = [
        "AXFloatingWindow",
        "AXSystemDialog",
        "AXDialog",
        "AXSheet"
    ]

    static func shouldExcludeFromDesktopRotation(subrole: String?) -> Bool {
        guard let subrole else { return false }
        return excludedDesktopRotationSubroles.contains(subrole)
    }
}
