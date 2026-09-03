#include "FTNativeCrashHandler.h"
#include "FTSignalHandler.h"
#include "ft_version.h"

// Define LOG_DOMAIN before including hilog/log.h to use custom domain
#define LOG_DOMAIN 0x0001
#define LOG_TAG "[FT-SDK-NATIVE]FTNativeCrashHandler"

#include <hiappevent/hiappevent.h>
#include <hilog/log.h>
#include <thread>
#include <mutex>
#include <sstream>
#include <cstdio>
#include <unistd.h>
#include <cstring>
#include <memory>
#include <chrono>
#include <iomanip>

namespace ftstatsd {

// Static instance
static FTNativeCrashHandler* g_instance = nullptr;
static std::mutex g_instanceMutex;

// Runtime log collection - static members
std::deque<LogEntry> FTNativeCrashHandler::s_logBuffer;
std::mutex FTNativeCrashHandler::s_logMutex;
size_t FTNativeCrashHandler::s_maxLogSize = 500;  // Default: keep last 500 log entries
bool FTNativeCrashHandler::s_logCollectionEnabled = true;  // Enabled by default

// LogEntry implementation
std::string LogEntry::toString() const {
    std::ostringstream oss;
    oss << timestamp << " " << level << " " << tag << ": " << message;
    return oss.str();
}

// Static log collection methods
void FTNativeCrashHandler::addLog(const char* level, const char* tag, const char* message) {
    // Skip if collection is disabled
    if (!s_logCollectionEnabled) {
        return;
    }

    std::lock_guard<std::mutex> lock(s_logMutex);

    LogEntry entry;
    entry.level = level;
    entry.tag = tag;
    entry.message = message;

    // Generate timestamp in HarmonyOS HiLog format: MM-DD HH:mm:ss.SSS
    auto now = std::chrono::system_clock::now();
    auto time_t_now = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;

    std::tm tm_now;
    localtime_r(&time_t_now, &tm_now);

    char ts_buf[64];
    snprintf(ts_buf, sizeof(ts_buf), "%02d-%02d %02d:%02d:%02d.%03d",
             tm_now.tm_mon + 1, tm_now.tm_mday,
             tm_now.tm_hour, tm_now.tm_min, tm_now.tm_sec,
             static_cast<int>(ms.count()));
    entry.timestamp = ts_buf;

    // Add to buffer
    s_logBuffer.push_back(entry);

    // Trim if exceeds max size (circular buffer)
    while (s_logBuffer.size() > s_maxLogSize) {
        s_logBuffer.pop_front();
    }
}

std::string FTNativeCrashHandler::getCollectedLogs(int maxLines) {
    std::lock_guard<std::mutex> lock(s_logMutex);

    if (s_logBuffer.empty()) {
        return "";
    }

    std::ostringstream oss;
    size_t startIdx = 0;
    size_t count = s_logBuffer.size();

    if (maxLines > 0 && count > static_cast<size_t>(maxLines)) {
        startIdx = count - maxLines;
        count = maxLines;
        oss << "... (showing last " << maxLines << " of " << s_logBuffer.size() << " log entries) ...\n";
    }

    for (size_t i = startIdx; i < s_logBuffer.size(); ++i) {
        oss << s_logBuffer[i].toString() << "\n";
    }

    return oss.str();
}

void FTNativeCrashHandler::clearLogs() {
    std::lock_guard<std::mutex> lock(s_logMutex);
    s_logBuffer.clear();
}

void FTNativeCrashHandler::setMaxLogSize(size_t maxSize) {
    std::lock_guard<std::mutex> lock(s_logMutex);
    s_maxLogSize = maxSize;
    // Trim if current buffer exceeds new max size
    while (s_logBuffer.size() > s_maxLogSize) {
        s_logBuffer.pop_front();
    }
}

void FTNativeCrashHandler::setLogCollectionEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(s_logMutex);
    s_logCollectionEnabled = enabled;
}

bool FTNativeCrashHandler::isLogCollectionEnabled() {
    std::lock_guard<std::mutex> lock(s_logMutex);
    return s_logCollectionEnabled;
}

std::string FTNativeCrashHandler::getVersion() {
    return FT_VERSION;
}

/**
 * Helper function to read /proc/self/maps for memory layout
 */
static std::string readMemoryMaps() {
    std::string mapsContent;
    FILE* fp = fopen("/proc/self/maps", "r");
    if (fp != nullptr) {
        char line[1024];
        int lineCount = 0;
        while (fgets(line, sizeof(line), fp) != nullptr) {
            mapsContent += line;
            lineCount++;
        }
        fclose(fp);
        OH_LOG_DEBUG(LogType::LOG_APP,  "Read %{public}d lines from /proc/self/maps", lineCount);
    } else {
        OH_LOG_ERROR(LogType::LOG_APP,  "Failed to open /proc/self/maps");
        mapsContent = "Unable to read memory maps";
    }
    return mapsContent;
}

/**
 * Helper function to read HiLog for recent system logs
 * Uses collected runtime logs instead of system hilog command
 */
static std::string readHiLog() {
    OH_LOG_DEBUG(LogType::LOG_APP,  "Collecting runtime logs for crash report");

    // Use collected runtime logs - this is more reliable than shell commands
    std::string collectedLogs = FTNativeCrashHandler::getCollectedLogs(500);

    if (collectedLogs.empty()) {
        OH_LOG_WARN(LogType::LOG_APP,  "No runtime logs collected");
        return "";
    }

    OH_LOG_DEBUG(LogType::LOG_APP,  "Collected %{public}zu bytes of runtime logs", collectedLogs.length());
    return collectedLogs;
}

/**
 * Helper function to try reading crash fault log for memory near registers
 * This attempts to read from the system's crash log files
 */
static std::string readCrashFaultLog() {
    // Common crash log file locations on HarmonyOS
    const char* crashLogPaths[] = {
        "/data/log/faultlog/fault_temp_log.txt",
        "/data/log/faultlog/",
        "/storage/log/faultlog/",
        nullptr
    };

    // First, try to read the main fault log file
    for (int i = 0; crashLogPaths[i] != nullptr; i++) {
        FILE* fp = fopen(crashLogPaths[i], "r");
        if (fp != nullptr) {
            OH_LOG_DEBUG(LogType::LOG_APP,  "Reading crash log from %{public}s", crashLogPaths[i]);

            // Read the entire file
            std::string content;
            char line[1024];
            while (fgets(line, sizeof(line), fp) != nullptr) {
                content += line;
            }
            fclose(fp);
            return content;
        }
    }

    // If direct file read fails, try using the faultlog command if available
    FILE* pipe = popen("cat /data/log/faultlog/fault_temp_log.txt 2>/dev/null", "r");
    if (pipe != nullptr) {
        OH_LOG_DEBUG(LogType::LOG_APP,  "Reading crash log via cat command");

        std::string content;
        char line[1024];
        while (fgets(line, sizeof(line), pipe) != nullptr) {
            content += line;
        }
        pclose(pipe);
        return content;
    }

    OH_LOG_WARN(LogType::LOG_APP,  "Unable to read crash fault log from system");
    return "";
}

FTNativeCrashHandler& FTNativeCrashHandler::getInstance() {
    std::lock_guard<std::mutex> lock(g_instanceMutex);
    if (g_instance == nullptr) {
        g_instance = new FTNativeCrashHandler();
    }
    return *g_instance;
}

FTNativeCrashHandler::FTNativeCrashHandler()
    : initialized_(false)
    , env_(nullptr)
    , watcher_(nullptr) {
}

FTNativeCrashHandler::~FTNativeCrashHandler() {
    if (watcher_ != nullptr) {
        OH_HiAppEvent_RemoveWatcher(static_cast<HiAppEvent_Watcher*>(watcher_));
        OH_HiAppEvent_DestroyWatcher(static_cast<HiAppEvent_Watcher*>(watcher_));
        watcher_ = nullptr;
    }
}

bool FTNativeCrashHandler::initialize(napi_env env) {
    if (initialized_) {
        OH_LOG_DEBUG(LogType::LOG_APP,  "FTNativeCrashHandler already initialized");
        return true;
    }

    env_ = env;

    // Register signal handlers with proper chaining
    // This ensures we can capture crashes and still pass them to other handlers
    if (!FTSignalHandler::registerHandlers()) {
        OH_LOG_WARN(LogType::LOG_APP,  "Failed to register signal handlers, continuing without them");
    }

    initialized_ = true;
    return true;
}

void FTNativeCrashHandler::setCrashCallback(std::shared_ptr<NativeCrashCallback> callback) {
    std::lock_guard<std::mutex> lock(g_instanceMutex);
    callback_ = callback;
}

std::shared_ptr<NativeCrashCallback> FTNativeCrashHandler::getCrashCallback() const {
    return callback_;
}

// Crash event callback function
static void OnCrashEventReceive(const char* domain,
                                const struct HiAppEvent_AppEventGroup* appEventGroups,
                                uint32_t groupLen) {
    OH_LOG_DEBUG(LogType::LOG_APP,  "OnCrashEventReceive called, groupLen=%{public}u", groupLen);

    auto& handler = FTNativeCrashHandler::getInstance();

    for (uint32_t i = 0; i < groupLen; ++i) {
        for (uint32_t j = 0; j < appEventGroups[i].infoLen; ++j) {
            const auto& eventInfo = appEventGroups[i].appEventInfos[j];

            OH_LOG_DEBUG(LogType::LOG_APP,
                       "Received event: domain=%{public}s, name=%{public}s, type=%{public}d",
                       eventInfo.domain, eventInfo.name, eventInfo.type);

            // Check if this is a crash event
            if (strcmp(eventInfo.domain, "OS") == 0 &&
                strcmp(eventInfo.name, "APP_CRASH") == 0) {

                OH_LOG_DEBUG(LogType::LOG_APP,  "Processing crash event, params=%{public}s",
                           eventInfo.params);

                // Helper function to extract string value from JSON
                auto extractJsonString = [&](const std::string& json, const std::string& key) -> std::string {
                    std::string searchKey = "\"" + key + "\":\"";
                    size_t pos = json.find(searchKey);
                    if (pos != std::string::npos) {
                        pos += searchKey.length();
                        size_t endPos = json.find("\"", pos);
                        if (endPos != std::string::npos) {
                            return json.substr(pos, endPos - pos);
                        }
                    }
                    return "";
                };

                // Helper function to extract int value from JSON
                auto extractJsonInt = [&](const std::string& json, const std::string& key) -> int64_t {
                    std::string searchKey = "\"" + key + "\":";
                    size_t pos = json.find(searchKey);
                    if (pos != std::string::npos) {
                        pos += searchKey.length();
                        size_t endPos = json.find_first_of(",}", pos);
                        if (endPos != std::string::npos) {
                            std::string numStr = json.substr(pos, endPos - pos);
                            try {
                                return std::stoll(numStr);
                            } catch (...) {
                                return 0;
                            }
                        }
                    }
                    return 0;
                };

                // Helper function to extract bool value from JSON
                auto extractJsonBool = [&](const std::string& json, const std::string& key) -> bool {
                    std::string searchKey = "\"" + key + "\":";
                    size_t pos = json.find(searchKey);
                    if (pos != std::string::npos) {
                        pos += searchKey.length();
                        std::string remaining = json.substr(pos);
                        if (remaining.find("true") == 0) {
                            return true;
                        } else if (remaining.find("false") == 0) {
                            return false;
                        }
                    }
                    return false;
                };

                std::string paramsStr = eventInfo.params;

                // Log the raw JSON data for debugging
                OH_LOG_DEBUG(LogType::LOG_APP,  "=== RAW CRASH DATA START ===");
                OH_LOG_DEBUG(LogType::LOG_APP,  "%{public}s", paramsStr.c_str());
                OH_LOG_DEBUG(LogType::LOG_APP,  "=== RAW CRASH DATA END ===");

                // Parse crash data from JSON
                NativeCrashData crashData;
                crashData.timestamp = extractJsonInt(paramsStr, "time");
                crashData.crashType = "Unknown";
                crashData.foreground = extractJsonBool(paramsStr, "foreground");
                crashData.bundleVersion = extractJsonString(paramsStr, "bundle_version");
                crashData.bundleName = extractJsonString(paramsStr, "bundle_name");
                crashData.pid = static_cast<int>(extractJsonInt(paramsStr, "pid"));
                crashData.uid = static_cast<int>(extractJsonInt(paramsStr, "uid"));
                crashData.uuid = extractJsonString(paramsStr, "uuid");
                crashData.exception = paramsStr;  // Store full params as exception
                crashData.hilogSize = static_cast<int>(extractJsonInt(paramsStr, "hilog_size"));

                // Extract external_log array (as JSON string)
                size_t externalLogPos = paramsStr.find("\"external_log\":");
                if (externalLogPos != std::string::npos) {
                    size_t arrayStart = paramsStr.find("[", externalLogPos);
                    size_t arrayEnd = paramsStr.find("]", arrayStart);
                    if (arrayStart != std::string::npos && arrayEnd != std::string::npos) {
                        crashData.externalLog = paramsStr.substr(arrayStart, arrayEnd - arrayStart + 1);
                    }
                }

                crashData.logOverLimit = extractJsonBool(paramsStr, "log_over_limit");

                // Extract memory_near_registers (as JSON string value)
                size_t memNearRegsPos = paramsStr.find("\"memory_near_registers\":");
                if (memNearRegsPos != std::string::npos) {
                    // Skip past "memory_near_registers":
                    size_t colonPos = paramsStr.find(":", memNearRegsPos);
                    if (colonPos != std::string::npos) {
                        // Skip whitespace
                        size_t valueStart = colonPos + 1;
                        while (valueStart < paramsStr.length() && (paramsStr[valueStart] == ' ' || paramsStr[valueStart] == '\t' || paramsStr[valueStart] == '\n')) {
                            valueStart++;
                        }

                        if (valueStart < paramsStr.length()) {
                            // Check if it's a string value (starts with ")
                            if (paramsStr[valueStart] == '"') {
                                valueStart++; // Skip opening quote
                                size_t valueEnd = valueStart;
                                bool escape = false;
                                while (valueEnd < paramsStr.length()) {
                                    char c = paramsStr[valueEnd];
                                    if (c == '\\' && !escape) {
                                        escape = true;
                                    } else if (c == '"' && !escape) {
                                        break; // Found closing quote
                                    } else {
                                        escape = false;
                                    }
                                    valueEnd++;
                                }
                                if (valueEnd > valueStart) {
                                    crashData.memoryNearRegisters = paramsStr.substr(valueStart, valueEnd - valueStart);
                                    OH_LOG_DEBUG(LogType::LOG_APP,  "Extracted memory_near_registers, length=%{public}zu", crashData.memoryNearRegisters.length());
                                }
                            } else {
                                // Try object or array format
                                size_t tempStart = valueStart;
                                char openBracket = paramsStr[tempStart];
                                char closeBracket = (openBracket == '{') ? '}' : ']';
                                if (openBracket == '{' || openBracket == '[') {
                                    int bracketCount = 0;
                                    bool inString = false;
                                    bool escape = false;
                                    for (size_t i = tempStart; i < paramsStr.length(); i++) {
                                        char c = paramsStr[i];
                                        if (c == '\\' && !escape) {
                                            escape = true;
                                        } else if (c == '"' && !escape) {
                                            inString = !inString;
                                            escape = false;
                                        } else if (!inString && !escape) {
                                            if (c == openBracket) {
                                                bracketCount++;
                                            } else if (c == closeBracket) {
                                                bracketCount--;
                                                if (bracketCount == 0) {
                                                    crashData.memoryNearRegisters = paramsStr.substr(tempStart, i - tempStart + 1);
                                                    OH_LOG_DEBUG(LogType::LOG_APP,  "Extracted memory_near_registers (object/array), length=%{public}zu", crashData.memoryNearRegisters.length());
                                                    break;
                                                }
                                            }
                                        } else {
                                            escape = false;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Extract maps (as JSON string value or array)
                size_t mapsPos = paramsStr.find("\"maps\":");
                if (mapsPos != std::string::npos) {
                    // Skip past "maps":
                    size_t colonPos = paramsStr.find(":", mapsPos);
                    if (colonPos != std::string::npos) {
                        // Skip whitespace
                        size_t valueStart = colonPos + 1;
                        while (valueStart < paramsStr.length() && (paramsStr[valueStart] == ' ' || paramsStr[valueStart] == '\t' || paramsStr[valueStart] == '\n')) {
                            valueStart++;
                        }

                        if (valueStart < paramsStr.length()) {
                            // Check if it's a string value (starts with ")
                            if (paramsStr[valueStart] == '"') {
                                valueStart++; // Skip opening quote
                                size_t valueEnd = valueStart;
                                bool escape = false;
                                while (valueEnd < paramsStr.length()) {
                                    char c = paramsStr[valueEnd];
                                    if (c == '\\' && !escape) {
                                        escape = true;
                                    } else if (c == '"' && !escape) {
                                        break; // Found closing quote
                                    } else {
                                        escape = false;
                                    }
                                    valueEnd++;
                                }
                                if (valueEnd > valueStart) {
                                    crashData.maps = paramsStr.substr(valueStart, valueEnd - valueStart);
                                    OH_LOG_DEBUG(LogType::LOG_APP,  "Extracted maps, length=%{public}zu", crashData.maps.length());
                                }
                            } else {
                                // Try array format
                                size_t tempStart = valueStart;
                                if (paramsStr[tempStart] == '[') {
                                    int bracketCount = 0;
                                    bool inString = false;
                                    bool escape = false;
                                    for (size_t i = tempStart; i < paramsStr.length(); i++) {
                                        char c = paramsStr[i];
                                        if (c == '\\' && !escape) {
                                            escape = true;
                                        } else if (c == '"' && !escape) {
                                            inString = !inString;
                                            escape = false;
                                        } else if (!inString && !escape) {
                                            if (c == '[') bracketCount++;
                                            else if (c == ']') {
                                                bracketCount--;
                                                if (bracketCount == 0) {
                                                    crashData.maps = paramsStr.substr(tempStart, i - tempStart + 1);
                                                    OH_LOG_DEBUG(LogType::LOG_APP,  "Extracted maps (array), length=%{public}zu", crashData.maps.length());
                                                    break;
                                                }
                                            }
                                        } else {
                                            escape = false;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Extract hilog (as JSON string value)
                size_t hilogPos = paramsStr.find("\"hilog\":");
                if (hilogPos != std::string::npos) {
                    // Skip past "hilog":
                    size_t colonPos = paramsStr.find(":", hilogPos);
                    if (colonPos != std::string::npos) {
                        // Skip whitespace
                        size_t valueStart = colonPos + 1;
                        while (valueStart < paramsStr.length() && (paramsStr[valueStart] == ' ' || paramsStr[valueStart] == '\t' || paramsStr[valueStart] == '\n')) {
                            valueStart++;
                        }

                        if (valueStart < paramsStr.length() && paramsStr[valueStart] == '"') {
                            valueStart++; // Skip opening quote
                            size_t valueEnd = valueStart;
                            bool escape = false;
                            while (valueEnd < paramsStr.length()) {
                                char c = paramsStr[valueEnd];
                                if (c == '\\' && !escape) {
                                    escape = true;
                                } else if (c == '"' && !escape) {
                                    break; // Found closing quote
                                } else {
                                    escape = false;
                                }
                                valueEnd++;
                            }
                            if (valueEnd > valueStart) {
                                std::string hilogContent = paramsStr.substr(valueStart, valueEnd - valueStart);
                                // Unescape common escape sequences
                                size_t pos = 0;
                                while ((pos = hilogContent.find("\\n", pos)) != std::string::npos) {
                                    hilogContent.replace(pos, 2, "\n");
                                    pos += 1;
                                }
                                pos = 0;
                                while ((pos = hilogContent.find("\\t", pos)) != std::string::npos) {
                                    hilogContent.replace(pos, 2, "\t");
                                    pos += 1;
                                }
                                crashData.hilog = hilogContent;
                                OH_LOG_DEBUG(LogType::LOG_APP,  "Extracted hilog, length=%{public}zu", crashData.hilog.length());
                            }
                        }
                    }
                }

                OH_LOG_DEBUG(LogType::LOG_APP,
                           "Parsed crash data: pid=%{public}d, uid=%{public}d, bundle=%{public}s, version=%{public}s",
                           crashData.pid, crashData.uid, crashData.bundleName.c_str(), crashData.bundleVersion.c_str());

                // Parse crash_type from params to determine if it's a native crash
                const char* crashTypeStr = "JsError";  // default

                // Simple crash_type detection
                if (paramsStr.find("\"crash_type\":\"NativeCrash\"") != std::string::npos) {
                    crashTypeStr = "NativeCrash";
                    OH_LOG_DEBUG(LogType::LOG_APP,  "Detected NATIVE crash (C++)");
                } else if (paramsStr.find("\"crash_type\":\"JsError\"") != std::string::npos) {
                    crashTypeStr = "JsError";
                    OH_LOG_DEBUG(LogType::LOG_APP,  "Detected JS crash");
                }

                crashData.crashType = crashTypeStr;

                // Log availability of optional crash data fields
                OH_LOG_DEBUG(LogType::LOG_APP,  "memory_near_registers: %{public}s, maps: %{public}s, hilog: %{public}s",
                           crashData.memoryNearRegisters.empty() ? "NOT FOUND" : "FOUND",
                           crashData.maps.empty() ? "NOT FOUND" : "FOUND",
                           crashData.hilog.empty() ? "NOT FOUND" : "FOUND");

                // Fallback: If memory_near_registers was not found in JSON, try reading from crash log file
                if (crashData.memoryNearRegisters.empty()) {
                    crashData.memoryNearRegisters = readCrashFaultLog();
                    if (!crashData.memoryNearRegisters.empty()) {
                        OH_LOG_DEBUG(LogType::LOG_APP,  "Read crash fault log from system as fallback");
                    } else {
                        OH_LOG_WARN(LogType::LOG_APP,  "Memory near registers not available (requires crash signal handler context)");
                    }
                }

                // Fallback: If maps was not found in JSON, try reading from /proc/self/maps
                if (crashData.maps.empty()) {
                    crashData.maps = readMemoryMaps();
                    OH_LOG_DEBUG(LogType::LOG_APP,  "Read memory maps from /proc/self/maps as fallback");
                }

                // Fallback: If hilog was not found in JSON, try reading from hilog command
                if (crashData.hilog.empty()) {
                    crashData.hilog = readHiLog();
                    if (!crashData.hilog.empty()) {
                        OH_LOG_DEBUG(LogType::LOG_APP,  "Read hilog from system as fallback");
                    } else {
                        OH_LOG_WARN(LogType::LOG_APP,  "Hilog not available in crash data and unable to read from system");
                    }
                }

                // Notify callback if available
                // ONLY callback for NATIVE crashes, not JavaScript crashes
                // JavaScript crashes are handled by errorManager in FTExceptionHandler
                OH_LOG_DEBUG(LogType::LOG_APP,  "<FT-CRASH-CALLBACK> About to get crash callback...");
                std::lock_guard<std::mutex> lock(g_instanceMutex);
                auto callback = handler.getCrashCallback();
                OH_LOG_DEBUG(LogType::LOG_APP,  "<FT-CRASH-CALLBACK> Callback retrieved: %{public}s", callback ? "VALID" : "NULL");

                // Filter: Only process native crashes, skip JavaScript crashes
                if (strcmp(crashTypeStr, "JsError") == 0) {
                    OH_LOG_DEBUG(LogType::LOG_APP,  "<FT-CRASH-CALLBACK> *** SKIPPING JS CRASH *** (handled by errorManager)");
                    OH_LOG_DEBUG(LogType::LOG_APP,  "<FT-CRASH-CALLBACK> JavaScript crashes should be handled by FTExceptionHandler, not FTNativeCrashHandler");
                } else if (callback) {
                    OH_LOG_DEBUG(LogType::LOG_APP,  "<FT-CRASH-CALLBACK> *** CALLING ARKTS CALLBACK *** for NATIVE crash: type=%{public}s", crashTypeStr);
                    callback->onNativeCrash(crashData);
                    OH_LOG_DEBUG(LogType::LOG_APP,  "<FT-CRASH-CALLBACK> *** ARKTS CALLBACK RETURNED ***");
                } else {
                    OH_LOG_DEBUG(LogType::LOG_APP,  "<FT-CRASH-CALLBACK> *** NO CALLBACK SET *** crash data not sent to ArkTS layer");
                }
            }
        }
    }
}

bool FTNativeCrashHandler::startWatching() {
    if (!initialized_) {
        OH_LOG_ERROR(LogType::LOG_APP,  "FTNativeCrashHandler not initialized");
        return false;
    }

    if (watcher_ != nullptr) {
        OH_LOG_DEBUG(LogType::LOG_APP,  "Watcher already started");
        return true;
    }

    // Create watcher
    watcher_ = OH_HiAppEvent_CreateWatcher("FTNativeCrashWatcher");
    if (watcher_ == nullptr) {
        OH_LOG_ERROR(LogType::LOG_APP,  "Failed to create HiAppEvent watcher");
        return false;
    }

    // Set event filter for crash events
    const char* eventNames[] = {"APP_CRASH"};
    int ret = OH_HiAppEvent_SetAppEventFilter(
        static_cast<HiAppEvent_Watcher*>(watcher_),
        "OS",
        0,
        eventNames,
        1
    );

    if (ret != 0) {
        OH_LOG_ERROR(LogType::LOG_APP,  "Failed to set app event filter: %{public}d", ret);
        OH_HiAppEvent_DestroyWatcher(static_cast<HiAppEvent_Watcher*>(watcher_));
        watcher_ = nullptr;
        return false;
    }

    // Set callback
    ret = OH_HiAppEvent_SetWatcherOnReceive(
        static_cast<HiAppEvent_Watcher*>(watcher_),
        OnCrashEventReceive
    );

    if (ret != 0) {
        OH_LOG_ERROR(LogType::LOG_APP,  "Failed to set watcher callback: %{public}d", ret);
        OH_HiAppEvent_DestroyWatcher(static_cast<HiAppEvent_Watcher*>(watcher_));
        watcher_ = nullptr;
        return false;
    }

    // Add watcher
    ret = OH_HiAppEvent_AddWatcher(static_cast<HiAppEvent_Watcher*>(watcher_));
    if (ret != 0) {
        OH_LOG_ERROR(LogType::LOG_APP,  "Failed to add watcher: %{public}d", ret);
        OH_HiAppEvent_DestroyWatcher(static_cast<HiAppEvent_Watcher*>(watcher_));
        watcher_ = nullptr;
        return false;
    }

    return true;
}

void FTNativeCrashHandler::stopWatching() {
    // Unregister signal handlers and restore old handlers
    FTSignalHandler::unregisterHandlers();

    if (watcher_ != nullptr) {
        OH_HiAppEvent_RemoveWatcher(static_cast<HiAppEvent_Watcher*>(watcher_));
        OH_HiAppEvent_DestroyWatcher(static_cast<HiAppEvent_Watcher*>(watcher_));
        watcher_ = nullptr;
    }
}

} // namespace ftstatsd
