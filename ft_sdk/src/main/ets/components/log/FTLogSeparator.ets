import { FTInnerLogger } from './FTLogger';

/**
 * Emits visually distinct lifecycle markers without changing the existing
 * component-level diagnostic messages. Keep these markers sparse: they denote
 * a completed or newly entered SDK phase, not every internal operation.
 */
export class FTLogSeparator {
  private static readonly INITIALIZATION_LINE = '='.repeat(26);
  private static readonly DATA_LINE = '-'.repeat(26);

  public static initialization(tag: string, title: string): void {
    FTInnerLogger.i(tag, `${FTLogSeparator.INITIALIZATION_LINE} ${title} ${FTLogSeparator.INITIALIZATION_LINE}`);
  }

  public static data(tag: string, title: string): void {
    FTInnerLogger.i(tag, `${FTLogSeparator.DATA_LINE} ${title} ${FTLogSeparator.DATA_LINE}`);
  }
}
