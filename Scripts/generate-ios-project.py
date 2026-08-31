#!/usr/bin/env python3
"""Generates ios/ChronoRemote/ChronoRemote.xcodeproj.

A generator rather than a checked-in pbxproj on purpose. A pbxproj is a 500-line file of
opaque 24-hex identifiers that nobody can review and that conflicts on every merge; this
script is the readable source of truth, and object ids are derived deterministically from
names so regenerating produces a byte-identical file.

Run after adding or removing a source file:

    python3 Scripts/generate-ios-project.py
"""

import hashlib
import os
import pathlib

PROJECT_NAME = "ChronoRemote"
BUNDLE_ID = "in.chrono.remote"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT_DIR = ROOT / "ios" / PROJECT_NAME
XCODEPROJ = PROJECT_DIR / f"{PROJECT_NAME}.xcodeproj"

# Sources that live inside the iOS app.
APP_SOURCES = [
    "ChronoRemoteApp.swift",
    "RemoteView.swift",
    "PairingIntroView.swift",
    "PairingStore.swift",
    "BLEClient.swift",
    "QRScannerView.swift",
]

# Sources shared verbatim with the Mac app.
#
# Compiled straight into the iOS target rather than linked as a package: it is the same file on
# disk, so the wire protocol and the signing scheme physically cannot drift between the two
# apps, and there is no package resolution for someone to get wrong before their first build.
SHARED_SOURCES = [
    "../../Sources/ChronoCore/Util/Clock.swift",
    "../../Sources/ChronoCore/Remote/RemoteProtocol.swift",
    "../../Sources/ChronoCore/Remote/RemoteAuth.swift",
]

RESOURCES = ["Assets.xcassets"]


def oid(*parts: str) -> str:
    """Stable 24-character hex id derived from a name."""
    digest = hashlib.md5("::".join(parts).encode()).hexdigest().upper()
    return digest[:24]


def main() -> None:
    XCODEPROJ.mkdir(parents=True, exist_ok=True)

    # --- object ids -------------------------------------------------------------------
    project_id = oid("project")
    target_id = oid("target")
    product_id = oid("product")
    main_group = oid("group", "main")
    app_group = oid("group", "app")
    shared_group = oid("group", "shared")
    products_group = oid("group", "products")
    sources_phase = oid("phase", "sources")
    frameworks_phase = oid("phase", "frameworks")
    resources_phase = oid("phase", "resources")
    project_config_list = oid("configlist", "project")
    target_config_list = oid("configlist", "target")

    all_sources = APP_SOURCES + SHARED_SOURCES

    def file_ref(path: str) -> str:
        return oid("fileref", path)

    def build_file(path: str) -> str:
        return oid("buildfile", path)

    lines: list[str] = []
    add = lines.append

    add("// !$*UTF8*$!")
    add("{")
    add("\tarchiveVersion = 1;")
    add("\tclasses = {")
    add("\t};")
    add("\tobjectVersion = 56;")
    add(f"\tobjects = {{")

    # --- PBXBuildFile ------------------------------------------------------------------
    add("")
    add("/* Begin PBXBuildFile section */")
    for path in all_sources:
        name = os.path.basename(path)
        add(
            f"\t\t{build_file(path)} /* {name} in Sources */ = {{isa = PBXBuildFile; "
            f"fileRef = {file_ref(path)} /* {name} */; }};"
        )
    for path in RESOURCES:
        add(
            f"\t\t{build_file(path)} /* {path} in Resources */ = {{isa = PBXBuildFile; "
            f"fileRef = {file_ref(path)} /* {path} */; }};"
        )
    add("/* End PBXBuildFile section */")

    # --- PBXFileReference --------------------------------------------------------------
    add("")
    add("/* Begin PBXFileReference section */")
    add(
        f"\t\t{product_id} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.application; includeInIndex = 0; "
        f'path = "{PROJECT_NAME}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )
    for path in APP_SOURCES:
        add(
            f"\t\t{file_ref(path)} /* {path} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {path}; sourceTree = \"<group>\"; }};"
        )
    for path in SHARED_SOURCES:
        name = os.path.basename(path)
        # SOURCE_ROOT is the directory containing the .xcodeproj, so these relative paths
        # reach back into Sources/ChronoCore.
        add(
            f"\t\t{file_ref(path)} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; name = {name}; "
            f'path = "{path}"; sourceTree = SOURCE_ROOT; }};'
        )
    for path in RESOURCES:
        add(
            f"\t\t{file_ref(path)} /* {path} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = folder.assetcatalog; path = {path}; sourceTree = \"<group>\"; }};"
        )
    add("/* End PBXFileReference section */")

    # --- PBXFrameworksBuildPhase -------------------------------------------------------
    add("")
    add("/* Begin PBXFrameworksBuildPhase section */")
    add(f"\t\t{frameworks_phase} /* Frameworks */ = {{")
    add("\t\t\tisa = PBXFrameworksBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXFrameworksBuildPhase section */")

    # --- PBXGroup ----------------------------------------------------------------------
    add("")
    add("/* Begin PBXGroup section */")
    add(f"\t\t{main_group} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{app_group} /* {PROJECT_NAME} */,")
    add(f"\t\t\t\t{products_group} /* Products */,")
    add("\t\t\t);")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{app_group} /* {PROJECT_NAME} */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for path in APP_SOURCES:
        add(f"\t\t\t\t{file_ref(path)} /* {path} */,")
    add(f"\t\t\t\t{shared_group} /* Shared with the Mac app */,")
    for path in RESOURCES:
        add(f"\t\t\t\t{file_ref(path)} /* {path} */,")
    add("\t\t\t);")
    add(f"\t\t\tpath = {PROJECT_NAME};")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{shared_group} /* Shared with the Mac app */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for path in SHARED_SOURCES:
        add(f"\t\t\t\t{file_ref(path)} /* {os.path.basename(path)} */,")
    add("\t\t\t);")
    add("\t\t\tname = \"Shared with the Mac app\";")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{products_group} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{product_id} /* {PROJECT_NAME}.app */,")
    add("\t\t\t);")
    add("\t\t\tname = Products;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")
    add("/* End PBXGroup section */")

    # --- PBXNativeTarget ---------------------------------------------------------------
    add("")
    add("/* Begin PBXNativeTarget section */")
    add(f"\t\t{target_id} /* {PROJECT_NAME} */ = {{")
    add("\t\t\tisa = PBXNativeTarget;")
    add(f"\t\t\tbuildConfigurationList = {target_config_list} /* Build configuration list */;")
    add("\t\t\tbuildPhases = (")
    add(f"\t\t\t\t{sources_phase} /* Sources */,")
    add(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
    add(f"\t\t\t\t{resources_phase} /* Resources */,")
    add("\t\t\t);")
    add("\t\t\tbuildRules = (")
    add("\t\t\t);")
    add("\t\t\tdependencies = (")
    add("\t\t\t);")
    add(f"\t\t\tname = {PROJECT_NAME};")
    add(f"\t\t\tproductName = {PROJECT_NAME};")
    add(f"\t\t\tproductReference = {product_id} /* {PROJECT_NAME}.app */;")
    add("\t\t\tproductType = \"com.apple.product-type.application\";")
    add("\t\t};")
    add("/* End PBXNativeTarget section */")

    # --- PBXProject --------------------------------------------------------------------
    add("")
    add("/* Begin PBXProject section */")
    add(f"\t\t{project_id} /* Project object */ = {{")
    add("\t\t\tisa = PBXProject;")
    add("\t\t\tattributes = {")
    add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    add("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    add("\t\t\t\tLastUpgradeCheck = 1600;")
    add("\t\t\t\tTargetAttributes = {")
    add(f"\t\t\t\t\t{target_id} = {{")
    add("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    add("\t\t\t\t\t};")
    add("\t\t\t\t};")
    add("\t\t\t};")
    add(f"\t\t\tbuildConfigurationList = {project_config_list} /* Build configuration list */;")
    add("\t\t\tcompatibilityVersion = \"Xcode 15.0\";")
    add("\t\t\tdevelopmentRegion = en;")
    add("\t\t\thasScannedForEncodings = 0;")
    add("\t\t\tknownRegions = (")
    add("\t\t\t\ten,")
    add("\t\t\t\tBase,")
    add("\t\t\t);")
    add(f"\t\t\tmainGroup = {main_group};")
    add(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    add("\t\t\tprojectDirPath = \"\";")
    add("\t\t\tprojectRoot = \"\";")
    add("\t\t\ttargets = (")
    add(f"\t\t\t\t{target_id} /* {PROJECT_NAME} */,")
    add("\t\t\t);")
    add("\t\t};")
    add("/* End PBXProject section */")

    # --- PBXResourcesBuildPhase --------------------------------------------------------
    add("")
    add("/* Begin PBXResourcesBuildPhase section */")
    add(f"\t\t{resources_phase} /* Resources */ = {{")
    add("\t\t\tisa = PBXResourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for path in RESOURCES:
        add(f"\t\t\t\t{build_file(path)} /* {path} in Resources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXResourcesBuildPhase section */")

    # --- PBXSourcesBuildPhase ----------------------------------------------------------
    add("")
    add("/* Begin PBXSourcesBuildPhase section */")
    add(f"\t\t{sources_phase} /* Sources */ = {{")
    add("\t\t\tisa = PBXSourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for path in all_sources:
        add(f"\t\t\t\t{build_file(path)} /* {os.path.basename(path)} in Sources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXSourcesBuildPhase section */")

    # --- XCBuildConfiguration ----------------------------------------------------------
    shared_project_settings = [
        "ALWAYS_SEARCH_USER_PATHS = NO",
        "CLANG_ENABLE_MODULES = YES",
        "CLANG_ENABLE_OBJC_ARC = YES",
        "ENABLE_STRICT_OBJC_MSGSEND = YES",
        f"IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET}",
        "SDKROOT = iphoneos",
        f"SWIFT_VERSION = {SWIFT_VERSION}",
        "TARGETED_DEVICE_FAMILY = \"1,2\"",
    ]

    target_settings = [
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = \"\"",
        "CODE_SIGN_STYLE = Automatic",
        "CURRENT_PROJECT_VERSION = 1",
        "ENABLE_PREVIEWS = YES",
        # The Info.plist is generated from these build settings, so there is no plist file to
        # keep in step with the project.
        "GENERATE_INFOPLIST_FILE = YES",
        "INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription = \"Chrono Remote talks to Chrono on your Mac over Bluetooth so you can pause or stop your timer from anywhere nearby.\"",
        "INFOPLIST_KEY_NSCameraUsageDescription = \"The camera is used once, to scan the pairing code shown by Chrono on your Mac.\"",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation = YES",
        "INFOPLIST_KEY_UIStatusBarStyle = UIStatusBarStyleLightContent",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait",
        "LD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/Frameworks\")",
        "MARKETING_VERSION = 1.0",
        f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID}",
        "PRODUCT_NAME = \"$(TARGET_NAME)\"",
        "SWIFT_EMIT_LOC_STRINGS = YES",
    ]

    def configuration(config_id: str, name: str, settings: list[str], debug: bool) -> None:
        add(f"\t\t{config_id} /* {name} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        add("\t\t\tbuildSettings = {")
        extra = (
            [
                "DEBUG_INFORMATION_FORMAT = dwarf",
                "ENABLE_TESTABILITY = YES",
                "GCC_OPTIMIZATION_LEVEL = 0",
                "ONLY_ACTIVE_ARCH = YES",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG",
                "SWIFT_OPTIMIZATION_LEVEL = \"-Onone\"",
            ]
            if debug
            else [
                "DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\"",
                "ENABLE_NS_ASSERTIONS = NO",
                "SWIFT_COMPILATION_MODE = wholemodule",
            ]
        )
        for setting in sorted(settings + extra):
            add(f"\t\t\t\t{setting};")
        add("\t\t\t};")
        add(f"\t\t\tname = {name};")
        add("\t\t};")

    add("")
    add("/* Begin XCBuildConfiguration section */")
    configuration(oid("config", "project", "Debug"), "Debug", shared_project_settings, True)
    configuration(oid("config", "project", "Release"), "Release", shared_project_settings, False)
    configuration(oid("config", "target", "Debug"), "Debug", target_settings, True)
    configuration(oid("config", "target", "Release"), "Release", target_settings, False)
    add("/* End XCBuildConfiguration section */")

    # --- XCConfigurationList -----------------------------------------------------------
    add("")
    add("/* Begin XCConfigurationList section */")
    for list_id, kind in ((project_config_list, "project"), (target_config_list, "target")):
        add(f"\t\t{list_id} /* Build configuration list */ = {{")
        add("\t\t\tisa = XCConfigurationList;")
        add("\t\t\tbuildConfigurations = (")
        add(f"\t\t\t\t{oid('config', kind, 'Debug')} /* Debug */,")
        add(f"\t\t\t\t{oid('config', kind, 'Release')} /* Release */,")
        add("\t\t\t);")
        add("\t\t\tdefaultConfigurationIsVisible = 0;")
        add("\t\t\tdefaultConfigurationName = Release;")
        add("\t\t};")
    add("/* End XCConfigurationList section */")

    add("\t};")
    add(f"\trootObject = {project_id} /* Project object */;")
    add("}")

    (XCODEPROJ / "project.pbxproj").write_text("\n".join(lines) + "\n")

    # A shared scheme, so the project can be built from the command line and Run works the
    # moment it is opened.
    schemes = XCODEPROJ / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    (schemes / f"{PROJECT_NAME}.xcscheme").write_text(SCHEME.format(
        project=PROJECT_NAME, target_id=target_id, product=f"{PROJECT_NAME}.app"
    ))

    print(f"[chrono] wrote {XCODEPROJ.relative_to(ROOT)}")


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{product}"
               BlueprintName = "{project}"
               ReferencedContainer = "container:{project}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{product}"
            BlueprintName = "{project}"
            ReferencedContainer = "container:{project}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{product}"
            BlueprintName = "{project}"
            ReferencedContainer = "container:{project}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

if __name__ == "__main__":
    main()
