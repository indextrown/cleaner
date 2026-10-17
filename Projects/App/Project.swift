import ProjectDescription

let project = Project(
    name: "Cleaner",
    // 저장소 루트의 Package.swift. 코어 라이브러리(CleanerCore)를 Xcode에서 함께 열고 고칠 수 있다.
    packages: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "Cleaner",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.cleaner.Cleaner",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDevelopmentRegion": "ko",
                    "CFBundleDisplayName": "Cleaner",
                    "CFBundleLocalizations": ["ko"],
                    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                    "LSApplicationCategoryType": "public.app-category.utilities",
                ]
            ),
            sources: ["Sources/**"],
            dependencies: [
                .package(product: "CleanerCore"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.0",
                    "MARKETING_VERSION": "0.1.0",
                    "CURRENT_PROJECT_VERSION": "1",
                    // 개인 인증서로 직접 서명한다. 인증서는 Signing.xcconfig(git 제외)에 적는다.
                    // Tuist가 타깃에 넣는 기본값("-")이 xcconfig보다 우선하므로, 타깃 설정이 xcconfig 변수를 가리키게 한다.
                    "CODE_SIGN_STYLE": "Manual",
                    "CODE_SIGN_IDENTITY": "$(CLEANER_CODE_SIGN_IDENTITY)",
                    // 다른 앱의 파일을 읽고 지워야 해서 샌드박스를 쓰지 않는다.
                    "ENABLE_APP_SANDBOX": "NO",
                ],
                configurations: [
                    .debug(name: "Debug", xcconfig: .relativeToManifest("Configuration.xcconfig")),
                    .release(name: "Release", xcconfig: .relativeToManifest("Configuration.xcconfig")),
                ]
            )
        ),
    ]
)
