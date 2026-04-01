#ifndef FT_CRASH_TEST_H
#define FT_CRASH_TEST_H

namespace ftcrash {

class CrashTest {
public:
    // Trigger null pointer dereference crash
    static void triggerNullPointerCrash();

    // Trigger division by zero crash
    static void triggerDivisionByZero();

    // Trigger abort crash
    static void triggerAbort();

    // Trigger wild pointer crash
    static void triggerWildPointer();

    // Trigger pure virtual function call crash
    static void triggerPureVirtualCall();
};

} // namespace ftcrash

#endif // FT_CRASH_TEST_H
