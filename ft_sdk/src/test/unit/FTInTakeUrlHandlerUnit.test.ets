import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTInTakeUrlHandler } from '../../main/ets/components/http/FTInTakeUrlHandler';
import { TestReset } from '../helpers/TestReset';

export default function ftInTakeUrlHandlerUnitTest() {
  describe('FTInTakeUrlHandlerUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('defaultHandlerShouldIgnoreInvalidDefaultAndInternalUrls', 0, () => {
      const handler = new FTInTakeUrlHandler();

      expect(handler.isInTakeUrl('')).assertTrue();
      expect(handler.isInTakeUrl('file:///tmp/index.html')).assertTrue();
      expect(handler.isInTakeUrl('https://dataway.guance.com/v1/write')).assertTrue();
      expect(handler.isInTakeUrl('https://example.com/api')).assertFalse();
    });

    it('customRulesShouldMatchPatternAndExactUrl', 0, () => {
      const handler = new FTInTakeUrlHandler({
        customIgnorePatterns: ['secret'],
        customIgnoreUrls: ['https://example.com/ignored'],
        enableLogging: true
      });

      expect(handler.getConfig().customIgnorePatternsCount).assertEqual(1);
      expect(handler.getConfig().customIgnoreUrlsCount).assertEqual(1);
      expect(handler.isInTakeUrl('https://example.com/ignored')).assertTrue();
      expect(handler.isInTakeUrl('https://example.com/secret/path')).assertTrue();

      handler.addIgnorePatterns([/private/i]);
      handler.addIgnoreUrls(['', 'HTTPS://EXAMPLE.COM/CAPS']);

      expect(handler.getConfig().customIgnorePatternsCount).assertEqual(2);
      expect(handler.getConfig().customIgnoreUrlsCount).assertEqual(2);
      expect(handler.isInTakeUrl('https://example.com/private/path')).assertTrue();
      expect(handler.isInTakeUrl('https://example.com/caps')).assertTrue();
    });

    it('configUpdateShouldToggleDefaultAndInternalPatterns', 0, () => {
      const handler = new FTInTakeUrlHandler({
        ignoreInternalUrls: false,
        ignoreDefaultPatterns: false,
        enableLogging: false
      });

      expect(handler.isInTakeUrl('file:///tmp/index.html')).assertFalse();
      expect(handler.isInTakeUrl('https://dataway.guance.com/v1/write')).assertFalse();

      handler.updateConfig({
        ignoreInternalUrls: true,
        ignoreDefaultPatterns: true,
        enableLogging: true
      });

      expect(handler.getConfig().ignoreInternalUrls).assertTrue();
      expect(handler.getConfig().ignoreDefaultPatterns).assertTrue();
      expect(handler.isInTakeUrl('file:///tmp/index.html')).assertTrue();
      expect(handler.isInTakeUrl('https://dataway.guance.com/v1/write')).assertTrue();
    });

    it('removeAndClearRulesShouldBeStableForExistingAndMissingRules', 0, () => {
      const handler = new FTInTakeUrlHandler({
        ignoreInternalUrls: false,
        ignoreDefaultPatterns: false
      });

      handler.addIgnorePatterns([/block-me/i]);
      handler.addIgnoreUrls(['https://example.com/remove']);
      expect(handler.isInTakeUrl('https://example.com/block-me')).assertTrue();
      expect(handler.isInTakeUrl('https://example.com/remove')).assertTrue();

      handler.removeIgnorePattern(/block-me/i);
      handler.removeIgnorePattern(/block-me/i);
      handler.removeIgnoreUrl('https://example.com/remove');
      handler.removeIgnoreUrl('https://example.com/remove');
      expect(handler.isInTakeUrl('https://example.com/block-me')).assertFalse();
      expect(handler.isInTakeUrl('https://example.com/remove')).assertFalse();

      handler.addIgnorePatterns([/again/i]);
      handler.addIgnoreUrls(['https://example.com/again']);
      handler.clearCustomRules();
      expect(handler.getConfig().customIgnorePatternsCount).assertEqual(0);
      expect(handler.getConfig().customIgnoreUrlsCount).assertEqual(0);
      expect(handler.isInTakeUrl('https://example.com/again')).assertFalse();
    });

    it('invalidPatternShouldBeCaughtAndKeepExistingRules', 0, () => {
      const handler = new FTInTakeUrlHandler();

      handler.addIgnorePatterns(['[']);

      expect(handler.getConfig().customIgnorePatternsCount).assertEqual(0);
      expect(handler.isInTakeUrl('https://example.com/normal')).assertFalse();
    });
  });
}
