import { ActionSourceType } from '../enum/ActionSourceType';
import { FrameNode } from '@kit.ArkUI';

/**
 * Action event wrapper
 * Contains information about a user action event
 * Aligned with Android SDK: ActionEventWrapper
 */
export class ActionEventWrapper {
  private source: FrameNode | null;
  private sourceType: ActionSourceType;
  private extra: Record<string, object> | null;

  constructor(source: FrameNode | null, sourceType: ActionSourceType, extra: Record<string, object> | null = null) {
    this.source = source;
    this.sourceType = sourceType;
    this.extra = extra;
  }

  public getSource(): FrameNode | null {
    return this.source;
  }

  public getSourceType(): ActionSourceType {
    return this.sourceType;
  }

  public getExtra(): Record<string, object> | null {
    return this.extra;
  }
}

