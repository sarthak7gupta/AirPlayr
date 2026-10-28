#!/usr/bin/env python3.14
"""Dependency-free, deterministic Xcode project generation."""
from pathlib import Path
import hashlib, json
root = Path(__file__).resolve().parent.parent
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(name, text): objects[uid(name)] = text; return uid(name)
def q(s): return json.dumps(str(s))
def array(ids): return '(' + ', '.join(ids) + (',)' if ids else ')')
def settings(name, values): return add(name, 'isa = XCBuildConfiguration; name = '+name.split(':')[-1]+'; buildSettings = {'+' '.join(k+' = '+q(v)+';' for k,v in values.items())+'};')
def configs(name, values):
    ids=[]
    for mode in ['Debug','Release']:
        v=dict(values)
        if mode == 'Release': v['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] = 'NO'
        v.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf','ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO'})
        ids.append(settings(name+':'+mode,v))
    return add(name+'Configs','isa = XCConfigurationList; buildConfigurations = '+array(ids)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
products=[]
for name,typ in [('AirPlayr.app','wrapper.application'),('AirPlayrTests.xctest','wrapper.cfbundle')]:
    products.append(add(name,'isa = PBXFileReference; explicitFileType = '+typ+'; path = '+q(name)+'; sourceTree = BUILT_PRODUCTS_DIR;'))
groups=[]; phases=[]
for folder in ['AirPlayr','AirPlayrTests']:
    refs=[]; builds=[]
    for path in sorted((root/folder).rglob('*.swift')):
        rel=str(path.relative_to(root)); ref=add(rel,'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = '+q(rel)+'; sourceTree = SOURCE_ROOT;'); refs.append(ref)
        builds.append(add('build:'+rel,'isa = PBXBuildFile; fileRef = '+ref+';'))
    groups.append(add('group:'+folder,'isa = PBXGroup; name = '+folder+'; children = '+array(refs)+'; sourceTree = "<group>";'))
    phases.append(add('sources:'+folder,'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+array(builds)+'; runOnlyForDeploymentPostprocessing = 0;'))
# Tests only read repository fixtures; no optional files from Downloads/build paths.
fixtureBuilds = []
mediaExtensions = {'.mp4', '.mkv', '.mov', '.m4v', '.mp3', '.m4a', '.aac', '.wav', '.aiff', '.aif', '.caf', '.flac'}
for path in sorted((root/'AirPlayrTests/Fixtures').rglob('*')):
    if path.suffix.lower() not in mediaExtensions: continue
    rel = str(path.relative_to(root))
    ref = add('fixture:'+rel, 'isa = PBXFileReference; lastKnownFileType = file; path = '+q(rel)+'; sourceTree = SOURCE_ROOT;')
    fixtureBuilds.append(add('fixtureBuild:'+rel, 'isa = PBXBuildFile; fileRef = '+ref+';'))
resourcePhase=add('testResources','isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+array(fixtureBuilds)+'; runOnlyForDeploymentPostprocessing = 0;')
privacy=add('privacy','isa = PBXFileReference; lastKnownFileType = text.xml; path = "AirPlayr/Resources/PrivacyInfo.xcprivacy"; sourceTree = SOURCE_ROOT;')
privacyBuild=add('privacyBuild','isa = PBXBuildFile; fileRef = '+privacy+';')
assets=add('assets','isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "AirPlayr/Resources/Assets.xcassets"; sourceTree = SOURCE_ROOT;')
assetsBuild=add('assetsBuild','isa = PBXBuildFile; fileRef = '+assets+';')
icon=add('icon','isa = PBXFileReference; lastKnownFileType = image.icns; path = \"AirPlayr/Resources/AirPlayrIcon.icns\"; sourceTree = SOURCE_ROOT;')
iconBuild=add('iconBuild','isa = PBXBuildFile; fileRef = '+icon+';')
branding=add('branding','isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "AirPlayr/Resources/Branding.xcassets"; sourceTree = SOURCE_ROOT;')
brandingBuild=add('brandingBuild','isa = PBXBuildFile; fileRef = '+branding+';')
appResources=add('appResources','isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+array([privacyBuild,iconBuild,brandingBuild])+'; runOnlyForDeploymentPostprocessing = 0;')
pg=add('products'  ,'isa = PBXGroup; name = Products; children = '+array(products)+'; sourceTree = "<group>";')
main=add('main','isa = PBXGroup; children = '+array(groups+[assets,branding,pg])+'; sourceTree = "<group>";')
base={'MACOSX_DEPLOYMENT_TARGET':'14.0','SDKROOT':'macosx','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','SWIFT_STRICT_CONCURRENCY':'targeted','CODE_SIGN_STYLE':'Automatic','CODE_SIGN_IDENTITY':'-'}
projectcfg=configs('project',base)
appcfg=configs('app',{'PRODUCT_BUNDLE_IDENTIFIER':'com.airplayr.app','PRODUCT_NAME':'AirPlayr','INFOPLIST_FILE':'AirPlayr/Resources/Info.plist','CODE_SIGN_ENTITLEMENTS':'AirPlayr/Resources/AirPlayr.entitlements','ENABLE_APP_SANDBOX':'YES','ENABLE_HARDENED_RUNTIME':'YES','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'})
testcfg=configs('tests',{'PRODUCT_BUNDLE_IDENTIFIER':'com.airplayr.tests','PRODUCT_NAME':'AirPlayrTests','GENERATE_INFOPLIST_FILE':'YES','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/AirPlayr.app/Contents/MacOS/AirPlayr','BUNDLE_LOADER':'$(TEST_HOST)','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks'})
helperPhase=add('mediaToolsPhase','isa = PBXShellScriptBuildPhase; name = "Embed and sign MKV helpers"; buildActionMask = 2147483647; files = (); inputPaths = '+array([q('$(SRCROOT)/Vendor/FFmpeg/bin/ffmpeg'), q('$(SRCROOT)/Vendor/FFmpeg/bin/ffprobe'), q('$(SRCROOT)/scripts/embed-media-tools.sh'), q('$(SRCROOT)/AirPlayr/Resources/MediaTool.entitlements'), q('$(SRCROOT)/Vendor/FFmpeg/Licenses/NOTICE.txt'), q('$(SRCROOT)/Vendor/FFmpeg/Licenses/LICENSE.md'), q('$(SRCROOT)/Vendor/FFmpeg/Licenses/COPYING.LGPLv2.1')])+'; outputPaths = '+array([q('$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/ffmpeg'),q('$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/ffprobe'), q('$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/FFmpegLicenses/COPYING.LGPLv2.1')])+'; shellPath = /bin/bash; shellScript = '+q('/bin/bash "$SRCROOT/scripts/embed-media-tools.sh"')+'; runOnlyForDeploymentPostprocessing = 0;')
app=add('app','isa = PBXNativeTarget; name = AirPlayr; productName = AirPlayr; productType = "com.apple.product-type.application"; productReference = '+products[0]+'; buildConfigurationList = '+appcfg+'; buildPhases = '+array([phases[0],appResources,helperPhase])+'; buildRules = (); dependencies = ();')
proxy=add('proxy','isa = PBXContainerItemProxy; containerPortal = '+uid('project')+'; proxyType = 1; remoteGlobalIDString = '+app+'; remoteInfo = AirPlayr;')
dep=add('dep','isa = PBXTargetDependency; target = '+app+'; targetProxy = '+proxy+';')
test=add('tests','isa = PBXNativeTarget; name = AirPlayrTests; productName = AirPlayrTests; productType = "com.apple.product-type.bundle.unit-test"; productReference = '+products[1]+'; buildConfigurationList = '+testcfg+'; buildPhases = '+array([phases[1],resourcePhase])+'; buildRules = (); dependencies = '+array([dep])+';')
add('project','isa = PBXProject; buildConfigurationList = '+projectcfg+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = '+main+'; productRefGroup = '+pg+'; projectDirPath = ""; projectRoot = ""; targets = '+array([app,test])+';')
p=root/'AirPlayr.xcodeproj';p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(k+' = {'+v+'};' for k,v in objects.items())+'\n}; rootObject = '+uid('project')+'; }\n')
scheme=p/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
def ref(id,name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{id}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:AirPlayr.xcodeproj"/>'
(scheme/'AirPlayr.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app,'AirPlayr.app')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test,'AirPlayrTests.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app,'AirPlayr.app')}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app,'AirPlayr.app')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
