import { describe, expect, it } from '@ohos/hypium';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { FTRUMConfig, FTSDKConfig } from '../../main/ets/components/Configs';
import { FTWebViewHostPolicy } from '../../main/ets/components/web/FTWebViewHostPolicy';
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
  public payloads: Array<string> = [];
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
    this.payloads.push(context.payload);
    return true;
  }
}

class ReplayControllerFixture {
  public url: string = 'https://sub.example.com/replay';
  public getUrl(): string { return this.url; }
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
    it('uses the same Host decision for privacy capabilities and Replay records', 0, () => {
      const manager = FTRUMConfigManager.getInstance();
      const previous = manager.getConfig();
      manager.initWithConfig(new FTRUMConfig().setRumAppId('host-replay-app').setEnableTraceWebView(true));
      const base = FTSDKConfig.builder('http://localhost').setAllowWebViewHost(['example.com']);
      FTWebViewHostPolicy.install(base);
      const registry = FTSessionReplayBridgeRegistry;
      const bridge = new ReplayBridgeFixture();
      const handler = new FTWebViewHandler();
      const controller = new ReplayControllerFixture();
      registry.register(bridge);
      try {
        handler.getJavaScriptProxy(controller as Object as webview.WebviewController);
        const componentId = FTWebViewReplayBridge.bindingId(controller);
        registry.observeWebReplaySlots('host-replay-app', FTRUMInnerManager.getInstance().getSessionId(),
          'native-host', [{ componentId, slotId: '9001' }], Date.now());
        const receiver = handler.getMessageReceiver();
        expect(receiver.getCapabilities()).assertEqual('["records"]');
        expect(receiver.getPrivacyLevel()).assertEqual('mask');
        receiver.sendEvent(rrwebEvent('allowed-host'));
        expect(bridge.views.join(',')).assertEqual('allowed-host');
        controller.url = 'https://example.com.evil.test/replay';
        expect(receiver.getCapabilities()).assertNull();
        expect(receiver.getPrivacyLevel()).assertNull();
        receiver.sendEvent(rrwebEvent('denied-host'));
        expect(bridge.views.length).assertEqual(1);
        base.setAllowWebViewHost([]);
        controller.url = 'https://example.com';
        expect(receiver.getCapabilities()).assertEqual('["records"]');
        handler.clearWebController();
        handler.setWebView(controller as Object as webview.WebviewController);
        expect(handler.getMessageReceiver().getCapabilities()).assertNull();
        expect(receiver.getAllowedWebViewHosts()).assertEqual('[]');
        expect(receiver.getCapabilities()).assertNull();
      } finally {
        handler.clearWebController();
        registry.unregister(bridge);
        FTWebViewHostPolicy.install(null);
        if (previous !== null) manager.initWithConfig(previous);
        else FTRUMConfigManager.resetStateInternal();
      }
    });

    it('shares network availability with Replay and notifies only on transitions', 0, () => {
      const registry = FTSessionReplayBridgeRegistry;
      const updates: Array<boolean> = [];
      registry.updateReplayUploadNetworkAvailability(null);
      registry.setReplayUploadNetworkListener((available: boolean): void => { updates.push(available); });
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

    it('publishes native Web viewport changes without requesting another DOM snapshot', 0, async () => {
      const manager = FTRUMConfigManager.getInstance();
      const previous = manager.getConfig();
      manager.initWithConfig(new FTRUMConfig().setRumAppId('viewport-app').setEnableTraceWebView(true));
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
        registry.observeWebReplaySlots('viewport-app', session, 'native-view',
          [{ componentId, slotId: '3001', width: 320, height: 480 }], Date.now());
        await new Promise<void>((resolve): void => { setTimeout(resolve, 10); });
        handler.getMessageReceiver().sendEvent(rrwebEvent('browser-view'));
        expect(bridge.payloads.length).assertEqual(1);
        registry.observeWebReplaySlots('viewport-app', session, 'native-view',
          [{ componentId, slotId: '3001', width: 320, height: 560 }], Date.now() + 1);
        await new Promise<void>((resolve): void => { setTimeout(resolve, 10); });
        expect(controller.snapshotRequests).assertEqual(1);
        expect(bridge.payloads.length).assertEqual(2);
        const resize = JSON.parse(bridge.payloads[1]) as Record<string, number | Record<string, number>>;
        expect(resize.type as number).assertEqual(3);
        const data = resize.data as Record<string, number>;
        expect(data.source).assertEqual(4);
        expect(data.width).assertEqual(320);
        expect(data.height).assertEqual(560);
      } finally {
        handler.clearWebController();
        registry.unregister(bridge);
        if (previous !== null) manager.initWithConfig(previous);
        else FTRUMConfigManager.resetStateInternal();
      }
    });

    it('refreshes the Browser visual viewport on native resize and clears it for a new Browser view', 0, async () => {
      const manager = FTRUMConfigManager.getInstance();
      const previous = manager.getConfig();
      manager.initWithConfig(new FTRUMConfig().setRumAppId('visual-app').setEnableTraceWebView(true));
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
        const observe = async (height: number): Promise<void> => {
          registry.observeWebReplaySlots('visual-app', session, 'native-view',
            [{ componentId, slotId: '3002', width: 320, height }], Date.now());
          await new Promise<void>((resolve): void => { setTimeout(resolve, 10); });
        };
        await observe(480);
        const receiver = handler.getMessageReceiver();
        receiver.sendEvent('{"name":"session_replay","view":{"id":"browser-view"},"data":' +
          `{"timestamp":${Date.now()},"type":8,"data":{"width":160,"height":240,"scale":2,` +
          '"offsetLeft":12,"offsetTop":24,"pageLeft":32,"pageTop":184}}}');
        await observe(560);
        expect(controller.snapshotRequests).assertEqual(1);
        expect(bridge.payloads.length).assertEqual(3);
        const visual = JSON.parse(bridge.payloads[2]) as Record<string, number | Record<string, number>>;
        expect(visual.type as number).assertEqual(8);
        const data = visual.data as Record<string, number>;
        expect(data.width).assertEqual(160);
        expect(data.height).assertEqual(280);
        expect(data.scale).assertEqual(2);
        expect(data.offsetLeft).assertEqual(12);
        expect(data.offsetTop).assertEqual(24);
        expect(data.pageLeft).assertEqual(32);
        expect(data.pageTop).assertEqual(184);
        await observe(560);
        expect(bridge.payloads.length).assertEqual(3);
        receiver.sendEvent(rrwebEvent('next-browser-view'));
        await observe(600);
        expect(bridge.payloads.length).assertEqual(5);
        expect(bridge.views[4]).assertEqual('next-browser-view');
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
