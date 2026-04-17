import ApplicationServices
import Cocoa

private let minimumStageContextWindowWidth = 300
private let minimumStageContextWindowHeight = 200
private let maximumStageThumbnailWidth = 260
private let maximumStageThumbnailHeight = 260

struct StageBundleResolution {
    let bundleIdentifiers: Set<String>
    let windowIDs: Set<CGWindowID>
}

private struct StageVisibleEntry {
    let windowID: CGWindowID
    let bundleIdentifier: String
}

private func regularBundleIdentifier(
    for pid: Int32,
    cache: inout [Int32: String],
    rejectedPIDs: inout Set<Int32>
) -> String? {
    if let bundleIdentifier = cache[pid] {
        return bundleIdentifier
    }

    if rejectedPIDs.contains(pid) {
        return nil
    }

    guard let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
        rejectedPIDs.insert(pid)
        return nil
    }

    cache[pid] = bundleIdentifier
    return bundleIdentifier
}

private func focusedApplicationBundleIdentifier() -> String? {
    let systemWideElement = AXUIElementCreateSystemWide()
    guard let focusedAppElement = try? systemWideElement.attribute(kAXFocusedApplicationAttribute, AXUIElement.self),
          let pid = try? focusedAppElement.pid(),
          let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    else {
        return nil
    }

    return bundleIdentifier
}

func currentStageContextBundleIdentifier(capturedBundleIdentifier: String? = nil) -> String? {
    if let capturedBundleIdentifier {
        return capturedBundleIdentifier
    }

    if let focusedBundleId = focusedApplicationBundleIdentifier() {
        return focusedBundleId
    }

    if let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
        return frontmostBundleId
    }

    guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else {
        return nil
    }

    var bundleIdentifiersByPID = [Int32: String]()
    var rejectedPIDs = Set<Int32>()

    for desc in list {
        let layer = (desc[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        guard layer == 0 else { continue }

        let isOnscreen = (desc[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let isActiveOffscreen = (desc["kSLWindowIsActiveOffscreen"] as? NSNumber)?.boolValue ?? false

        let bounds = desc[kCGWindowBounds as String] as? [String: AnyObject]
        let width = (bounds?["Width"] as? NSNumber)?.intValue ?? 0
        let height = (bounds?["Height"] as? NSNumber)?.intValue ?? 0
        let isSubstantialWindow = width >= minimumStageContextWindowWidth && height >= minimumStageContextWindowHeight

        guard isActiveOffscreen || (isOnscreen && isSubstantialWindow) else { continue }

        let pid = (desc[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        guard let bundleId = regularBundleIdentifier(
            for: pid,
            cache: &bundleIdentifiersByPID,
            rejectedPIDs: &rejectedPIDs
        ) else {
            continue
        }

        return bundleId
    }

    return nil
}

private func currentOnscreenStageEntries() -> [StageVisibleEntry] {
    var bundleIdentifiersByPID = [Int32: String]()
    var rejectedPIDs = Set<Int32>()

    guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else {
        return []
    }

    var entries = [StageVisibleEntry]()
    entries.reserveCapacity(list.count)

    for desc in list {
        let layer = (desc[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        let isOnscreen = (desc[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        guard layer == 0, isOnscreen else { continue }

        let bounds = desc[kCGWindowBounds as String] as? [String: AnyObject]
        let width = (bounds?["Width"] as? NSNumber)?.intValue ?? 0
        let height = (bounds?["Height"] as? NSNumber)?.intValue ?? 0

        guard width > 0, height > 0 else {
            continue
        }

        let isLikelyStageThumbnail = width <= maximumStageThumbnailWidth && height <= maximumStageThumbnailHeight
        guard !isLikelyStageThumbnail else {
            continue
        }

        let pid = (desc[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        guard let bundleIdentifier = regularBundleIdentifier(
            for: pid,
            cache: &bundleIdentifiersByPID,
            rejectedPIDs: &rejectedPIDs
        ),
            bundleIdentifier != "com.apple.WindowManager"
        else {
            continue
        }

        entries.append(StageVisibleEntry(
            windowID: CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0),
            bundleIdentifier: bundleIdentifier
        ))
    }

    return entries
}

private func isStageManagerManagedSpaceActive() -> Bool {
    guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: AnyObject]] else {
        return false
    }

    for display in displays {
        guard let currentSpace = display["Current Space"] as? [String: AnyObject],
              let windowManagerInfo = currentSpace["WindowManagerInfo"] as? [String: AnyObject],
              let windowSets = windowManagerInfo["windowSets"] as? [String: [String]],
              !windowSets.isEmpty
        else {
            continue
        }

        return true
    }

    return false
}

// Returns the window and bundle identifiers in the active Stage Manager stage, when available.
func currentStageBundleResolution(contextBundleIdentifier: String? = nil) -> StageBundleResolution {
    guard let contextBundleId = currentStageContextBundleIdentifier(capturedBundleIdentifier: contextBundleIdentifier) else {
        return StageBundleResolution(bundleIdentifiers: [], windowIDs: [])
    }

    guard isStageManagerManagedSpaceActive() else {
        return StageBundleResolution(bundleIdentifiers: [], windowIDs: [])
    }

    let visibleStageEntries = currentOnscreenStageEntries()
    guard !visibleStageEntries.isEmpty else {
        return StageBundleResolution(bundleIdentifiers: [], windowIDs: [])
    }

    var visibleStageBundleIdentifiers = Set<String>()
    visibleStageBundleIdentifiers.reserveCapacity(visibleStageEntries.count)
    var visibleStageWindowIDs = Set<CGWindowID>()
    visibleStageWindowIDs.reserveCapacity(visibleStageEntries.count)
    var containsContextBundle = false

    for entry in visibleStageEntries {
        visibleStageBundleIdentifiers.insert(entry.bundleIdentifier)
        visibleStageWindowIDs.insert(entry.windowID)
        if entry.bundleIdentifier == contextBundleId {
            containsContextBundle = true
        }
    }

    if containsContextBundle {
        return StageBundleResolution(
            bundleIdentifiers: visibleStageBundleIdentifiers,
            windowIDs: visibleStageWindowIDs
        )
    }

    return StageBundleResolution(bundleIdentifiers: [], windowIDs: [])
}
