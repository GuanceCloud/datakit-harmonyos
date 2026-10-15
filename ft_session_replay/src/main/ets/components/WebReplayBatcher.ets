import { copyReplayValue, replayValuesEqual } from './ReplayWireframeValues';
import { SessionReplayContext, SessionReplayRecord } from './SessionReplayProtocol';

export interface WebReplayBatchClock {
  now(): number;
  schedule(callback: () => void, delay: number): number;
  cancel(id: number): void;
}

class SystemWebReplayBatchClock implements WebReplayBatchClock {
  public now(): number { return Date.now(); }
  public schedule(callback: () => void, delay: number): number { return setTimeout(callback, delay); }
  public cancel(id: number): void { clearTimeout(id); }
}

interface WebReplayBatch {
  context: SessionReplayContext;
  slotId: string;
  records: Array<SessionReplayRecord>;
  bytes: number;
  startedAt: number;
  completePersistence: () => void;
}

/** Count UTF-8 bytes without allocating another native buffer for a large DOM snapshot. */
function utf8Size(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code < 0x80) bytes++;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xD800 && code <= 0xDBFF && index + 1 < value.length &&
      value.charCodeAt(index + 1) >= 0xDC00 && value.charCodeAt(index + 1) <= 0xDFFF) {
      bytes += 4; index++;
    } else bytes += 3;
  }
  return bytes;
}

/** Browser records stay opaque; never merge DOM mutations using the native mutation grammar. */
export class WebReplayBatcher {
  private batch: WebReplayBatch | null = null;
  private timer: number = -1;
  private readonly clock: WebReplayBatchClock;
  private readonly write: (context: SessionReplayContext, records: Array<SessionReplayRecord>, reason: string) => boolean;
  private readonly beginPersistence: (context: SessionReplayContext) => (() => void);

  constructor(
    write: (context: SessionReplayContext, records: Array<SessionReplayRecord>, reason: string) => boolean,
    beginPersistence: (context: SessionReplayContext) => (() => void),
    clock: WebReplayBatchClock = new SystemWebReplayBatchClock()
  ) {
    this.write = write;
    this.beginPersistence = beginPersistence;
    this.clock = clock;
  }

  public add(context: SessionReplayContext, record: SessionReplayRecord): boolean {
    if (record.slotId === undefined) return false;
    const bytes = utf8Size(JSON.stringify(record));
    let batch = this.batch;
    if (batch !== null && (batch.slotId !== record.slotId || !replayValuesEqual(batch.context, context) ||
      batch.bytes + bytes > 256 * 1024)) {
      if (!this.flush('boundary')) return false;
      batch = null;
    }
    if (batch === null) {
      const immutableContext = copyReplayValue(context) as SessionReplayContext;
      batch = {
        context: immutableContext, slotId: record.slotId, records: [], bytes: 0, startedAt: this.clock.now(),
        completePersistence: this.beginPersistence(immutableContext)
      };
      this.batch = batch;
    }
    batch.records.push(copyReplayValue(record) as SessionReplayRecord);
    batch.bytes += bytes;
    if (batch.records.length >= 20 || batch.bytes >= 256 * 1024) return this.flush('size');
    if (this.timer !== -1) this.clock.cancel(this.timer);
    // Android's 500ms debounce plus a 1s maximum residence time prevents slow streams starving.
    this.timer = this.clock.schedule((): void => { this.flush('timeout'); },
      Math.max(0, Math.min(500, 1000 - (this.clock.now() - batch.startedAt))));
    return true;
  }

  public flush(reason: string = 'explicit'): boolean {
    if (this.timer !== -1) this.clock.cancel(this.timer);
    this.timer = -1;
    const batch = this.batch;
    if (batch === null) return true;
    this.batch = null;
    try {
      return this.write(batch.context, batch.records, reason);
    } finally {
      // Writer creates its own persistence guard before this buffer guard is released.
      batch.completePersistence();
    }
  }
}
