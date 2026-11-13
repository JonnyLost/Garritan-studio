// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MusioCreate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DAWCore", targets: ["DAWCore"]),
        .library(name: "StudioAnalogDSP", targets: ["StudioAnalogDSP"]),
        .library(name: "StudioFMDSP", targets: ["StudioFMDSP"]),
        .library(name: "StudioWavetableDSP", targets: ["StudioWavetableDSP"]),
        .library(name: "StudioAdditiveDSP", targets: ["StudioAdditiveDSP"]),
        .library(name: "StudioGranularDSP", targets: ["StudioGranularDSP"]),
        .library(name: "StudioSamplerDSP", targets: ["StudioSamplerDSP"]),
        .library(name: "StudioPhysicalDSP", targets: ["StudioPhysicalDSP"]),
        .library(name: "DAWUI", targets: ["DAWUI"]),
        .library(name: "VST3Bridge", targets: ["VST3Bridge"]),
        .executable(name: "DAWApp", targets: ["DAWApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0")
    ],
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

        // MARK: - Original spectral additive voice renderer
        .target(
            name: "StudioAdditiveDSP",
            path: "StudioAdditiveDSP",
            sources: ["src/StudioAdditiveDSP.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),

        // MARK: - Original real-time grain-cloud renderer
        .target(
            name: "StudioGranularDSP",
            path: "StudioGranularDSP",
            sources: ["src/StudioGranularDSP.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),

        // MARK: - Original native multi-zone sampler with RAM/disk streaming
        .target(
            name: "StudioSamplerDSP",
            path: "StudioSamplerDSP",
            sources: ["src/StudioSamplerDSP.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),

        // MARK: - Native plucked / struck string waveguides and body modes
        .target(
            name: "StudioPhysicalDSP",
            path: "StudioPhysicalDSP",
            sources: ["src/StudioPhysicalDSP.cpp"],
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

        // MARK: - Core Audio/MIDI Engine
        .target(
            name: "DAWCore",
            dependencies: [
                "DAWRealtime",
                "StudioAnalogDSP",
                "StudioFMDSP",
                "StudioWavetableDSP",
                "StudioAdditiveDSP",
                "StudioGranularDSP",
                "StudioPhysicalDSP",
                "StudioSamplerDSP",
                .product(name: "Supabase", package: "supabase-swift")
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
            dependencies: ["DAWCore"],
            path: "DAWUI/Sources/DAWUI",
            resources: [
                .copy("Resources/GPO5_keyswitch_catalog.json")
            ]
        ),
        
        // MARK: - Main Application
        .executableTarget(
            name: "DAWApp",
            dependencies: ["DAWCore", "DAWUI", "VST3Bridge"],
            path: "DAWApp/Sources/DAWApp"
        ),
        
        // MARK: - Tests
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
            name: "StudioPhysicalDSPTests",
            dependencies: ["StudioPhysicalDSP"],
            path: "Tests/StudioPhysicalDSPTests"
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
