#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Get the module type from command line argument
MODULE_TYPE=${1:-agent}  # Default to 'agent' if no argument provided

if [[ "$MODULE_TYPE" != "agent" && "$MODULE_TYPE" != "native" ]]; then
    echo "Usage: $0 [agent|native]"
    echo "  agent: Publish ft_sdk.har and ft_sdk_ext.har (default)"
    echo "  native: Publish ft_native.har"
    exit 1
fi

echo "Publishing module type: $MODULE_TYPE"

# =====Test  Envs=====
#HARMONY_OS_NODE_PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin/node"
#HARMONY_OS_HVIGOR_PATH="/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js"
#OSS_BASE_PATH="base"
#export DEVECO_SDK_HOME=""

# Define modules based on module type
if [ "$MODULE_TYPE" == "agent" ]; then
    # Agent modules are published together, and ft_sdk_ext depends on ft_sdk.
    MODULE_NAMES=("ft_sdk" "ft_sdk_ext")
elif [ "$MODULE_TYPE" == "native" ]; then
    # Native module (ft_native)
    MODULE_NAMES=("ft_native")
fi
OSS_UTIL_PATH=~/ossutilmac64
FT_SDK_EXT_DEPENDENCY_HAR_PATH="ft_sdk_ext/ft_sdk.har"

# Check required environment variables
if [ -z "$HARMONY_OS_NODE_PATH" ]; then
    echo "Error: HARMONY_OS_NODE_PATH environment variable is not set"
    exit 1
fi

if [ -z "$HARMONY_OS_HVIGOR_PATH" ]; then
    echo "Error: HARMONY_OS_HVIGOR_PATH environment variable is not set"
    exit 1
fi

if [ -z "$OSS_BASE_PATH" ]; then
    echo "Error: OSS_BASE_PATH environment variable is not set"
    exit 1
fi

for MODULE_NAME in "${MODULE_NAMES[@]}"; do
    PACKAGE_JSON_PATH="$MODULE_NAME/oh-package.json5"
    HAR_SOURCE_PATH="$MODULE_NAME/build/default/outputs/default/$MODULE_NAME.har"
    BUILD_MODULE="$MODULE_NAME@default"

    # Step 1: Build HAR package
    echo "Building HAR package for $MODULE_NAME..."
    $HARMONY_OS_NODE_PATH $HARMONY_OS_HVIGOR_PATH --mode module -p product=default -p module=$BUILD_MODULE clean --analyze=normal
    $HARMONY_OS_NODE_PATH $HARMONY_OS_HVIGOR_PATH --mode module -p product=default -p module=$BUILD_MODULE assembleHar --analyze=normal --parallel

    # Check if HAR package was built successfully
    if [ ! -f "$HAR_SOURCE_PATH" ]; then
        echo "Error: HAR package not found at $HAR_SOURCE_PATH"
        exit 1
    fi

    echo "HAR package built successfully: $HAR_SOURCE_PATH"

    if [ "$MODULE_NAME" == "ft_sdk" ] && [ "$MODULE_TYPE" == "agent" ]; then
        echo "Syncing $HAR_SOURCE_PATH to $FT_SDK_EXT_DEPENDENCY_HAR_PATH for ft_sdk_ext build..."
        cp -f "$HAR_SOURCE_PATH" "$FT_SDK_EXT_DEPENDENCY_HAR_PATH"

        if [ $? -ne 0 ]; then
            echo "Error: Failed to sync ft_sdk HAR to $FT_SDK_EXT_DEPENDENCY_HAR_PATH"
            exit 1
        fi

        echo "Synced successfully: $FT_SDK_EXT_DEPENDENCY_HAR_PATH"
    fi

    # Step 2: Extract version number from oh-package.json5
    if [ ! -f "$PACKAGE_JSON_PATH" ]; then
        echo "Error: Package JSON file not found at $PACKAGE_JSON_PATH"
        exit 1
    fi

    # oh-package.json5 is JSON5, so avoid jq and extract the version directly.
    VERSION=$(grep -E '^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$PACKAGE_JSON_PATH" | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -n 1)

    if [ -z "$VERSION" ]; then
        echo "Error: Failed to extract version from $PACKAGE_JSON_PATH"
        exit 1
    fi

    echo "Extracted version for $MODULE_NAME: $VERSION"

    OSS_TARGET_PATH="${OSS_BASE_PATH}/ft-sdk-package/harmony_os_sdk_har/$MODULE_NAME/${VERSION}/$MODULE_NAME.har"

    echo "Uploading to OSS: $OSS_TARGET_PATH"
    $OSS_UTIL_PATH cp -f "$HAR_SOURCE_PATH" "$OSS_TARGET_PATH"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to upload to OSS target path"
        exit 1
    fi

    echo "Uploaded successfully to: $OSS_TARGET_PATH"

    OSS_TARGET_LATEST_PATH="${OSS_BASE_PATH}/ft-sdk-package/harmony_os_sdk_har/latest/$MODULE_NAME.har"

    echo "Copying to latest directory: $OSS_TARGET_LATEST_PATH"
    $OSS_UTIL_PATH cp -f "$OSS_TARGET_PATH" "$OSS_TARGET_LATEST_PATH"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to copy to latest directory"
        exit 1
    fi

    echo "Copied successfully to: $OSS_TARGET_LATEST_PATH"
done

echo "Publish completed successfully for $MODULE_TYPE module!"
