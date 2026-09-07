import { describe, expect, it } from '@ohos/hypium';
import { StressLogTimestampSequencer } from '../../../main/ets/utils/StressLogTimestampSequencer';

export default function stressLogTimestampSequencerTest() {
  describe('StressLogTimestampSequencerTest', () => {
    it('keepLargeSameTickBatchStrictlyOrdered', 0, () => {
      const sequencer = new StressLogTimestampSequencer();
      const fixedNowMs = 1700000000000;
      const firstTimestampMs = sequencer.next(fixedNowMs);
      let previousTimestampMs = firstTimestampMs;

      for (let i = 1; i < 2000; i++) {
        const timestampMs = sequencer.next(fixedNowMs);
        expect(timestampMs > previousTimestampMs).assertTrue();
        previousTimestampMs = timestampMs;
      }

      expect(previousTimestampMs - firstTimestampMs < 3).assertTrue();
    });

    it('frozenClockKeepsOrderAcrossResets', 0, () => {
      const sequencer = new StressLogTimestampSequencer();
      const firstTimestampMs = sequencer.next(1700000001000);
      const secondTimestampMs = sequencer.next(1700000000000);

      expect(secondTimestampMs > firstTimestampMs).assertTrue();

      sequencer.reset();
      expect(sequencer.next(1700000000000)).assertEqual(1700000000000);
    });
  });
}
