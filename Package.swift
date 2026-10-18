// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tezgah",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor", from: "0.15.2"),
        // Pinned by CodeEditSourceEditor; listed so Tezgah can import it directly.
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", exact: "0.1.20"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.25.0"),
        // GitHub-flavored Markdown → HTML for the preview.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.6.0"),
        // Database drivers.
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.32.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Tezgah",
            dependencies: [
                "SwiftTerm",
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
            ],
            path: "Sources/Tezgah",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TezgahTests",
            dependencies: [
                "Tezgah",
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
            ],
            path: "Tests/TezgahTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
