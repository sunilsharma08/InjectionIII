#!/bin/bash -x
#
#  build_bundles.sh
#  InjectionIII
#
#  Created by John Holdsworth on 04/10/2019.
#  Copyright © 2019 John Holdsworth. All rights reserved.
#
#  $Id: //depot/ResidentEval/InjectionIII/build_bundles.sh#56 $
#

# Injection has to assume a fixed path for Xcode.app as it uses
# Swift and the user's project may contain only Objective-C.
# The second "rpath" is to be able to find XCTest.framework.
FIXED_XCODE_DEVELOPER_PATH=/Applications/Xcode.app/Contents/Developer

function build_bundle () {
    FAMILY=$1
    PLATFORM=$2
    SDK=$3
    SWIFT_DYLIBS_PATH="$FIXED_XCODE_DEVELOPER_PATH/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/$SDK"
    XCTEST_FRAMEWORK_PATH="$FIXED_XCODE_DEVELOPER_PATH/Platforms/$PLATFORM.platform/Developer/Library/Frameworks"
    if [ ! -d "$SWIFT_DYLIBS_PATH" -o ! -d "${XCTEST_FRAMEWORK_PATH}/XCTest.framework" ]; then
        echo "Missing RPATH $SWIFT_DYLIBS_PATH $XCTEST_FRAMEWORK_PATH"
        exit 1
    fi
    "$DEVELOPER_BIN_DIR"/xcodebuild SYMROOT=$SYMROOT ARCHS="$ARCHS" -sdk $SDK -config $CONFIGURATION -target SwiftTrace &&
    "$DEVELOPER_BIN_DIR"/xcodebuild SYMROOT=$SYMROOT ARCHS="$ARCHS" PRODUCT_NAME="${FAMILY}Injection" LD_RUNPATH_SEARCH_PATHS="$SWIFT_DYLIBS_PATH $XCTEST_FRAMEWORK_PATH @loader_path/Frameworks" -sdk $SDK -config $CONFIGURATION -target InjectionBundle &&
    "$DEVELOPER_BIN_DIR"/xcodebuild SYMROOT=$SYMROOT ARCHS="$ARCHS" PRODUCT_NAME="${FAMILY}SwiftUISupport" -sdk $SDK -config $CONFIGURATION -target SwiftUISupport
}

#build_bundle macOS MacOSX macosx &&
build_bundle iOS iPhoneSimulator iphonesimulator &&
build_bundle tvOS AppleTVSimulator appletvsimulator &&
build_bundle maciOS iPhoneOS iphoneos &&

# macOSSwiftUISupport needs to be built separately from the main app
"$DEVELOPER_BIN_DIR"/xcodebuild SYMROOT=$SYMROOT ARCHS="$ARCHS" -sdk macosx -config $CONFIGURATION -target SwiftUISupport &&

# Copy across bundles and .swiftinterface files
rsync -au $SYMROOT/$CONFIGURATION/macOSSwiftUISupport.bundle $SYMROOT/$CONFIGURATION-*/*.bundle "$CODESIGNING_FOLDER_PATH/Contents/Resources" &&
rsync -au $SYMROOT/$CONFIGURATION/SwiftTrace.framework/{Headers,Modules,Versions} "$CODESIGNING_FOLDER_PATH/Contents/Resources/macOSInjection.bundle/Contents/Frameworks/SwiftTrace.framework" &&
rsync -au $SYMROOT/$CONFIGURATION-iphonesimulator/SwiftTrace.framework/{Headers,Modules} "$CODESIGNING_FOLDER_PATH/Contents/Resources/iOSInjection.bundle/Frameworks/SwiftTrace.framework" &&
rsync -au $SYMROOT/$CONFIGURATION-appletvsimulator/SwiftTrace.framework/{Headers,Modules} "$CODESIGNING_FOLDER_PATH/Contents/Resources/tvOSInjection.bundle/Frameworks/SwiftTrace.framework" &&
rsync -au $SYMROOT/$CONFIGURATION-iphoneos/SwiftTrace.framework/{Headers,Modules} "$CODESIGNING_FOLDER_PATH/Contents/Resources/maciOSInjection.bundle/Frameworks/SwiftTrace.framework" &&
# This seems to be a bug producing .swiftinterface files.
perl -pi.bak -e 's/SwiftTrace.(Swift(Trace|Meta)|dyld_interpose_tuple)/$1/g' $CODESIGNING_FOLDER_PATH/Contents/Resources/{macOSInjection.bundle/Contents,{i,maci,tv}OSInjection.bundle}/Frameworks/SwiftTrace.framework/Modules/*/*.swiftinterface &&
find $CODESIGNING_FOLDER_PATH/Contents/Resources/*.bundle -name '*.bak' -delete
