import { FTLoggerConfig } from '../Configs';
import { LogBean } from '../bean/LogBean';
import { Status } from '../bean/Status';
import { Utils } from '../utils/Utils';
import { StringWrapper } from '../utils/StringWrapper';
import { FTInnerLogger } from './FTLogger';
import { TrackLogManager } from './TrackLogManager';

const TAG = 'FTConsoleLogBridge';

type ConsoleLogLevel = 'debug' | 'info' | 'warn' | 'error' | 'fatal' | 'log';

/**
 * Minimal structural type shared by @ohos.hilog and @kit.PerformanceAnalysisKit
 * imports. The compiler plugin passes the imported module as the delegate so
 * the original call is executed exactly once after telemetry is queued.
 */
interface HiLogDelegate {
  debug(domain: number, tag: string, format: string, ...args: Object[]): void;
  info(domain: number, tag: string, format: string, ...args: Object[]): void;
  warn(domain: number, tag: string, format: string, ...args: Object[]): void;
  error(domain: number, tag: string, format: string, ...args: Object[]): void;
  fatal(domain: number, tag: string, format: string, ...args: Object[]): void;
}

/**
 * Minimal structural type for the HarmonyOS console implementation.
 */
interface ConsoleDelegate {
  debug(...args: Object[]): void;
  info(...args: Object[]): void;
  warn(...args: Object[]): void;
  error(...args: Object[]): void;
  log(...args: Object[]): void;
}

/**
 * Runtime contract for the Guance Hvigor console-log compiler plugin.
 *
 * This is not a manual logging API. Application source calls are rewritten to
 * this bridge at build time, while the original console/HiLog call still runs.
 */
export class FTConsoleLogBridge {
  private static compilerPluginInstalled: boolean = false;
  private static missingPluginWarningReported: boolean = false;

  /**
   * Called by transformed application modules. It is intentionally idempotent.
   */
  public static markCompilerPluginInstalled(): void {
    FTConsoleLogBridge.compilerPluginInstalled = true;
  }

  /**
   * Called by SDK initialization after the log configuration is installed.
   */
  public static onLogConfigInstalled(config: FTLoggerConfig): void {
    if (!config.isEnableConsoleLog() || FTConsoleLogBridge.compilerPluginInstalled ||
      FTConsoleLogBridge.missingPluginWarningReported) {
      return;
    }

    FTConsoleLogBridge.missingPluginWarningReported = true;
    FTInnerLogger.w(TAG,
      'Console/HiLog automatic collection is disabled because the Guance Hvigor compiler plugin is not installed. ' +
      'Manual FTLogger logs remain controlled by setEnableCustomLog.');
  }

  /**
   * Runtime target for a transformed hilog.debug/info/warn/error/fatal call.
   */
  public static hilog(delegate: HiLogDelegate, level: ConsoleLogLevel, domain: number, tag: string,
    format: string, ...args: Object[]): void {
    FTConsoleLogBridge.captureHiLog(level, domain, tag, format, args);
    switch (level) {
      case 'debug':
        delegate.debug(domain, tag, format, ...args);
        return;
      case 'info':
        delegate.info(domain, tag, format, ...args);
        return;
      case 'warn':
        delegate.warn(domain, tag, format, ...args);
        return;
      case 'error':
        delegate.error(domain, tag, format, ...args);
        return;
      case 'fatal':
        delegate.fatal(domain, tag, format, ...args);
        return;
      default:
        delegate.info(domain, tag, format, ...args);
    }
  }

  /**
   * Runtime target for a transformed console.log/debug/info/warn/error call.
   */
  public static console(delegate: ConsoleDelegate, level: ConsoleLogLevel, ...args: Object[]): void {
    FTConsoleLogBridge.captureConsole(level, args);
    switch (level) {
      case 'debug':
        delegate.debug(...args);
        return;
      case 'info':
        delegate.info(...args);
        return;
      case 'warn':
        delegate.warn(...args);
        return;
      case 'error':
        delegate.error(...args);
        return;
      default:
        delegate.log(...args);
    }
  }

  public static resetStateInternal(): void {
    FTConsoleLogBridge.compilerPluginInstalled = false;
    FTConsoleLogBridge.missingPluginWarningReported = false;
  }

  private static captureHiLog(level: ConsoleLogLevel, domain: number, tag: string, format: string,
    args: Object[]): void {
    try {
      const logBean = FTConsoleLogBridge.createLogBean(level,
        FTConsoleLogBridge.formatHiLogMessage(format, args));
      logBean.addTag('log_source', new StringWrapper('hilog'));
      logBean.addTag('tag', new StringWrapper(tag));
      logBean.addTag('domain', new StringWrapper(String(domain)));
      TrackLogManager.getInstance().trackConsoleLog(logBean);
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to capture HiLog: ${String(error)}`);
    }
  }

  private static captureConsole(level: ConsoleLogLevel, args: Object[]): void {
    try {
      const logBean = FTConsoleLogBridge.createLogBean(level, FTConsoleLogBridge.formatConsoleMessage(args));
      logBean.addTag('log_source', new StringWrapper('console'));
      TrackLogManager.getInstance().trackConsoleLog(logBean);
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to capture console log: ${String(error)}`);
    }
  }

  private static createLogBean(level: ConsoleLogLevel, content: string): LogBean {
    const logBean = new LogBean(content, Utils.getCurrentTimestamp());
    logBean.setStatus(FTConsoleLogBridge.toStatus(level));
    const config = TrackLogManager.getInstance().getLogConfig();
    if (config !== null) {
      logBean.setServiceName(config.getServiceName());
    }
    return logBean;
  }

  private static toStatus(level: ConsoleLogLevel): string {
    switch (level) {
      case 'debug':
        return Status.DEBUG.name;
      case 'warn':
        return Status.WARN.name;
      case 'error':
        return Status.ERROR.name;
      case 'fatal':
        return Status.FATAL.name;
      default:
        return Status.INFO.name;
    }
  }

  private static formatConsoleMessage(args: Object[]): string {
    const messages: string[] = [];
    for (let index = 0; index < args.length; index++) {
      messages.push(FTConsoleLogBridge.stringify(args[index]));
    }
    return messages.join(' ');
  }

  /**
   * HiLog treats values as private unless a placeholder is explicitly marked
   * %{public}. Preserve that privacy rule in collected telemetry.
   */
  private static formatHiLogMessage(format: string, args: Object[]): string {
    let message = '';
    let argumentIndex = 0;
    let index = 0;
    while (index < format.length) {
      if (format[index] !== '%') {
        message += format[index];
        index++;
        continue;
      }

      if (index + 1 < format.length && format[index + 1] === '%') {
        message += '%';
        index += 2;
        continue;
      }

      const publicPrefix = '%{public}';
      const privatePrefix = '%{private}';
      if (format.startsWith(publicPrefix, index)) {
        const specifierIndex = index + publicPrefix.length;
        if (specifierIndex < format.length) {
          message += argumentIndex < args.length ? FTConsoleLogBridge.stringify(args[argumentIndex]) : '';
          argumentIndex++;
          index = specifierIndex + 1;
          continue;
        }
      }

      if (format.startsWith(privatePrefix, index)) {
        const specifierIndex = index + privatePrefix.length;
        if (specifierIndex < format.length) {
          message += '<private>';
          argumentIndex++;
          index = specifierIndex + 1;
          continue;
        }
      }

      if (index + 1 < format.length && FTConsoleLogBridge.isFormatSpecifier(format[index + 1])) {
        message += '<private>';
        argumentIndex++;
        index += 2;
        continue;
      }

      message += '%';
      index++;
    }
    return message;
  }

  private static isFormatSpecifier(value: string): boolean {
    return value === 'd' || value === 'i' || value === 'o' || value === 'O' || value === 'f' ||
      value === 's' || value === 'c' || value === 'j' || value === 'x' || value === 'X';
  }

  private static stringify(value: Object): string {
    try {
      return String(value);
    } catch (_error) {
      return '<unprintable>';
    }
  }
}
