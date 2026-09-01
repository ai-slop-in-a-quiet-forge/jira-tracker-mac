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

# The Apple Developer team to sign with is per-person, not per-project: a team id committed here
# would be one contributor's identity imposed on everyone else's build.
#
# It therefore lives in `Local.xcconfig`, which is generated once and gitignored. An xcconfig is
# the right home rather than a build setting written into the project, because the project file
# is *generated and committed*: a per-machine value inside it shows up as a permanent local
# modification, and has to be stashed around every rebase. The xcconfig keeps the tracked file
# byte-identical for everyone.
#
#     echo 'DEVELOPMENT_TEAM = XXXXXXXXXX' > ios/ChronoRemote/Local.xcconfig
#
# Or set CHRONO_DEVELOPMENT_TEAM and regenerate, which seeds the file for you. Left unset the
# project builds for the simulator exactly as before; only device builds and archives need a team.
LOCAL_XCCONFIG = "Local.xcconfig"
SEED_DEVELOPMENT_TEAM = os.environ.get("CHRONO_DEVELOPMENT_TEAM", "").strip()


def write_local_xcconfig() -> None:
    """Creates `Local.xcconfig` if it is missing, so Xcode never points at a file that is not
    there. Never overwrites: it is the one file here a person is expected to edit."""
    path = PROJECT_DIR / LOCAL_XCCONFIG
    if path.exists():
        return
    team_line = (
        f"DEVELOPMENT_TEAM = {SEED_DEVELOPMENT_TEAM}"
        if SEED_DEVELOPMENT_TEAM
        else "// DEVELOPMENT_TEAM = XXXXXXXXXX"
    )
    path.write_text(
        "// Per-machine build settings. Gitignored: a team id is your identity, not the\n"
        "// project's, and committing one would sign everyone else's build as you.\n"
        "//\n"
        "// Find yours in Xcode > Settings > Accounts. Only device builds and archives need it;\n"
        "// the simulator does not.\n"
        f"{team_line}\n"
    )
    print(f"wrote {path.relative_to(ROOT)}")


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
    "ChronoActivityAttributes.swift",
    "LiveActivityController.swift",
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

# --- The Live Activity widget extension ----------------------------------------------
WIDGET_NAME = "ChronoRemoteWidget"
WIDGET_BUNDLE_ID = f"{BUNDLE_ID}.widget"

WIDGET_SOURCES = [
    "ChronoWidgetBundle.swift",
    "ChronoLockScreenView.swift",
    "ChronoDynamicIslandView.swift",
]

# Files that belong to the app but are also compiled into the extension. They keep their
# existing file references and only gain a second build-file entry, so there is one copy on
# disk: the widget cannot disagree with the app about what a ContentState contains, in the same
# way the iOS app cannot disagree with the Mac about the wire protocol.
WIDGET_REUSED_SOURCES = [
    "ChronoActivityAttributes.swift",
    "../../Sources/ChronoCore/Remote/RemoteProtocol.swift",
]

# Cannot be generated from build settings: INFOPLIST_KEY_* covers a fixed list of top-level
# keys, and NSExtensionPointIdentifier is nested inside NSExtension. Verified against Xcode's
# CoreBuildSystem.xcspec, which lists NSSupportsLiveActivities but not this.
WIDGET_INFO_PLIST = f"{WIDGET_NAME}/Info.plist"


def oid(*parts: str) -> str:
    """Stable 24-character hex id derived from a name."""
    digest = hashlib.md5("::".join(parts).encode()).hexdigest().upper()
    return digest[:24]


def main() -> None:
    XCODEPROJ.mkdir(parents=True, exist_ok=True)
    write_local_xcconfig()

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

    widget_target_id = oid("target", "widget")
    widget_product_id = oid("product", "widget")
    widget_group = oid("group", "widget")
    widget_sources_phase = oid("phase", "widget", "sources")
    widget_frameworks_phase = oid("phase", "widget", "frameworks")
    widget_config_list = oid("configlist", "widget")
    embed_phase = oid("phase", "embed")
    embed_build_file = oid("buildfile", "embed", WIDGET_NAME)
    widget_dependency = oid("dependency", "widget")
    widget_proxy = oid("proxy", "widget")

    all_sources = APP_SOURCES + SHARED_SOURCES
    widget_all_sources = WIDGET_SOURCES + WIDGET_REUSED_SOURCES

    def file_ref(path: str) -> str:
        return oid("fileref", path)

    def build_file(path: str) -> str:
        return oid("buildfile", path)

    # A PBXBuildFile is per-target, so a file compiled into both targets needs two of them
    # pointing at the same PBXFileReference. Keeping the app's ids untouched keeps the
    # regenerated project a readable diff.
    def widget_build_file(path: str) -> str:
        return oid("buildfile", "widget", path)

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
    for path in widget_all_sources:
        name = os.path.basename(path)
        add(
            f"\t\t{widget_build_file(path)} /* {name} in Sources */ = {{isa = PBXBuildFile; "
            f"fileRef = {file_ref(path)} /* {name} */; }};"
        )
    # RemoveHeadersOnCopy is what Xcode's own extension template emits; without it the copy
    # carries headers into the bundle and the app fails validation on submission.
    add(
        f"\t\t{embed_build_file} /* {WIDGET_NAME}.appex in Embed Foundation Extensions */ = "
        f"{{isa = PBXBuildFile; fileRef = {widget_product_id} /* {WIDGET_NAME}.appex */; "
        f"settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};"
    )
    add("/* End PBXBuildFile section */")

    # --- PBXContainerItemProxy ---------------------------------------------------------
    add("")
    add("/* Begin PBXContainerItemProxy section */")
    add(f"\t\t{widget_proxy} /* PBXContainerItemProxy */ = {{")
    add("\t\t\tisa = PBXContainerItemProxy;")
    add(f"\t\t\tcontainerPortal = {project_id} /* Project object */;")
    add("\t\t\tproxyType = 1;")
    add(f"\t\t\tremoteGlobalIDString = {widget_target_id};")
    add(f"\t\t\tremoteInfo = {WIDGET_NAME};")
    add("\t\t};")
    add("/* End PBXContainerItemProxy section */")

    # --- PBXCopyFilesBuildPhase --------------------------------------------------------
    # Embedding the extension in the app is what makes it ship at all; a widget target that
    # builds but is never copied into the .app produces no Live Activity and no error either.
    add("")
    add("/* Begin PBXCopyFilesBuildPhase section */")
    add(f"\t\t{embed_phase} /* Embed Foundation Extensions */ = {{")
    add("\t\t\tisa = PBXCopyFilesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tdstPath = \"\";")
    # 13 is the PlugIns directory inside the app wrapper.
    add("\t\t\tdstSubfolderSpec = 13;")
    add("\t\t\tfiles = (")
    add(f"\t\t\t\t{embed_build_file} /* {WIDGET_NAME}.appex in Embed Foundation Extensions */,")
    add("\t\t\t);")
    add("\t\t\tname = \"Embed Foundation Extensions\";")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXCopyFilesBuildPhase section */")

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
    add(
        f"\t\t{file_ref(LOCAL_XCCONFIG)} /* {LOCAL_XCCONFIG} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = text.xcconfig; path = {LOCAL_XCCONFIG}; sourceTree = \"<group>\"; }};"
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
    add(
        f"\t\t{widget_product_id} /* {WIDGET_NAME}.appex */ = {{isa = PBXFileReference; "
        f"explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; "
        f'path = "{WIDGET_NAME}.appex"; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )
    for path in WIDGET_SOURCES:
        add(
            f"\t\t{file_ref(path)} /* {path} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {path}; sourceTree = \"<group>\"; }};"
        )
    add(
        f"\t\t{file_ref(WIDGET_INFO_PLIST)} /* Info.plist */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};"
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
    add(f"\t\t{widget_frameworks_phase} /* Frameworks */ = {{")
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
    add(f"\t\t\t\t{widget_group} /* {WIDGET_NAME} */,")
    add(f"\t\t\t\t{file_ref(LOCAL_XCCONFIG)} /* {LOCAL_XCCONFIG} */,")
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

    add(f"\t\t{widget_group} /* {WIDGET_NAME} */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for path in WIDGET_SOURCES:
        add(f"\t\t\t\t{file_ref(path)} /* {path} */,")
    add(f"\t\t\t\t{file_ref(WIDGET_INFO_PLIST)} /* Info.plist */,")
    add("\t\t\t);")
    add(f"\t\t\tpath = {WIDGET_NAME};")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{products_group} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{product_id} /* {PROJECT_NAME}.app */,")
    add(f"\t\t\t\t{widget_product_id} /* {WIDGET_NAME}.appex */,")
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
    add(f"\t\t\t\t{embed_phase} /* Embed Foundation Extensions */,")
    add("\t\t\t);")
    add("\t\t\tbuildRules = (")
    add("\t\t\t);")
    add("\t\t\tdependencies = (")
    add(f"\t\t\t\t{widget_dependency} /* PBXTargetDependency */,")
    add("\t\t\t);")
    add(f"\t\t\tname = {PROJECT_NAME};")
    add(f"\t\t\tproductName = {PROJECT_NAME};")
    add(f"\t\t\tproductReference = {product_id} /* {PROJECT_NAME}.app */;")
    add("\t\t\tproductType = \"com.apple.product-type.application\";")
    add("\t\t};")

    add(f"\t\t{widget_target_id} /* {WIDGET_NAME} */ = {{")
    add("\t\t\tisa = PBXNativeTarget;")
    add(f"\t\t\tbuildConfigurationList = {widget_config_list} /* Build configuration list */;")
    add("\t\t\tbuildPhases = (")
    add(f"\t\t\t\t{widget_sources_phase} /* Sources */,")
    add(f"\t\t\t\t{widget_frameworks_phase} /* Frameworks */,")
    add("\t\t\t);")
    add("\t\t\tbuildRules = (")
    add("\t\t\t);")
    add("\t\t\tdependencies = (")
    add("\t\t\t);")
    add(f"\t\t\tname = {WIDGET_NAME};")
    add(f"\t\t\tproductName = {WIDGET_NAME};")
    add(f"\t\t\tproductReference = {widget_product_id} /* {WIDGET_NAME}.appex */;")
    add("\t\t\tproductType = \"com.apple.product-type.app-extension\";")
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
    add(f"\t\t\t\t\t{widget_target_id} = {{")
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
    add(f"\t\t\t\t{widget_target_id} /* {WIDGET_NAME} */,")
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
    add(f"\t\t{widget_sources_phase} /* Sources */ = {{")
    add("\t\t\tisa = PBXSourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for path in widget_all_sources:
        add(f"\t\t\t\t{widget_build_file(path)} /* {os.path.basename(path)} in Sources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXSourcesBuildPhase section */")

    # --- PBXTargetDependency -----------------------------------------------------------
    add("")
    add("/* Begin PBXTargetDependency section */")
    add(f"\t\t{widget_dependency} /* PBXTargetDependency */ = {{")
    add("\t\t\tisa = PBXTargetDependency;")
    add(f"\t\t\ttarget = {widget_target_id} /* {WIDGET_NAME} */;")
    add(f"\t\t\ttargetProxy = {widget_proxy} /* PBXContainerItemProxy */;")
    add("\t\t};")
    add("/* End PBXTargetDependency section */")

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
        "INFOPLIST_KEY_NSSupportsLiveActivities = YES",
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

    widget_settings = [
        "CODE_SIGN_STYLE = Automatic",
        "CURRENT_PROJECT_VERSION = 1",
        "ENABLE_PREVIEWS = YES",
        # Both: the generated plist supplies the ordinary keys, this file supplies the nested
        # NSExtension dictionary that no build setting can express. Xcode merges them.
        "GENERATE_INFOPLIST_FILE = YES",
        f"INFOPLIST_FILE = {WIDGET_INFO_PLIST}",
        "INFOPLIST_KEY_CFBundleDisplayName = Chrono",
        # An extension is loaded from inside the host app, so it looks two directories further
        # up for shared frameworks than the app does.
        "LD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/Frameworks\", \"@executable_path/../../Frameworks\")",
        "MARKETING_VERSION = 1.0",
        f"PRODUCT_BUNDLE_IDENTIFIER = {WIDGET_BUNDLE_ID}",
        "PRODUCT_NAME = \"$(TARGET_NAME)\"",
        # The extension ships inside the app rather than being installed in its own right.
        "SKIP_INSTALL = YES",
        "SWIFT_EMIT_LOC_STRINGS = YES",
    ]

    def configuration(
        config_id: str,
        name: str,
        settings: list[str],
        debug: bool,
        useLocalConfig: bool = False,
    ) -> None:
        add(f"\t\t{config_id} /* {name} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        # Only the targets, not the project: a base configuration set at both levels is
        # inherited twice, and the target's would win anyway.
        if useLocalConfig:
            add(
                f"\t\t\tbaseConfigurationReference = {file_ref(LOCAL_XCCONFIG)} "
                f"/* {LOCAL_XCCONFIG} */;"
            )
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
    configuration(oid("config", "target", "Debug"), "Debug", target_settings, True, True)
    configuration(oid("config", "target", "Release"), "Release", target_settings, False, True)
    configuration(oid("config", "widget", "Debug"), "Debug", widget_settings, True, True)
    configuration(oid("config", "widget", "Release"), "Release", widget_settings, False, True)
    add("/* End XCBuildConfiguration section */")

    # --- XCConfigurationList -----------------------------------------------------------
    add("")
    add("/* Begin XCConfigurationList section */")
    for list_id, kind in (
        (project_config_list, "project"),
        (target_config_list, "target"),
        (widget_config_list, "widget"),
    ):
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
