#include "FTSignalHandler.h"
#include "FTNativeCrashHandler.h"

// Define LOG_DOMAIN before including hilog/log.h to use custom domain
#define LOG_DOMAIN 0x0001
#define LOG_TAG "[FT-SDK-NATIVE]FTSignalHandler"

#include <hilog/log.h>
#include <cstring>
#include <csignal>
#include <cstdarg>
#include <cstdio>
#include <unistd.h>
#include <sys/types.h>
#include <sys/ucontext.h>

namespace ftstatsd {

// Static member initialization
struct sigaction FTSignalHandler::s_oldActions[NSIG] = {};
bool FTSignalHandler::s_registered = false;
bool FTSignalHandler::s_inHandler = false;

// Signal names for logging
static const char* getSignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGABRT: return "SIGABRT";
        case SIGFPE:  return "SIGFPE";
        case SIGILL:  return "SIGILL";
        case SIGBUS:  return "SIGBUS";
        case SIGTRAP: return "SIGTRAP";
        default:      return "UNKNOWN";
    }
}

// Safe write function for signal handler context
// write() is async-signal-safe
static void safeWrite(const char* msg) {
    if (msg == nullptr) return;
    size_t len = strlen(msg);
    write(STDERR_FILENO, msg, len);
}

// Safe number to string conversion
static void safeIntToStr(char* buf, int value, int& len) {
    if (value == 0) {
        buf[len++] = '0';
        return;
    }

    char tmp[32];
    int tmpLen = 0;
    bool negative = value < 0;
    if (negative) value = -value;

    while (value > 0) {
        tmp[tmpLen++] = '0' + (value % 10);
        value /= 10;
    }

    if (negative) {
        buf[len++] = '-';
    }
    while (tmpLen > 0) {
        buf[len++] = tmp[--tmpLen];
    }
}

void FTSignalHandler::collectCrashData(int sig, siginfo_t* info, void* ucontext) {
    // Minimal data collection in signal handler context
    // Collect only what we can get from siginfo_t and ucontext_t

    char crashInfo[512];
    int offset = 0;

    // Build crash info string
    const char* sigName = getSignalName(sig);

    // Copy signal name
    while (*sigName && offset < 100) {
        crashInfo[offset++] = *sigName++;
    }

    crashInfo[offset++] = ':';
    crashInfo[offset++] = ' ';

    // Add signal number
    safeIntToStr(crashInfo, sig, offset);

    crashInfo[offset++] = '\n';
    crashInfo[offset++] = '\0';

    safeWrite(crashInfo);

    // Try to extract fault address from siginfo_t
    if (info != nullptr && info->si_addr != nullptr) {
        safeWrite("Fault address: 0x");

        char addrStr[32];
        int addrLen = 0;
        uintptr_t addr = reinterpret_cast<uintptr_t>(info->si_addr);

        if (addr == 0) {
            crashInfo[addrLen++] = '0';
        } else {
            char tmp[32];
            int tmpLen = 0;
            while (addr > 0) {
                int digit = addr % 16;
                tmp[tmpLen++] = digit < 10 ? '0' + digit : 'a' + digit - 10;
                addr /= 16;
            }
            while (tmpLen > 0) {
                crashInfo[addrLen++] = tmp[--tmpLen];
            }
        }
        crashInfo[addrLen++] = '\n';
        crashInfo[addrLen] = '\0';
        safeWrite(crashInfo);
    }

    // Note: We cannot call FTNativeCrashHandler here because
    // it's not async-signal-safe. The crash data will be
    // collected by HiAppEvent callback instead.
}

void FTSignalHandler::signalHandler(int sig, siginfo_t* info, void* ucontext) {
    // ========================================
    // STEP 1: Signal handler entry
    // ========================================
    safeWrite("\n");
    safeWrite("╔════════════════════════════════════════════════════════════╗\n");
    safeWrite("║     FT SIGNAL HANDLER: ENTRY                                 ║\n");
    safeWrite("╚════════════════════════════════════════════════════════════╝\n");

    // Prevent re-entrancy
    if (s_inHandler) {
        safeWrite("⚠️  RE-ENTRANT CRASH DETECTED!\n");
        safeWrite("→ Restoring default handler and re-raising signal\n");
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }

    s_inHandler = true;

    // Log signal info
    const char* sigName = getSignalName(sig);
    char sigInfo[128];
    snprintf(sigInfo, sizeof(sigInfo), "📞 SIGNAL RECEIVED: %s (%d)\n", sigName, sig);
    safeWrite(sigInfo);

    // ========================================
    // STEP 2: Collect crash data
    // ========================================
    safeWrite("→ STEP 2: Collecting crash data...\n");
    collectCrashData(sig, info, ucontext);
    safeWrite("  ✓ Crash data collected\n");

    // ========================================
    // STEP 3: Check the previous handler (signal chain)
    // ========================================
    safeWrite("→ STEP 3: Checking for old handler (signal chain)...\n");

    struct sigaction& oldAction = s_oldActions[sig];
    bool hasOldHandler = false;

    // Log old handler info
    char handlerInfo[256];
    snprintf(handlerInfo, sizeof(handlerInfo), "  Old handler address: %p\n",
             reinterpret_cast<void*>(oldAction.sa_sigaction));
    safeWrite(handlerInfo);

    // Try to call the old handler in sigaction format first
    if (oldAction.sa_sigaction != nullptr) {
        auto handlerAddr = reinterpret_cast<uintptr_t>(oldAction.sa_sigaction);
        if (handlerAddr > 1) {  // 0 and 1 are typically SIG_DFL/SIG_IGN
            hasOldHandler = true;

            safeWrite("→ STEP 4: 🔄 CHAINING to next handler (signal chain)\n");
            snprintf(handlerInfo, sizeof(handlerInfo), "  → Calling handler at %p\n",
                     reinterpret_cast<void*>(handlerAddr));
            safeWrite(handlerInfo);

            // Call old sigaction handler (this is where the magic happens!)
            oldAction.sa_sigaction(sig, info, ucontext);

            safeWrite("  ✓ Returned from next handler\n");
        } else {
            safeWrite("  → Old handler is SIG_DFL or SIG_IGN (no valid handler)\n");
        }
    }

    // If no sigaction handler, try the old signal handler format
    if (!hasOldHandler && oldAction.sa_handler != nullptr) {
        auto handlerAddr = reinterpret_cast<uintptr_t>(oldAction.sa_handler);
        if (handlerAddr > 1) {  // 0 and 1 are typically SIG_DFL/SIG_IGN
            hasOldHandler = true;

            safeWrite("→ STEP 4: 🔄 CHAINING to old-style signal handler\n");
            snprintf(handlerInfo, sizeof(handlerInfo), "  → Calling handler at %p\n",
                     reinterpret_cast<void*>(handlerAddr));
            safeWrite(handlerInfo);

            // Call old signal handler (without siginfo)
            oldAction.sa_handler(sig);

            safeWrite("  ✓ Returned from old handler\n");
        } else {
            safeWrite("  → Old handler is SIG_DFL or SIG_IGN (no valid handler)\n");
        }
    }

    // ========================================
    // STEP 5: No previous handler, restore default behavior
    // ========================================
    if (!hasOldHandler) {
        safeWrite("→ STEP 5: No old handler found\n");
        safeWrite("  → Restoring default handler (SIG_DFL)\n");
        safeWrite("  → Re-raising signal to terminate process\n");
        signal(sig, SIG_DFL);
        raise(sig);
    }

    s_inHandler = false;

    // ========================================
    // Exit the signal handler
    // ========================================
    safeWrite("╔════════════════════════════════════════════════════════════╗\n");
    safeWrite("║     FT SIGNAL HANDLER: EXIT                                  ║\n");
    safeWrite("╚════════════════════════════════════════════════════════════╝\n");
    safeWrite("\n");
}

bool FTSignalHandler::registerHandlers() {
    if (s_registered) {
        return true;
    }

    struct sigaction sa {};
    sa.sa_sigaction = signalHandler;
    sigemptyset(&sa.sa_mask);

    // Block all signals during handler to prevent re-entrancy
    sigfillset(&sa.sa_mask);

    // Use SA_SIGINFO to get siginfo_t and ucontext_t
    // Use SA_RESTART to restart interrupted system calls
    // Use SA_ONSTACK to use alternate signal stack (if set up)
    sa.sa_flags = SA_SIGINFO | SA_RESTART;

    // Register handlers for each signal
    for (int i = 0; SIGNALS[i] != 0; ++i) {
        int sig = SIGNALS[i];

        // Save old handler
        if (sigaction(sig, &sa, &s_oldActions[sig]) == -1) {
            // Failed to register handler for this signal
            // Don't fail completely, just log and continue
            OH_LOG_ERROR(LogType::LOG_APP, 
                        "Failed to register handler for %{public}s (%{public}d): %{public}s",
                        getSignalName(sig), sig, strerror(errno));
            s_oldActions[sig].sa_handler = nullptr;
        }
    }

    s_registered = true;
    return true;
}

void FTSignalHandler::unregisterHandlers() {
    if (!s_registered) {
        return;
    }

    // Restore old handlers
    for (int i = 0; SIGNALS[i] != 0; ++i) {
        int sig = SIGNALS[i];

        if (s_oldActions[sig].sa_handler != nullptr ||
            s_oldActions[sig].sa_sigaction != nullptr) {
            // Restore old handler
            sigaction(sig, &s_oldActions[sig], nullptr);
        }

        // Clear old handler
        s_oldActions[sig].sa_handler = nullptr;
        s_oldActions[sig].sa_sigaction = nullptr;
    }

    s_registered = false;
}

} // namespace ftstatsd
