// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingAssistant",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "MeetingAssistant", targets: ["MeetingAssistant"]),
               .executable(name: "MeetingDiagnostics", targets: ["MeetingDiagnostics"])],
    targets: [
        .target(name: "MeetingCore"),
        .target(name: "AudioSafety"),
        .executableTarget(name: "MeetingAssistant", dependencies: ["MeetingCore", "AudioSafety"]),
        .executableTarget(name: "MeetingDiagnostics", dependencies: ["MeetingCore"]),
        .executableTarget(name: "AudioSafetyChecks", dependencies: ["AudioSafety"], path: "Tests/AudioSafetyChecks"),
        .executableTarget(name: "MeetingCoreChecks", dependencies: ["MeetingCore"], path: "Tests/MeetingCoreTests")
    ]
)
