#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Get the module type from command line argument
MODULE_TYPE=${1:-agent}  # Default to 'agent' if no argument provided

if [[ "$MODULE_TYPE" != "agent" && "$MODULE_TYPE" != "native" ]]; then
    echo "Usage: $0 [agent|native]"
    echo "  agent: Publish ft_sdk.har (default)"
    echo "  native: Publish ft_native.har"
    exit 1
fi

echo "Publishing module type: $MODULE_TYPE"

# =====Test  Envs=====
#HARMONY_OS_NODE_PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin/node"
#HARMONY_OS_HVIGOR_PATH="/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js"
#OSS_BASE_PATH="base"
#export DEVECO_SDK_HOME=""

# Define paths based on module type
if [ "$MODULE_TYPE" == "agent" ]; then
    # Agent module (ft_sdk)
    MODULE_NAME="ft_sdk"
elif [ "$MODULE_TYPE" == "native" ]; then
    # Native module (ft_native)
    MODULE_NAME="ft_native"
fi

PACKAGE_JSON_PATH="$MODULE_NAME/oh-package.json5"
HAR_SOURCE_PATH="$MODULE_NAME/build/default/outputs/default/$MODULE_NAME.har"
BUILD_MODULE="$MODULE_NAME@default"
OSS_UTIL_PATH=~/ossutilmac64

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

# Step 1: Build HAR package
echo "Building HAR package for $MODULE_TYPE module..."
$HARMONY_OS_NODE_PATH $HARMONY_OS_HVIGOR_PATH --mode module -p product=default -p module=$BUILD_MODULE assembleHar --analyze=normal --parallel --incremental --daemon

# Check if HAR package was built successfully
if [ ! -f "$HAR_SOURCE_PATH" ]; then
    echo "Error: HAR package not found at $HAR_SOURCE_PATH"
    exit 1
fi

echo "HAR package built successfully: $HAR_SOURCE_PATH"

# Step 2: Extract version number from oh-package.json5
if [ ! -f "$PACKAGE_JSON_PATH" ]; then
    echo "Error: Package JSON file not found at $PACKAGE_JSON_PATH"
    exit 1
fi

# Extract version number (using grep and sed or jq)
# Use jq if available, otherwise fallback to grep/sed
if command -v jq &> /dev/null; then
    VERSION=$(jq -r '.version' "$PACKAGE_JSON_PATH")
else
    # If jq is not available, use grep and sed to extract
    VERSION=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PACKAGE_JSON_PATH" | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
fi

if [ -z "$VERSION" ]; then
    echo "Error: Failed to extract version from $PACKAGE_JSON_PATH"
    exit 1
fi

echo "Extracted version: $VERSION"

# HAR package filename based on module type
HARMONY_HAR_PACKAGE="$MODULE_NAME.har"
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
echo "Publish completed successfully for $MODULE_TYPE module!"

