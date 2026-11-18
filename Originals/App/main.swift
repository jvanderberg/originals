import Foundation

#if DEBUG
// Headless developer probe (no window, no Dock icon), used to test download paths outside the UI:
//   open -n -g --env ORIGINALS_PROBE=/path/to/workdir Originals.app
// Runs as the same signed app, so it shares Originals' Photos permission.
if let workDir = ProcessInfo.processInfo.environment["ORIGINALS_PROBE"] {
    MainActor.assumeIsolated { HeadlessProbe.main(workDir: URL(fileURLWithPath: workDir, isDirectory: true)) }
}
#endif
OriginalsApp.main()
