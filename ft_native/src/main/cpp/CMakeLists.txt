# CMakeLists.txt for FT Native Crash Handler

cmake_minimum_required(VERSION 3.4.1)
project(FTNativeCrash)

# Set NDK API level
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Get NDK native path
if(DEFINED OH_SDK_NATIVE_PATH)
    set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
else()
    set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
endif()

# Add source files
set(SOURCE_LIST
    ft_native_crash_napi.cpp
    src/FTNativeCrashHandler.cpp
    src/FTSignalHandler.cpp
)

# Create header include directories
include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
    ${OH_SDK_NATIVE_PATH}/include
    ${OH_SDK_NATIVE_PATH}/include/napi
)

# Define the native library
add_library(ftnativecrash SHARED ${SOURCE_LIST})

# Link libraries
target_link_libraries(ftnativecrash PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libhiappevent_ndk.z.so
)

# Set output directory
set_target_properties(ftnativecrash PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}
)

# Compiler options
target_compile_options(ftnativecrash PRIVATE
    -fPIC
    -fexceptions
    -frtti
)
