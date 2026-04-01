#ifndef FT_SIGNAL_HANDLER_H
#define FT_SIGNAL_HANDLER_H

#include <signal.h>
#include <string>
#include <unordered_map>

namespace ftstatsd {

/**
 * Signal Handler for HarmonyOS
 * Implements proper signal chaining to avoid interfering with other crash handlers
 *
 * Key principles:
 * 1. Use sigaction() instead of signal() to save old handlers
 * 2. Do minimal work in signal handler (avoid async-signal-unsafe functions)
 * 3. Chain to old handler after our processing
 * 4. Restore default handler if needed to avoid infinite loops
 */
class FTSignalHandler {
public:
    /**
     * Register signal handlers with proper chaining
     * @return true if successful, false otherwise
     */
    static bool registerHandlers();

    /**
     * Unregister signal handlers and restore old handlers
     */
    static void unregisterHandlers();

    /**
     * Check if signal handler is registered
     */
    static bool isRegistered() { return s_registered; }

private:
    FTSignalHandler() = delete;
    ~FTSignalHandler() = delete;

    // Signals we want to handle
    static constexpr int SIGNALS[] = {
        SIGSEGV,  // Segment fault
        SIGABRT,  // Abort
        SIGFPE,   // Floating point exception
        SIGILL,   // Illegal instruction
        SIGBUS,   // Bus error
        SIGTRAP,  // Trace trap
        0         // Sentinel
    };

    // Signal handler function (static C-compatible)
    static void signalHandler(int sig, siginfo_t* info, void* ucontext);

    // Old signal handlers for chaining
    static struct sigaction s_oldActions[NSIG];
    static bool s_registered;
    static bool s_inHandler;

    // Safe crash data collection (called from signal handler)
    static void collectCrashData(int sig, siginfo_t* info, void* ucontext);
};

} // namespace ftstatsd

#endif // FT_SIGNAL_HANDLER_H
