import { Context } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FTInnerLogger } from '../log/FTLogger';
import { AppUtils } from './AppUtils';

interface SDKProcessContext {
  processName?: string;
}

/** Check before SDK initialization can read or write shared application data. */
export class SDKProcessGuard {
  public static canInstall(onlyMainProcess: boolean, context?: Context): boolean {
    if (!onlyMainProcess) {
      return true;
    }
    try {
      const applicationInfo = context?.applicationInfo ?? AppUtils.getAppInfo();
      const mainProcessName = (applicationInfo.process || applicationInfo.name || '').trim();
      const currentProcessName = SDKProcessGuard.getCurrentProcessName(context);
      if (mainProcessName.length === 0 || currentProcessName.length === 0) {
        FTInnerLogger.w('FTSDK', 'Unable to verify the main process; continuing SDK installation');
        return true;
      }
      if (currentProcessName === mainProcessName) {
        return true;
      }
      FTInnerLogger.e('FTSDK', `SDK installation skipped: main process=${mainProcessName}, ` +
        `current process=${currentProcessName}. setOnlySupportMainProcess(false) allows other processes.`);
    } catch (error) {
      // A process metadata failure must not disable application monitoring.
      FTInnerLogger.w('FTSDK', `Unable to verify the main process; continuing SDK installation: ${error}`);
      return true;
    }
    return false;
  }

  private static getCurrentProcessName(context?: Context): string {
    // Context.processName is available from API 18. Read it structurally so
    // API 12 installations can use the synchronous procfs fallback.
    try {
      const processName = (context as SDKProcessContext | undefined)?.processName;
      if (typeof processName === 'string' && processName.trim().length > 0) {
        return processName.trim();
      }
    } catch (_error) {
      // A missing platform property must not prevent the API 12 fallback.
    }
    const file = fs.openSync('/proc/self/cmdline', fs.OpenMode.READ_ONLY);
    try {
      // procfs reports a zero file size; read a bounded buffer rather than
      // using a text-file helper that may depend on stat().size.
      const buffer = new ArrayBuffer(4096);
      const count = fs.readSync(file.fd, buffer);
      const commandLine = util.TextDecoder.create('utf-8')
        .decodeWithStream(new Uint8Array(buffer, 0, count), { stream: false });
      const terminator = commandLine.indexOf('\0');
      if (terminator < 0 && count === buffer.byteLength) {
        throw new Error('Current process name is truncated');
      }
      return (terminator < 0 ? commandLine : commandLine.substring(0, terminator)).trim();
    } finally {
      fs.closeSync(file);
    }
  }
}
