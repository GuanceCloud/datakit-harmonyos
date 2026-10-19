import { describe, expect, it } from '@ohos/hypium';
import { WebReplayBatcher, WebReplayBatchClock } from '../../main/ets/components/WebReplayBatcher';
import { ReplayRecordType, SessionReplayContext, SessionReplayRecord } from '../../main/ets/components/SessionReplayProtocol';

interface TimerTask { id: number; at: number; callback: () => void; }
interface BrowserMutationFixture { source: number; text: string; }
class BatchClock implements WebReplayBatchClock {
  private time: number = 1000;
  private nextId: number = 0;
  private tasks: Array<TimerTask> = [];
  public now(): number { return this.time; }
  public schedule(callback: () => void, delay: number): number {
    const id = ++this.nextId;
    this.tasks.push({ id, at: this.time + delay, callback });
    return id;
  }
  public cancel(id: number): void { this.tasks = this.tasks.filter((task: TimerTask): boolean => task.id !== id); }
  public advance(ms: number): void {
    this.time += ms;
    const due = this.tasks.filter((task: TimerTask): boolean => task.at <= this.time);
    for (const task of due) { this.cancel(task.id); task.callback(); }
  }
}

function browserRecord(index: number, text: string = ''): SessionReplayRecord {
  const data: BrowserMutationFixture = { source: 0, text };
  const record: SessionReplayRecord = {
    timestamp: 1700000000000 + index, type: 3 as ReplayRecordType, slotId: 'batch-slot', data
  };
  return record;
}

export default function webReplayBatcherUnitTest() {
  describe('WebReplayBatcherUnit', () => {
    it('flushes 20 records together and retains a persistence guard until enqueue', 0, () => {
      let pending = 0;
      const batches: Array<Array<SessionReplayRecord>> = [];
      const clock = new BatchClock();
      const batcher = new WebReplayBatcher((_context, records): boolean => {
        expect(pending).assertEqual(1);
        batches.push(records);
        return true;
      }, (): (() => void) => { pending++; return (): void => { pending--; }; }, clock);
      const context: SessionReplayContext = { applicationId: 'app', sessionId: 's', viewId: 'browser-a' };
      for (let index = 0; index < 19; index++) expect(batcher.add(context, browserRecord(index))).assertTrue();
      expect(batches.length).assertEqual(0);
      batcher.add(context, browserRecord(19));
      expect(batches[0].length).assertEqual(20);
      expect(pending).assertEqual(0);
      clock.advance(1000);
      expect(batches.length).assertEqual(1);
    });

    it('flushes after 500ms idle or 1s residence and never mixes views or contexts', 0, () => {
      const views: Array<string> = [];
      const counts: Array<number> = [];
      const clock = new BatchClock();
      const batcher = new WebReplayBatcher((context, records): boolean => {
        views.push(context.viewId); counts.push(records.length); return true;
      }, (): (() => void) => (): void => {}, clock);
      const context: SessionReplayContext = { applicationId: 'app', sessionId: 's', viewId: 'browser-a' };
      batcher.add(context, browserRecord(0));
      clock.advance(499);
      expect(views.length).assertEqual(0);
      clock.advance(1);
      expect(counts[0]).assertEqual(1);
      batcher.add(context, browserRecord(1));
      clock.advance(400); batcher.add(context, browserRecord(2));
      clock.advance(400); batcher.add(context, browserRecord(3));
      clock.advance(200);
      expect(counts[1]).assertEqual(3);
      batcher.add(context, browserRecord(4));
      context.viewId = 'browser-b';
      batcher.add(context, browserRecord(5));
      expect(views[2]).assertEqual('browser-a');
      context.globalContext = { 'order_id': 'new' };
      batcher.add(context, browserRecord(6));
      expect(views[3]).assertEqual('browser-b');
      batcher.flush();
      expect(counts.join(',')).assertEqual('1,3,1,1,1');
    });

    it('isolates large full snapshots and reports a rejected writer without leaking guards', 0, () => {
      let pending = 0;
      let writes = 0;
      const batcher = new WebReplayBatcher((_context, records): boolean => {
        writes++;
        expect(records.length).assertEqual(1);
        return false;
      }, (): (() => void) => { pending++; return (): void => { pending--; }; }, new BatchClock());
      const context: SessionReplayContext = { applicationId: 'app', sessionId: 's', viewId: 'browser-a' };
      expect(batcher.add(context, browserRecord(0, '大'.repeat(100000)))).assertFalse();
      expect(writes).assertEqual(1);
      expect(pending).assertEqual(0);
    });
  });
}
