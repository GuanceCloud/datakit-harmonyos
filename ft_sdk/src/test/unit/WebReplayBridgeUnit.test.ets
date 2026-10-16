import { describe, expect, it } from '@ohos/hypium';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { FTRUMConfig } from '../../main/ets/components/Configs';
import { FTRUMConfigManager } from '../../main/ets/components/rum/FTRUMConfigManager';
import { FTRUMInnerManager } from '../../main/ets/components/rum/FTRUMInnerManager';
import { FTWebViewHandler } from '../../main/ets/components/web/FTWebViewHandler';
import { FTWebViewReplayBridge } from '../../main/ets/components/web/FTWebViewReplayBridge';
import { FTSessionReplayBridge, FTSessionReplayBridgeRegistry, FTSessionReplayRUMContext,
  FTSessionReplayErrorContext, FTSessionReplaySessionContext, FTSessionReplayViewMetadata,
  FTSessionReplayWebDataContext, FTSessionReplayWebViewOptions } from '../../main/ets/components/sessionreplay/FTSessionReplayBridge';

class ReplayBridgeFixture implements FTSessionReplayBridge {
  public views: Array<string> = [];
  public slots: Array<string> = [];
  public getRUMLinkKeys(): Array<string> { return []; }
  public getViewMetadata(_context: FTSessionReplayRUMContext): FTSessionReplayViewMetadata {
    return { hasReplay: false, recordsCount: 0, sampledOnError: false };
  }
  public onViewStarted(_context: FTSessionReplayRUMContext): boolean { return false; }
  public onViewStopped(_context: FTSessionReplayRUMContext): void {}
  public onError(_context: FTSessionReplayErrorContext): boolean { return false; }
  public onSessionRenewed(_context: FTSessionReplaySessionContext): void {}
  public getWebViewOptions(): FTSessionReplayWebViewOptions { return { privacyLevel: 'mask', capabilities: ['records'] }; }
  public onWebReplayData(context: FTSessionReplayWebDataContext): boolean {
    this.views.push(context.viewId);
    this.slots.push(context.slotId);
    return true;
  }
}

class ReplayControllerFixture {
  public snapshotRequests: number = 0;
  public registerJavaScriptProxy(_receiver: Object, _name: string, _methods: Array<string>): void {}
  public deleteJavaScriptRegister(_name: string): void {}
  public runJavaScript(_script: string, callback: (error?: BusinessError<void>) => void): void {
    this.snapshotRequests++;
    callback();
  }
}

function rrwebEvent(viewId: string): string {
  return `{"name":"session_replay","view":{"id":"${viewId}"},"data":{"timestamp":1700000000000,"type":2,"data":{"node":{"id":1}}}}`;
}

export default function webReplayBridgeUnitTest() {
  describe('WebReplayBridgeUnit', () => {
    it('shares network availability with Replay and notifies only on transitions', 0, () => {
      const registry = FTSessionReplayBridgeRegistry;
      const updates: Array<boolean> = [];
      registry.updateReplayUploadNetworkAvailability(null);
      registry.setReplayUploadNetworkListener((available: boolean): void => updates.push(available));
      try {
        expect(registry.getReplayUploadNetworkAvailability()).assertNull();
        registry.updateReplayUploadNetworkAvailability(false);
        registry.updateReplayUploadNetworkAvailability(false);
        registry.updateReplayUploadNetworkAvailability(true);
        expect(updates.join(',')).assertEqual('false,true');
        expect(registry.getReplayUploadNetworkAvailability()).assertTrue();
      } finally {
        registry.setReplayUploadNetworkListener(null);
        registry.updateReplayUploadNetworkAvailability(null);
      }
    });

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
        handler.setWebView(controller);
        const componentId = FTWebViewReplayBridge.bindingId(controller);
        expect(handler.getSessionReplaySlotId()).assertEqual('');
        // Declarative proxy registration happens before a native frame exists.
        const oldReceiver = handler.getMessageReceiver();
        const sessionId = FTRUMInnerManager.getInstance().getSessionId();
        registry.observeWebReplaySlots('bridge-app', sessionId, 'native-container',
          [{ componentId, slotId: '1000000126' }], Date.now());
        expect(handler.getSessionReplaySlotId()).assertEqual('1000000126');
        oldReceiver.sendEvent(rrwebEvent('browser-before-rum'));
        expect(bridge.views.join(',')).assertEqual('browser-before-rum');
        expect(bridge.slots[0]).assertEqual('1000000126');
        const replacement = new ReplayControllerFixture() as Object as webview.WebviewController;
        handler.setWebView(replacement);
        registry.observeWebReplaySlots('bridge-app', sessionId, 'native-container',
          [{ componentId: FTWebViewReplayBridge.bindingId(replacement), slotId: '1000000127' }], Date.now());
        oldReceiver.sendEvent(rrwebEvent('stale-browser'));
        handler.getMessageReceiver().sendEvent(rrwebEvent('replacement-browser'));
        expect(bridge.views.join(',')).assertEqual('browser-before-rum,replacement-browser');
        expect(bridge.slots.join(',')).assertEqual('1000000126,1000000127');
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

    it('requests a fresh DOM snapshot only at active native binding boundaries', 0, async () => {
      const manager = FTRUMConfigManager.getInstance();
      const previous = manager.getConfig();
      const config = new FTRUMConfig().setRumAppId('binding-app').setEnableTraceWebView(true);
      manager.initWithConfig(config);
      const registry = FTSessionReplayBridgeRegistry;
      const bridge = new ReplayBridgeFixture();
      const handler = new FTWebViewHandler();
      const controller = new ReplayControllerFixture();
      registry.register(bridge);
      registry.setWebReplayAppForeground(true);
      try {
        handler.setWebView(controller as Object as webview.WebviewController);
        const componentId = FTWebViewReplayBridge.bindingId(controller);
        const session = FTRUMInnerManager.getInstance().getSessionId();
        const observe = (slotId: string, view: string = 'native'): void => {
          registry.observeWebReplaySlots('binding-app', session, view,
            [{ componentId, slotId }], Date.now());
        };
        observe('1001');
        await new Promise<void>((resolve): void => { setTimeout(resolve, 10); });
        expect(controller.snapshotRequests).assertEqual(1);
        observe('1001');
        await new Promise<void>((resolve): void => { setTimeout(resolve, 10); });
        expect(controller.snapshotRequests).assertEqual(1);
        // The same JS proxy survives a new native root epoch/node ID.
        const receiver = handler.getMessageReceiver();
        observe('2001');
        await new Promise<void>((resolve): void => { setTimeout(resolve, 10); });
        expect(controller.snapshotRequests).assertEqual(2);
        receiver.sendEvent(rrwebEvent('same-document'));
        expect(bridge.slots[0]).assertEqual('2001');
        observe('2001', 'next-native');
        await new Promise<void>((resolve): void => { setTimeout(resolve, 10); });
        expect(controller.snapshotRequests).assertEqual(3);
        registry.observeWebReplaySlots('binding-app', session, 'next-native', [], Date.now());
        await new Promise<void>((resolve): void => { setTimeout(resolve, 10); });
        expect(controller.snapshotRequests).assertEqual(3);
        observe('2001', 'next-native');
        await new Promise<void>((resolve): void => { setTimeout(resolve, 10); });
        expect(controller.snapshotRequests).assertEqual(4);
        registry.setWebReplayAppForeground(false);
        expect(controller.snapshotRequests).assertEqual(4);
        registry.setWebReplayAppForeground(true);
        expect(controller.snapshotRequests).assertEqual(5);
        registry.unregister(bridge);
        registry.register(bridge);
        observe('2001', 'next-native');
        await new Promise<void>((resolve): void => { setTimeout(resolve, 10); });
        expect(controller.snapshotRequests).assertEqual(6);
      } finally {
        handler.clearWebController();
        registry.unregister(bridge);
        if (previous !== null) manager.initWithConfig(previous);
        else FTRUMConfigManager.resetStateInternal();
      }
    });

    it('does not let a duplicate handler unregister the original controller binding', 0, () => {
      const manager = FTRUMConfigManager.getInstance();
      const previous = manager.getConfig();
      manager.initWithConfig(new FTRUMConfig().setRumAppId('duplicate-app').setEnableTraceWebView(true));
      const owner = new FTWebViewHandler();
      const duplicate = new FTWebViewHandler();
      const controller = new ReplayControllerFixture() as Object as webview.WebviewController;
      const componentId = FTWebViewReplayBridge.bindingId(controller);
      const registry = FTSessionReplayBridgeRegistry;
      try {
        owner.setWebView(controller);
        duplicate.setWebView(controller);
        duplicate.clearWebController();
        expect(registry.getWebReplayComponentBinding(componentId) !== null).assertTrue();
        expect(duplicate.getSessionReplayCapabilities()).assertNull();
      } finally {
        owner.clearWebController();
        duplicate.clearWebController();
        if (previous !== null) manager.initWithConfig(previous);
        else FTRUMConfigManager.resetStateInternal();
      }
    });
  });
}
