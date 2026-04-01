#include "include/FTNativeCrashHandler.h"

// Define LOG_DOMAIN before including hilog/log.h to use custom domain
#define LOG_DOMAIN 0x0001
#define LOG_TAG "[FT-SDK-NATIVE]FTNativeCrashNAPI"

#include <napi/native_api.h>
#include <hilog/log.h>
#include <memory>
#include <string>

namespace ftstatsd {

// Global reference to the crash callback function in JavaScript
static napi_ref g_crashCallbackRef = nullptr;
static napi_threadsafe_function g_threadSafeFunction = nullptr;

// Data structure for passing crash data to JavaScript
struct CrashDataWrapper {
    NativeCrashData crashData;
};

// Thread-safe function call to JavaScript
static void CallJs(napi_env env, napi_value jsCallback, void* context, void* data) {
    OH_LOG_INFO(LogType::LOG_APP,  "<FT-NATIVE-NAPI-CALLJS> *** CallJs CALLBACK INVOKED ***");

    if (env == nullptr) {
        OH_LOG_ERROR(LogType::LOG_APP,  "<FT-NATIVE-NAPI-CALLJS> *** env is NULL ***");
        return;
    }

    if (jsCallback == nullptr) {
        OH_LOG_ERROR(LogType::LOG_APP,  "<FT-NATIVE-NAPI-CALLJS> *** jsCallback is NULL ***");
        return;
    }

    if (data == nullptr) {
        OH_LOG_ERROR(LogType::LOG_APP,  "<FT-NATIVE-NAPI-CALLJS> *** data is NULL ***");
        return;
    }

    OH_LOG_INFO(LogType::LOG_APP,  "<FT-NATIVE-NAPI-CALLJS> All parameters valid, creating crash object...");

    CrashDataWrapper* crashDataWrapper = static_cast<CrashDataWrapper*>(data);

    napi_value undefined;
    napi_get_undefined(env, &undefined);

    // Create JavaScript object with crash data
    napi_value crashObj;
    napi_create_object(env, &crashObj);

    // Set timestamp
    napi_value timestampValue;
    napi_create_int64(env, crashDataWrapper->crashData.timestamp, &timestampValue);
    napi_set_named_property(env, crashObj, "timestamp", timestampValue);

    // Set crashType
    napi_value crashTypeValue;
    napi_create_string_utf8(env,
                           crashDataWrapper->crashData.crashType.c_str(),
                           crashDataWrapper->crashData.crashType.length(),
                           &crashTypeValue);
    napi_set_named_property(env, crashObj, "crashType", crashTypeValue);

    // Set foreground
    napi_value foregroundValue;
    napi_get_boolean(env, crashDataWrapper->crashData.foreground, &foregroundValue);
    napi_set_named_property(env, crashObj, "foreground", foregroundValue);

    // Set bundleVersion
    napi_value bundleVersionValue;
    napi_create_string_utf8(env,
                           crashDataWrapper->crashData.bundleVersion.c_str(),
                           crashDataWrapper->crashData.bundleVersion.length(),
                           &bundleVersionValue);
    napi_set_named_property(env, crashObj, "bundleVersion", bundleVersionValue);

    // Set bundleName
    napi_value bundleNameValue;
    napi_create_string_utf8(env,
                           crashDataWrapper->crashData.bundleName.c_str(),
                           crashDataWrapper->crashData.bundleName.length(),
                           &bundleNameValue);
    napi_set_named_property(env, crashObj, "bundleName", bundleNameValue);

    // Set pid
    napi_value pidValue;
    napi_create_int32(env, crashDataWrapper->crashData.pid, &pidValue);
    napi_set_named_property(env, crashObj, "pid", pidValue);

    // Set uid
    napi_value uidValue;
    napi_create_int32(env, crashDataWrapper->crashData.uid, &uidValue);
    napi_set_named_property(env, crashObj, "uid", uidValue);

    // Set uuid
    napi_value uuidValue;
    napi_create_string_utf8(env,
                           crashDataWrapper->crashData.uuid.c_str(),
                           crashDataWrapper->crashData.uuid.length(),
                           &uuidValue);
    napi_set_named_property(env, crashObj, "uuid", uuidValue);

    // Set exception (JSON string)
    napi_value exceptionValue;
    napi_create_string_utf8(env,
                           crashDataWrapper->crashData.exception.c_str(),
                           crashDataWrapper->crashData.exception.length(),
                           &exceptionValue);
    napi_set_named_property(env, crashObj, "exception", exceptionValue);

    // Set hilogSize
    napi_value hilogSizeValue;
    napi_create_int32(env, crashDataWrapper->crashData.hilogSize, &hilogSizeValue);
    napi_set_named_property(env, crashObj, "hilogSize", hilogSizeValue);

    // Set externalLog
    napi_value externalLogValue;
    napi_create_string_utf8(env,
                           crashDataWrapper->crashData.externalLog.c_str(),
                           crashDataWrapper->crashData.externalLog.length(),
                           &externalLogValue);
    napi_set_named_property(env, crashObj, "externalLog", externalLogValue);

    // Set logOverLimit
    napi_value logOverLimitValue;
    napi_get_boolean(env, crashDataWrapper->crashData.logOverLimit, &logOverLimitValue);
    napi_set_named_property(env, crashObj, "logOverLimit", logOverLimitValue);

    // Set memoryNearRegisters
    napi_value memoryNearRegistersValue;
    napi_create_string_utf8(env,
                           crashDataWrapper->crashData.memoryNearRegisters.c_str(),
                           crashDataWrapper->crashData.memoryNearRegisters.length(),
                           &memoryNearRegistersValue);
    napi_set_named_property(env, crashObj, "memoryNearRegisters", memoryNearRegistersValue);

    // Set maps
    napi_value mapsValue;
    napi_create_string_utf8(env,
                           crashDataWrapper->crashData.maps.c_str(),
                           crashDataWrapper->crashData.maps.length(),
                           &mapsValue);
    napi_set_named_property(env, crashObj, "maps", mapsValue);

    // Set hilog
    napi_value hilogValue;
    napi_create_string_utf8(env,
                           crashDataWrapper->crashData.hilog.c_str(),
                           crashDataWrapper->crashData.hilog.length(),
                           &hilogValue);
    napi_set_named_property(env, crashObj, "hilog", hilogValue);

    OH_LOG_INFO(LogType::LOG_APP,  "<FT-NATIVE-NAPI-CALLJS> Crash object created, calling JavaScript callback...");

    // Call JavaScript callback
    napi_value argv[] = {crashObj};
    napi_status callStatus = napi_call_function(env, undefined, jsCallback, 1, argv, nullptr);

    if (callStatus == napi_ok) {
        OH_LOG_INFO(LogType::LOG_APP,  "<FT-NATIVE-NAPI-CALLJS> *** JavaScript callback called SUCCESSFULLY ***");
    } else {
        OH_LOG_ERROR(LogType::LOG_APP,  "<FT-NATIVE-NAPI-CALLJS> *** JavaScript callback call FAILED: %{public}d ***", callStatus);
    }

    // Clean up
    delete crashDataWrapper;

    OH_LOG_INFO(LogType::LOG_APP,  "<FT-NATIVE-NAPI-CALLJS> *** CallJs COMPLETED ***");
}

// Finalizer for thread-safe function
static void FinalizeJs(napi_env env, void* data, void* hint) {
    if (g_crashCallbackRef != nullptr) {
        napi_delete_reference(env, g_crashCallbackRef);
        g_crashCallbackRef = nullptr;
    }
}

// Crash event callback implementation
class CrashCallbackImpl : public NativeCrashCallback {
public:
    void onNativeCrash(const NativeCrashData& crashData) override {
        OH_LOG_INFO(LogType::LOG_APP, 
                   "<FT-NAPI-CALLBACK> CrashCallbackImpl::onNativeCrash called, crashType=%{public}s",
                   crashData.crashType.c_str());

        if (g_threadSafeFunction == nullptr) {
            OH_LOG_ERROR(LogType::LOG_APP,  "<FT-NAPI-CALLBACK> *** g_threadSafeFunction is NULL ***");
            return;
        }

        OH_LOG_INFO(LogType::LOG_APP,  "<FT-NAPI-CALLBACK> Thread-safe function is valid, calling napi_call_threadsafe_function...");

        CrashDataWrapper* wrapper = new CrashDataWrapper();
        wrapper->crashData = crashData;

        napi_status status = napi_call_threadsafe_function(
            g_threadSafeFunction,
            wrapper,
            napi_tsfn_nonblocking
        );

        if (status == napi_ok) {
            OH_LOG_INFO(LogType::LOG_APP,  "<FT-NAPI-CALLBACK> *** napi_call_threadsafe_function SUCCESS ***");
        } else {
            OH_LOG_ERROR(LogType::LOG_APP,  "<FT-NAPI-CALLBACK> *** napi_call_threadsafe_function FAILED: %{public}d ***", status);
            delete wrapper;
        }
    }
};

// NAPI: Initialize native crash handler
static napi_value InitNativeCrashHandler(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LogType::LOG_APP,  "InitNativeCrashHandler called");

    auto& handler = FTNativeCrashHandler::getInstance();
    bool success = handler.initialize(env);

    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

// NAPI: Set crash callback from JavaScript
static napi_value SetCrashCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value thisArg;

    if (napi_get_cb_info(env, info, &argc, argv, &thisArg, nullptr) != napi_ok) {
        OH_LOG_ERROR(LogType::LOG_APP,  "Failed to get callback info");
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    if (argc < 1) {
        OH_LOG_ERROR(LogType::LOG_APP,  "Missing callback argument");
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    // Create thread-safe function
    napi_value resourceName;
    napi_create_string_utf8(env, "FTCrashCallback", NAPI_AUTO_LENGTH, &resourceName);

    napi_value asyncResourceName;
    napi_create_string_utf8(env, "FTCrashCallbackResource", NAPI_AUTO_LENGTH, &asyncResourceName);

    if (g_threadSafeFunction != nullptr) {
        OH_LOG_INFO(LogType::LOG_APP,  "Releasing existing thread-safe function");
        napi_release_threadsafe_function(g_threadSafeFunction, napi_tsfn_release);
        g_threadSafeFunction = nullptr;
    }

    OH_LOG_INFO(LogType::LOG_APP,  "Creating thread-safe function...");

    napi_status status = napi_create_threadsafe_function(
        env,
        argv[0],  // JavaScript callback function
        nullptr,  // async resource
        asyncResourceName,
        0,        // max queue size (0 = unlimited)
        1,        // initial thread count
        nullptr,  // thread finalize data
        FinalizeJs,  // thread finalize callback
        nullptr,  // context
        CallJs,   // call JS callback
        &g_threadSafeFunction
    );

    if (status != napi_ok) {
        OH_LOG_ERROR(LogType::LOG_APP,  "Failed to create thread-safe function: %{public}d", status);
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    OH_LOG_INFO(LogType::LOG_APP,  "Thread-safe function created successfully");
    OH_LOG_INFO(LogType::LOG_APP,  "g_threadSafeFunction pointer: %{public}p", g_threadSafeFunction);

    // Set the callback in C++ handler
    auto callbackImpl = std::make_shared<CrashCallbackImpl>();
    FTNativeCrashHandler::getInstance().setCrashCallback(callbackImpl);

    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

// NAPI: Start watching crash events
static napi_value StartWatching(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LogType::LOG_APP,  "StartWatching called");

    auto& handler = FTNativeCrashHandler::getInstance();
    bool success = handler.startWatching();

    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

// NAPI: Stop watching crash events
static napi_value StopWatching(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LogType::LOG_APP,  "StopWatching called");

    auto& handler = FTNativeCrashHandler::getInstance();
    handler.stopWatching();

    if (g_threadSafeFunction != nullptr) {
        napi_release_threadsafe_function(g_threadSafeFunction, napi_tsfn_release);
        g_threadSafeFunction = nullptr;
    }

    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

// NAPI: Add a log entry to the runtime log buffer
static napi_value AddLog(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_value thisArg;

    if (napi_get_cb_info(env, info, &argc, argv, &thisArg, nullptr) != napi_ok) {
        OH_LOG_ERROR(LogType::LOG_APP,  "Failed to get callback info for AddLog");
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    if (argc < 3) {
        OH_LOG_ERROR(LogType::LOG_APP,  "AddLog requires 3 arguments: level, tag, message");
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    // Get level
    size_t levelLen = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &levelLen);
    std::string level(levelLen + 1, '\0');
    napi_get_value_string_utf8(env, argv[0], &level[0], levelLen + 1, &levelLen);

    // Get tag
    size_t tagLen = 0;
    napi_get_value_string_utf8(env, argv[1], nullptr, 0, &tagLen);
    std::string tag(tagLen + 1, '\0');
    napi_get_value_string_utf8(env, argv[1], &tag[0], tagLen + 1, &tagLen);

    // Get message
    size_t msgLen = 0;
    napi_get_value_string_utf8(env, argv[2], nullptr, 0, &msgLen);
    std::string message(msgLen + 1, '\0');
    napi_get_value_string_utf8(env, argv[2], &message[0], msgLen + 1, &msgLen);

    FTNativeCrashHandler::addLog(level.c_str(), tag.c_str(), message.c_str());

    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

// NAPI: Get collected runtime logs
static napi_value GetCollectedLogs(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value thisArg;

    if (napi_get_cb_info(env, info, &argc, argv, &thisArg, nullptr) != napi_ok) {
        argc = 0;
    }

    int maxLines = 0;
    if (argc >= 1) {
        napi_valuetype type;
        if (napi_typeof(env, argv[0], &type) == napi_ok && type == napi_number) {
            double val;
            if (napi_get_value_double(env, argv[0], &val) == napi_ok) {
                maxLines = static_cast<int>(val);
            }
        }
    }

    std::string logs = FTNativeCrashHandler::getCollectedLogs(maxLines);
    napi_value result;
    napi_create_string_utf8(env, logs.c_str(), logs.length(), &result);
    return result;
}

// NAPI: Clear collected logs
static napi_value ClearLogs(napi_env env, napi_callback_info info) {
    FTNativeCrashHandler::clearLogs();

    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

// NAPI: Set maximum log buffer size
static napi_value SetMaxLogSize(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value thisArg;

    if (napi_get_cb_info(env, info, &argc, argv, &thisArg, nullptr) != napi_ok || argc < 1) {
        OH_LOG_ERROR(LogType::LOG_APP,  "SetMaxLogSize requires 1 argument: maxSize");
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    double val = 0;
    if (napi_get_value_double(env, argv[0], &val) == napi_ok) {
        FTNativeCrashHandler::setMaxLogSize(static_cast<size_t>(val));

        napi_value result;
        napi_get_boolean(env, true, &result);
        return result;
    }

    napi_value result;
    napi_get_boolean(env, false, &result);
    return result;
}

// NAPI: Get native crash handler version
static napi_value GetVersion(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LogType::LOG_APP,  "GetVersion called");

    std::string version = FTNativeCrashHandler::getVersion();

    napi_value result;
    napi_create_string_utf8(env, version.c_str(), version.length(), &result);
    return result;
}

// Module initialization
EXTERN_C_START

static napi_value Init(napi_env env, napi_value exports) {
    OH_LOG_INFO(LogType::LOG_APP,  "Initializing FT Native Crash NAPI module");

    napi_property_descriptor desc[] = {
        {"initNativeCrashHandler", nullptr, InitNativeCrashHandler, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCrashCallback", nullptr, SetCrashCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startWatching", nullptr, StartWatching, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopWatching", nullptr, StopWatching, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"addLog", nullptr, AddLog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCollectedLogs", nullptr, GetCollectedLogs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearLogs", nullptr, ClearLogs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMaxLogSize", nullptr, SetMaxLogSize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getVersion", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

EXTERN_C_END

// Module registration
static napi_module ftNativeCrashModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "ftnativecrash",
    .nm_priv = ((void*)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterFTNativeCrashModule(void) {
    OH_LOG_INFO(LogType::LOG_APP,  "Registering FT Native Crash module");
    napi_module_register(&ftNativeCrashModule);
}

} // namespace ftstatsd
