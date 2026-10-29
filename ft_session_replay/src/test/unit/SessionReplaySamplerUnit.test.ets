import { describe, expect, it } from '@ohos/hypium';
import { FTSessionReplayConfig } from '../../main/ets/components/FTSessionReplayConfig';
import { SessionReplaySampler, SessionReplaySamplingMode } from '../../main/ets/components/SessionReplaySampler';

function expectSampledSessions(
  config: FTSessionReplayConfig,
  sessions: Array<string>,
  sampledCount: number,
  mode: SessionReplaySamplingMode
): void {
  const sampler = new SessionReplaySampler(config);
  for (let index = 0; index < sessions.length; index++) {
    expect(sampler.decide(sessions[index])).assertEqual(
      index < sampledCount ? mode : SessionReplaySamplingMode.NONE);
  }
}

export default function sessionReplaySamplerUnitTest() {
  describe('SessionReplaySamplerUnit', () => {
    it('defaults to full regular sampling and disabled error sampling', 0, () => {
      const config = new FTSessionReplayConfig();
      expect(config.getSampleRate()).assertEqual(100);
      expect(config.getSessionReplayOnErrorSampleRate()).assertEqual(0);
      expect(new SessionReplaySampler(config).decide('default-session'))
        .assertEqual(SessionReplaySamplingMode.REGULAR);
    });

    it('keeps both setters and getters in percentage units including values below one', 0, () => {
      const config = new FTSessionReplayConfig();
      for (const rate of [0, 0.1, 1, 2, 25.5, 99.9, 100]) {
        expect(config.setSampleRate(rate).getSampleRate()).assertEqual(rate);
        expect(config.setSessionReplayOnErrorSampleRate(rate).getSessionReplayOnErrorSampleRate())
          .assertEqual(rate);
      }
    });

    it('bounds percentages and disables sampling for non-finite values', 0, () => {
      const config = new FTSessionReplayConfig();
      expect(config.setSampleRate(-1).getSampleRate()).assertEqual(0);
      expect(config.setSampleRate(101).getSampleRate()).assertEqual(100);
      expect(config.setSessionReplayOnErrorSampleRate(-1).getSessionReplayOnErrorSampleRate()).assertEqual(0);
      expect(config.setSessionReplayOnErrorSampleRate(101).getSessionReplayOnErrorSampleRate()).assertEqual(100);
      for (const rate of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY]) {
        expect(config.setSampleRate(rate).getSampleRate()).assertEqual(0);
        expect(config.setSessionReplayOnErrorSampleRate(rate).getSessionReplayOnErrorSampleRate())
          .assertEqual(0);
      }
    });

    it('samples regular sessions at zero, fractional, one, ten and full percentages', 0, () => {
      // Fixed session buckets: 0.0447%, 0.8031%, 9.8670%, and 75.0904%.
      const sessions = ['sampling-session-543', 'sampling-session-529',
        'sampling-session-16', 'sampling-session-0'];
      const rates = [0, 0.1, 1, 10, 100];
      const sampledCounts = [0, 1, 2, 3, 4];
      for (let index = 0; index < rates.length; index++) {
        expectSampledSessions(new FTSessionReplayConfig().setSampleRate(rates[index]),
          sessions, sampledCounts[index], SessionReplaySamplingMode.REGULAR);
      }
    });

    it('samples error sessions at zero, fractional, one, ten and full percentages', 0, () => {
      // Fixed error-session buckets: 0.0233%, 0.1266%, 1.8275%, and 19.9097%.
      const sessions = ['sampling-session-749', 'sampling-session-162',
        'sampling-session-8', 'sampling-session-0'];
      const rates = [0, 0.1, 1, 10, 100];
      const sampledCounts = [0, 1, 2, 3, 4];
      for (let index = 0; index < rates.length; index++) {
        expectSampledSessions(new FTSessionReplayConfig().setSampleRate(0)
          .setSessionReplayOnErrorSampleRate(rates[index]),
          sessions, sampledCounts[index], SessionReplaySamplingMode.ERROR);
      }
    });

    it('tries regular sampling before error sampling', 0, () => {
      const config = new FTSessionReplayConfig().setSampleRate(1)
        .setSessionReplayOnErrorSampleRate(100);
      const sampler = new SessionReplaySampler(config);
      expect(sampler.decide('sampling-session-543')).assertEqual(SessionReplaySamplingMode.REGULAR);
      expect(sampler.decide('sampling-session-0')).assertEqual(SessionReplaySamplingMode.ERROR);
    });

    it('retains a session decision until cleared or reset', 0, () => {
      const config = new FTSessionReplayConfig().setSampleRate(100);
      const sampler = new SessionReplaySampler(config);
      expect(sampler.decide('sticky-session')).assertEqual(SessionReplaySamplingMode.REGULAR);
      config.setSampleRate(0);
      expect(sampler.decide('sticky-session')).assertEqual(SessionReplaySamplingMode.REGULAR);
      sampler.clear('sticky-session');
      expect(sampler.decide('sticky-session')).assertEqual(SessionReplaySamplingMode.NONE);
      config.setSessionReplayOnErrorSampleRate(100);
      expect(sampler.decide('sticky-session')).assertEqual(SessionReplaySamplingMode.NONE);
      sampler.reset();
      expect(sampler.decide('sticky-session')).assertEqual(SessionReplaySamplingMode.ERROR);
    });
  });
}
