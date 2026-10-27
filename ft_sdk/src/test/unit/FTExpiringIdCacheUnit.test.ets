import { describe, it, expect } from '@ohos/hypium';
import { FTExpiringIdCache } from '../../main/ets/components/utils/FTExpiringIdCache';

export default function ftExpiringIdCacheUnitTest() {
  describe('FTExpiringIdCacheUnit', () => {
    it('capacity evicts only the oldest completion', 0, () => {
      const cache = new FTExpiringIdCache(2, 1000);
      try {
        cache.add('old');
        cache.add('recent');
        cache.add('new');
        expect(cache.size).assertEqual(2);
        expect(cache.has('old')).assertFalse();
        expect(cache.has('recent')).assertTrue();
        expect(cache.has('new')).assertTrue();
      } finally { cache.clear(); }
    });

    it('late duplicates do not extend the completion window', 0, () => {
      let now = 0;
      const cache = new FTExpiringIdCache(2, 100, (): number => now);
      try {
        cache.add('first');
        now = 50;
        cache.add('second');
        now = 90;
        cache.add('first');
        expect(cache.has('first')).assertTrue();
        now = 100;
        expect(cache.has('first')).assertFalse();
        expect(cache.has('second')).assertTrue();
        now = 150;
        expect(cache.size).assertEqual(0);
      } finally { cache.clear(); }
    });

    it('repeated failed IDs leave no stale order entries', 0, () => {
      const cache = new FTExpiringIdCache(2, 1000);
      try {
        cache.add('anchor');
        for (let i = 0; i < 10000; i++) {
          const failed = `failed-${i}`;
          cache.add(failed);
          cache.delete(failed);
        }
        expect(cache.size).assertEqual(1);
        expect(cache.has('anchor')).assertTrue();
        cache.add('second');
        cache.add('third');
        expect(cache.has('anchor')).assertFalse();
        expect(cache.size).assertEqual(2);
      } finally { cache.clear(); }
    });

    it('expiration timer runs even without more requests', 0, async () => {
      let now = 0;
      let reads = 0;
      const cache = new FTExpiringIdCache(2, 10, (): number => { reads++; return now; });
      try {
        cache.add('idle');
        const readsBeforeIdle = reads;
        now = 10;
        await new Promise<void>((resolve) => { setTimeout(resolve, 30); });
        expect(reads > readsBeforeIdle).assertTrue();
        expect(cache.size).assertEqual(0);
      } finally { cache.clear(); }
    });

    it('clear cancels the old window and permits a fresh completion', 0, () => {
      let now = 0;
      const cache = new FTExpiringIdCache(2, 100, (): number => now);
      try {
        cache.add('same-id');
        cache.clear();
        expect(cache.size).assertEqual(0);
        now = 50;
        cache.add('same-id');
        now = 100;
        expect(cache.has('same-id')).assertTrue();
        now = 150;
        expect(cache.has('same-id')).assertFalse();
      } finally { cache.clear(); }
    });
  });
}
