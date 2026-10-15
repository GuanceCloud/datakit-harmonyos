import { describe, expect, it } from '@ohos/hypium';
import { webview } from '@kit.ArkWeb';
import { FTRUMConfig } from '../../main/ets/components/Configs';
import { FTRUMConfigManager } from '../../main/ets/components/rum/FTRUMConfigManager';
import { FTRUMInnerManager } from '../../main/ets/components/rum/FTRUMInnerManager';
import { FTWebViewHandler } from '../../main/ets/components/web/FTWebViewHandler';
import { FTSessionReplayBridge, FTSessionReplayBridgeRegistry, FTSessionReplayRUMContext,
  FTSessionReplayErrorContext, FTSessionReplaySessionContext, FTSessionReplayViewMetadata,
  FTSessionReplayWebDataContext, FTSessionReplayWebViewOptions } from '../../main/ets/components/sessionreplay/FTSessionReplayBridge';

class ReplayBridgeFixture implements FTSessionReplayBridge {
  public views: Array<string> = [];
  public getRUMLinkKeys(): Array<string> { return []; }
  public getViewMetadata(_context: FTSessionReplayRUMContext): FTSessionReplayViewMetadata {
    return { hasReplay: false, recordsCount: 0, sampledOnError: false };
  }
  public onViewStarted(_context: FTSessionReplayRUMContext): boolean { return false; }
  public onViewStopped(_context: FTSessionReplayRUMContext): void {}
  public onError(_context: FTSessionReplayErrorContext): boolean { return false; }
  public onSessionRenewed(_context: FTSessionReplaySessionContext): void {}
  public getWebViewOptions(): FTSessionReplayWebViewOptions { return { privacyLevel: 'mask', capabilities: ['records'] }; }
  public onWebReplayData(context: FTSessionReplayWebDataContext): boolean { this.views.push(context.viewId); return true; }
}

class ReplayControllerFixture {
  public registerJavaScriptProxy(_receiver: Object, _name: string, _methods: Array<string>): void {}
  public deleteJavaScriptRegister(_name: string): void {}
}

function rrwebEvent(viewId: string): string {
  return `{"name":"session_replay","view":{"id":"${viewId}"},"data":{"timestamp":1700000000000,"type":2,"data":{"node":{"id":1}}}}`;
}

export default function webReplayBridgeUnitTest() {
  describe('WebReplayBridgeUnit', () => {
    it('uses Browser view.id before RUM arrives and rejects a detached JS proxy after replacement', 0, () => {
      const manager = FTRUMConfigManager.getInstance();
      const previous = manager.getConfig();
      const config = new FTRUMConfig().setRumAppId('bridge-app').setEnableTraceWebView(true);
      manager.initWithConfig(config);
      const bridge = new ReplayBridgeFixture();
      const registry = FTSessionReplayBridgeRegistry;
      registry.register(bridge);
      registry.setWebReplayAppForeground(true);
      const handler = new FTWebViewHandler();
      try {
        const controller = new ReplayControllerFixture() as Object as webview.WebviewController;
        handler.setWebView(controller, config, 'bridge-test-web');
        const slot = handler.getSessionReplaySlotId();
        const sessionId = FTRUMInnerManager.getInstance().getSessionId();
        registry.observeWebReplaySlots('bridge-app', sessionId, 'native-container', [slot], Date.now());
        const oldReceiver = handler.getMessageReceiver();
        oldReceiver.sendEvent(rrwebEvent('browser-before-rum'));
        expect(bridge.views.join(',')).assertEqual('browser-before-rum');
        handler.setWebView(new ReplayControllerFixture() as Object as webview.WebviewController, config, 'bridge-test-web');
        registry.observeWebReplaySlots('bridge-app', sessionId, 'native-container',
          [handler.getSessionReplaySlotId()], Date.now());
        oldReceiver.sendEvent(rrwebEvent('stale-browser'));
        handler.getMessageReceiver().sendEvent(rrwebEvent('replacement-browser'));
        expect(bridge.views.join(',')).assertEqual('browser-before-rum,replacement-browser');
        config.setEnableTraceWebView(false);
        handler.getMessageReceiver().sendEvent(rrwebEvent('disabled-tracing'));
        expect(bridge.views.length).assertEqual(2);
      } finally {
        handler.clearWebController();
        registry.unregister(bridge);
        if (previous !== null) manager.initWithConfig(previous);
        else FTRUMConfigManager.resetStateInternal();
      }
    });
  });
}
