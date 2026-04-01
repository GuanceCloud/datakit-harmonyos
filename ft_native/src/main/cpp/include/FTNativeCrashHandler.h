#ifndef FT_NATIVE_CRASH_HANDLER_H
#define FT_NATIVE_CRASH_HANDLER_H

#include <string>
#include <vector>
#include <deque>
#include <memory>
#include <mutex>
#include <napi/native_api.h>

namespace ftstatsd {

/**
 * Log entry for runtime log collection
 */
struct LogEntry {
    std::string timestamp;
    std::string level;
    std::string tag;
    std::string message;
    std::string toString() const;
};

/**
 * Native crash data structure
 */
struct NativeCrashData {
    int64_t timestamp;
    std::string crashType;      // "JsError" or "NativeCrash"
    bool foreground;
    std::string bundleVersion;
    std::string bundleName;
    int pid;
    int uid;
    std::string uuid;
    std::string exception;      // JSON string containing exception details
    int hilogSize;
    std::string externalLog;    // JSON string containing external log paths
    bool logOverLimit;
    std::string memoryNearRegisters;  // Memory dump near registers
    std::string maps;           // Memory maps information
    std::string hilog;          // System log content
};

/**
 * Callback interface for notifying ArkTS layer about native crashes
 */
class NativeCrashCallback {
public:
    virtual ~NativeCrashCallback() = default;
    virtual void onNativeCrash(const NativeCrashData& crashData) = 0;
};

/**
 * FT Native Crash Handler
 * Uses HarmonyOS HiAppEvent NDK API to subscribe to crash events
 * Also collects runtime logs for crash reports
 */
class FTNativeCrashHandler {
public:
    static FTNativeCrashHandler& getInstance();

    /**
     * Initialize the native crash handler
     * @param env NAPI environment
     * @return true if successful, false otherwise
     */
    bool initialize(napi_env env);

    /**
     * Set the callback for crash notifications
     * @param callback Callback implementation
     */
    void setCrashCallback(std::shared_ptr<NativeCrashCallback> callback);

    /**
     * Get the crash callback
     * @return Shared pointer to the crash callback
     */
    std::shared_ptr<NativeCrashCallback> getCrashCallback() const;

    /**
     * Start watching crash events
     * @return true if successful, false otherwise
     */
    bool startWatching();

    /**
     * Stop watching crash events
     */
    void stopWatching();

    /**
     * Check if the handler is initialized
     */
    bool isInitialized() const { return initialized_; }

    /**
     * Get NAPI environment
     */
    napi_env getEnv() const { return env_; }

    /**
     * Add a log entry to the runtime log buffer
     * @param level Log level (D/I/W/E/F)
     * @param tag Log tag
     * @param message Log message
     */
    static void addLog(const char* level, const char* tag, const char* message);

    /**
     * Get the collected runtime logs as a formatted string
     * @param maxLines Maximum number of lines to retrieve (0 for all)
     * @return Formatted log string
     */
    static std::string getCollectedLogs(int maxLines = 0);

    /**
     * Clear the runtime log buffer
     */
    static void clearLogs();

    /**
     * Set the maximum log buffer size
     * @param maxSize Maximum number of log entries to keep
     */
    static void setMaxLogSize(size_t maxSize);

    /**
     * Enable or disable automatic log collection
     * @param enabled true to enable, false to disable
     */
    static void setLogCollectionEnabled(bool enabled);

    /**
     * Check if log collection is enabled
     */
    static bool isLogCollectionEnabled();

    /**
     * Get the version of the native crash handler module
     * @return Version string
     */
    static std::string getVersion();

private:
    FTNativeCrashHandler();
    ~FTNativeCrashHandler();
    FTNativeCrashHandler(const FTNativeCrashHandler&) = delete;
    FTNativeCrashHandler& operator=(const FTNativeCrashHandler&) = delete;

    bool initialized_;
    napi_env env_;
    std::shared_ptr<NativeCrashCallback> callback_;
    void* watcher_;  // HiAppEvent_Watcher pointer

    // Runtime log collection
    static std::deque<LogEntry> s_logBuffer;
    static std::mutex s_logMutex;
    static size_t s_maxLogSize;
    static bool s_logCollectionEnabled;
};

} // namespace ftstatsd

#endif // FT_NATIVE_CRASH_HANDLER_H
