// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// The normal Studio application is local-first, with no external SwiftPM SDK.
// Set STUDIO_ENABLE_CLOUD_AUTH=1 to build the existing Supabase sign-in UI.
let studioCloudAuthEnabled = ProcessInfo.processInfo.environment["STUDIO_ENABLE_CLOUD_AUTH"] == "1"

let package = Package(
    name: "Studio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DAWCore", targets: ["DAWCore"]),
        .library(name: "StudioIdentity", targets: ["StudioIdentity"]),
        .library(name: "StudioAI", targets: ["StudioAI"]),
        .library(name: "StudioCloudAuth", targets: ["StudioCloudAuth"]),
        .library(name: "StudioAnalogDSP", targets: ["StudioAnalogDSP"]),
        .library(name: "StudioSamplerDSP", targets: ["StudioSamplerDSP"]),
        .library(name: "StudioFMDSP", targets: ["StudioFMDSP"]),
        .library(name: "StudioWavetableDSP", targets: ["StudioWavetableDSP"]),
        .library(name: "DAWUI", targets: ["DAWUI"]),
        .library(name: "VST3Bridge", targets: ["VST3Bridge"]),
        .executable(name: "DAWApp", targets: ["DAWApp"]),
        .executable(name: "RoomAcousticCalibration", targets: ["RoomAcousticCalibration"])
    ],
    dependencies: studioCloudAuthEnabled
        ? [.package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0")]
        : [],
    targets: [
        // MARK: - Original, standalone C++17 modular virtual-analog engine
        .target(
            name: "StudioAnalogDSP",
            path: "StudioAnalogDSP",
            sources: ["src/StudioAnalogDSP.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),

        // MARK: - Original four-operator FM engine
        .target(
            name: "StudioFMDSP",
            path: "StudioFMDSP",
            sources: ["src/StudioFMDSP.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),

        // MARK: - Original morphable, bandlimited wavetable renderer
        .target(
            name: "StudioWavetableDSP",
            path: "StudioWavetableDSP",
            sources: ["src/StudioWavetableDSP.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),

        // MARK: - Original native sample playback DSP
        .target(
            name: "StudioSamplerDSP",
            path: "StudioSamplerDSP",
            sources: ["src/StudioSamplerDSP.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),

        // MARK: - Real-time callback primitives (C11 atomics)
        .target(
            name: "DAWRealtime",
            path: "DAWRealtime",
            sources: ["DAWRealtime.c"],
            publicHeadersPath: "include"
        ),

        // MARK: - Shared lightweight product identity (no DAW or network dependencies)
        .target(
            name: "StudioIdentity",
            path: "StudioIdentity/Sources/StudioIdentity"
        ),

        // MARK: - Optional network/AI composition services (not part of DAWCore)
        .target(
            name: "StudioAI",
            dependencies: ["DAWCore"],
            path: "StudioAI/Sources/StudioAI",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // MARK: - Optional cloud authentication (never required by the DAW core)
        .target(
            name: "StudioCloudAuth",
            dependencies: studioCloudAuthEnabled
                ? [.product(name: "Supabase", package: "supabase-swift")]
                : [],
            path: "StudioCloudAuth/Sources/StudioCloudAuth",
            exclude: studioCloudAuthEnabled
                ? ["LocalOnlyAuthService.swift"]
                : ["SupabaseAuthService.swift"],
            swiftSettings: studioCloudAuthEnabled
                ? [.enableExperimentalFeature("StrictConcurrency")]
                : [.enableExperimentalFeature("StrictConcurrency"), .define("STUDIO_LOCAL_AUTH")]
        ),

        // MARK: - Core Audio/MIDI Engine
        .target(
            name: "DAWCore",
            dependencies: [
                "DAWRealtime",
                "StudioAnalogDSP",
                "StudioFMDSP",
                "StudioWavetableDSP",
                "StudioSamplerDSP"
            ],
            path: "DAWCore/Sources/DAWCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        
        // MARK: - VST3 C++ Bridge
        // This target wraps the C++ VST3 SDK and exposes it to Swift
        .target(
            name: "VST3BridgeCpp",
            dependencies: [],
            path: "VST3Bridge/Sources/VST3BridgeCpp",
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .define("RELEASE", .when(configuration: .release)),
                .unsafeFlags(["-std=c++17"])
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreAudio")
            ]
        ),
        
        .target(
            name: "VST3Bridge",
            dependencies: ["VST3BridgeCpp"],
            path: "VST3Bridge/Sources/VST3Bridge",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        
        // MARK: - SwiftUI Layer
        .target(
            name: "DAWUI",
            dependencies: ["DAWCore", "StudioCloudAuth", "StudioIdentity", "StudioAI"],
            path: "DAWUI/Sources/DAWUI",
            exclude: studioCloudAuthEnabled
                ? ["Views/Auth/OfflineAccountViews.swift"]
                : ["Views/Auth/AuthenticationView.swift", "Views/Auth/AccountSettingsView.swift"],
            resources: [
                .copy("Resources/GPO5_keyswitch_catalog.json")
            ],
            swiftSettings: studioCloudAuthEnabled ? [] : [.define("STUDIO_LOCAL_AUTH")]
        ),
        
        // MARK: - Main Application
        .executableTarget(
            name: "DAWApp",
            dependencies: ["DAWCore", "DAWUI", "StudioIdentity"],
            path: "DAWApp/Sources/DAWApp"
        ),
        
        // MARK: - Offline room impulse calibration (never runs in the DAW)
        .executableTarget(
            name: "RoomAcousticCalibration",
            dependencies: ["DAWCore"],
            path: "Tools/RoomAcousticCalibration"
        ),

        // MARK: - Tests
        .testTarget(
            name: "StudioCloudAuthTests",
            dependencies: ["StudioCloudAuth"],
            path: "Tests/StudioCloudAuthTests",
            swiftSettings: studioCloudAuthEnabled ? [] : [.define("STUDIO_LOCAL_AUTH")]
        ),
        .testTarget(
            name: "StudioIdentityTests",
            dependencies: ["StudioIdentity"],
            path: "Tests/StudioIdentityTests"
        ),
        .testTarget(
            name: "StudioFMDSPTests",
            dependencies: ["StudioFMDSP"],
            path: "Tests/StudioFMDSPTests"
        ),
        .testTarget(
            name: "StudioWavetableDSPTests",
            dependencies: ["StudioWavetableDSP"],
            path: "Tests/StudioWavetableDSPTests"
        ),
        .testTarget(
            name: "StudioAnalogDSPTests",
            dependencies: ["StudioAnalogDSP"],
            path: "Tests/StudioAnalogDSPTests"
        ),
        .testTarget(
            name: "DAWCoreTests",
            dependencies: ["DAWCore", "DAWRealtime"],
            path: "Tests/DAWCoreTests"
        )
    ]
)
