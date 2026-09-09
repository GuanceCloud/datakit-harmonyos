import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context, common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import window from '@ohos.window';
import {
  FTDnsConfig,
  FTDataFilters,
  FTLoggerConfig,
  FTProxyAuthenticator,
  FTProxyConfig,
  FTRUMConfig,
  FTSDKConfig,
  FTTraceConfig
} from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import {
  DataType,
  DBCacheDiscard,
  DetectFrequency,
  EnvType,
  LogCacheDiscard,
  RUMCacheDiscard,
  SDKLogLevel,
  SyncPageSize
} from '../../main/ets/components/enum/Enums';
import { Status as LogLevel } from '../../main/ets/components/bean/Status';
import { DeviceMetricsMonitorType } from '../../main/ets/components/rum/enum/DeviceMetricsMonitorType';
import { ErrorMonitorType } from '../../main/ets/components/rum/enum/ErrorMonitorType';
import { FTDBCachePolicy } from '../../main/ets/components/db/FTDBCachePolicy';
import { FTSDK } from '../../main/ets/components/FTSDK';
import FTTrackInner from '../../main/ets/components/FTTrackInner';
import { FTSDKAnrManager, FTSDKRuntime } from '../../main/ets/components/internal/runtime/FTSDKRuntime';
import { SdkInternalTestAccess } from '../../main/ets/components/internal/testaccess/SdkInternalTestAccess';
import { FTLogger } from '../../main/ets/components/log/FTLogger';
import { FTConsoleLogBridge } from '../../main/ets/components/log/FTConsoleLogBridge';
import { TrackLogManager } from '../../main/ets/components/log/TrackLogManager';
import { LogBean } from '../../main/ets/components/bean/LogBean';
import { FTRUMConfigManager } from '../../main/ets/components/rum/FTRUMConfigManager';
import { SyncTaskManager } from '../../main/ets/components/SyncTaskManager';
import { ConfigRecord } from '../../main/ets/components/SyncTaskManager';
import { SyncInternalTestAccess } from '../../main/ets/components/internal/testaccess/SyncInternalTestAccess';
import { SyncDataHelper } from '../../main/ets/components/SyncDataHelper';
import { FTTraceConfigManager } from '../../main/ets/components/trace/FTTraceConfigManager';
import {
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceRequestContext
} from '../../main/ets/components/trace/FTTraceHeaderHandler';
import { FTTraceManager } from '../../main/ets/components/trace/FTTraceManager';
import { TraceType } from '../../main/ets/components/trace/TraceType';
import { FTInTakeUrlHandler } from '../../main/ets/components/http/FTInTakeUrlHandler';
import { HandlerView } from '../../main/ets/components/rum/bean/HandlerView';
import { FTViewNavigationTrackingHandler } from '../../main/ets/components/rum/handler/FTViewNavigationTrackingHandler';
import { FTViewRouterTrackingHandler } from '../../main/ets/components/rum/handler/FTViewRouterTrackingHandler';
import { TestReset } from '../helpers/TestReset';

const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_CLIENT_TOKEN = 'fake_client_token';
const TEST_FAKE_RUM_ID = 'rumId';

class TestConfigRecord implements ConfigRecord {
  private config: FTSDKConfig;

  constructor(config: FTSDKConfig) {
    this.config = config;
  }

  isLimitWithDbSize(): boolean {
    return this.config.isLimitWithDbSize();
  }

  getDbCacheLimit(): number {
    return this.config.getDbCacheLimit();
  }

  getDBCacheDiscard(): string {
    return this.config.getDBCacheDiscard();
  }

  getLogCacheDiscard(): string {
    return this.config.getLogCacheDiscard();
  }
}

class RecordingConfigHeaderHandler implements FTTraceHeaderHandler {
  public requestTraceId: string = '';
  public requestSpanId: string = '';

  getTraceContext(request: FTTraceRequestContext): FTTraceContext {
    const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
    this.requestTraceId = traceContext.traceId;
    this.requestSpanId = traceContext.spanId;
    traceContext.headers['x-config-handler-trace-id'] = traceContext.traceId;
    return traceContext;
  }
}

class TestViewRouterTrackingHandler implements FTViewRouterTrackingHandler {
  resolveHandlerView(routeName: string): HandlerView | null {
    return routeName === 'IgnoredRoute' ? null : new HandlerView(`router_${routeName}`);
  }
}

class TestViewNavigationTrackingHandler implements FTViewNavigationTrackingHandler {
  resolveHandlerView(destinationName: string): HandlerView | null {
    return destinationName === 'IgnoredDestination' ? null : new HandlerView(`navigation_${destinationName}`);
  }
}

class TestResourceUrlHandler extends FTInTakeUrlHandler {
  public calls: number = 0;

  public isInTakeUrl(url: string): boolean {
    this.calls++;
    return url.startsWith('https://ignored.example.com/');
  }
}

class FakeAnrManager implements FTSDKAnrManager {
  initializeCount: number = 0;
  startMonitoringCount: number = 0;
  shutdownCount: number = 0;

  initialize(): void {
    this.initializeCount++;
  }

  startMonitoring(): boolean {
    this.startMonitoringCount++;
    return true;
  }

  shutdown(): void {
    this.shutdownCount++;
  }
}

class FakeFTSDKRuntime implements FTSDKRuntime {
  context: common.UIAbilityContext | null = null;
  uiContext: UIContext | null = null;
  anrManager: FakeAnrManager = new FakeAnrManager();
  syncTaskInitCount: number = 0;
  exceptionHandlerInitCount: number = 0;
  uiBlockStartCount: number = 0;
  lifecycleRegisterCount: number = 0;
  actionTrackerInitCount: number = 0;
  navigationTrackerInitCount: number = 0;
  mainWindowSetCount: number = 0;

  initUtils(context: common.UIAbilityContext): void {
    this.context = context;
  }

  getAbilityContext(): common.UIAbilityContext | null {
    return this.context;
  }

  initSyncTaskManager(config: FTSDKConfig, _context: Context): void {
    this.syncTaskInitCount++;
    FTDBCachePolicy.getInstance().initSDKParams(new TestConfigRecord(config));
  }

  getAnrDetectManager(): FTSDKAnrManager | null {
    return this.anrManager;
  }

  initExceptionHandler(_config: FTRUMConfig): void {
    this.exceptionHandlerInitCount++;
  }

  startUIBlockManager(_config: FTRUMConfig): void {
    this.uiBlockStartCount++;
  }

  registerLifecycleListener(): void {
    this.lifecycleRegisterCount++;
  }

  setMainWindow(_mainWindow?: window.Window): void {
    this.mainWindowSetCount++;
  }

  getUIContext(): UIContext | null {
    return this.uiContext;
  }

  initActionTracker(_uiContext: UIContext, _config: FTRUMConfig): void {
    this.actionTrackerInitCount++;
  }

  destroyActionTracker(): void {
  }

  initNavigationTracker(_uiContext: UIContext, _config: FTRUMConfig): void {
    this.navigationTrackerInitCount++;
  }

  destroyNavigationTracker(): void {
  }
}

class FakeAbilityContext {
}

class FakeUIContext {
}

class RecordingConsoleDelegate {
  public callCount: number = 0;

  debug(..._args: Object[]): void {
    this.callCount++;
  }

  info(..._args: Object[]): void {
    this.callCount++;
  }

  warn(..._args: Object[]): void {
    this.callCount++;
  }

  error(..._args: Object[]): void {
    this.callCount++;
  }

  log(..._args: Object[]): void {
    this.callCount++;
  }

  trace(..._args: Object[]): void {
    this.callCount++;
  }
}

function createFakeContext(): common.UIAbilityContext {
  return new FakeAbilityContext() as Object as common.UIAbilityContext;
}

export default function configUnitTest() {
  describe('ConfigUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
      TrackLogManager.resetStateInternal();
      FTTrackInner.resetInstanceInternal();
      SdkInternalTestAccess.resetState();
      SdkInternalTestAccess.resetRuntime();
      FTRUMConfigManager.getInstance().release();
    });

    afterEach(() => {
      TestReset.resetP0State();
      TrackLogManager.resetStateInternal();
      FTTrackInner.resetInstanceInternal();
      SdkInternalTestAccess.resetState();
      SdkInternalTestAccess.resetRuntime();
      FTRUMConfigManager.getInstance().release();
    });

    it('sdkConfigShouldKeepDefaults', 0, () => {
      const datakitConfig = FTSDKConfig.builder(TEST_FAKE_URL).setServiceName('').setEnv('');
      const datawayConfig = FTSDKConfig.builder(TEST_FAKE_URL, TEST_FAKE_CLIENT_TOKEN).setEnv(EnvType.GRAY);
      const deferredEndpointConfig = FTSDKConfig.builder();

      expect(datakitConfig.getServiceName()).assertEqual(Constants.DEFAULT_SERVICE_NAME);
      expect(datakitConfig.getEnv()).assertEqual(EnvType.PROD.toString());
      expect(datakitConfig.getDatakitUrl()).assertEqual(TEST_FAKE_URL);
      expect(datawayConfig.getEnv()).assertEqual(EnvType.GRAY.toString());
      expect(datawayConfig.getDatawayUrl()).assertEqual(TEST_FAKE_URL);
      expect(datawayConfig.getClientToken()).assertEqual(TEST_FAKE_CLIENT_TOKEN);
      expect(datakitConfig.getSdkLogLevel()).assertEqual(SDKLogLevel.V);
      expect(datakitConfig.setSdkLogLevel(SDKLogLevel.W).getSdkLogLevel()).assertEqual(SDKLogLevel.W);
      expect(datakitConfig.isCompressIntakeRequests()).assertTrue();
      expect(datakitConfig.setCompressIntakeRequests(false).isCompressIntakeRequests()).assertFalse();
      expect(deferredEndpointConfig.getDatakitUrl()).assertEqual('');
      expect(deferredEndpointConfig.getDatawayUrl()).assertEqual('');
      expect(deferredEndpointConfig.getClientToken()).assertEqual('');
    });

    it('resourceUrlHandlerShouldUseAndroidFilterSemantics', 0, () => {
      const handler = new TestResourceUrlHandler();
      const config = new FTRUMConfig().setResourceUrlHandler(handler);
      const manager = FTRUMConfigManager.getInstance();
      manager.initWithConfig(config);

      expect(config.getResourceUrlHandler() === handler).assertTrue();
      expect(manager.shouldFilterResourceUrl('https://ignored.example.com/metrics')).assertTrue();
      expect(manager.shouldFilterResourceUrl('https://api.example.com/orders')).assertFalse();
      expect(handler.calls).assertEqual(2);
    });

    it('runtimeEndpointUpdatesSwitchUploadModes', 0, () => {
      const runtime = new FakeFTSDKRuntime();
      const config = FTSDKConfig.builder();
      SdkInternalTestAccess.setRuntime(runtime);
      FTSDK.install(config, createFakeContext());

      FTSDK.setDatakitUrl('https://datakit.example.com');
      expect(config.getDatakitUrl()).assertEqual('https://datakit.example.com');
      expect(config.getDatawayUrl()).assertEqual('');
      expect(config.getClientToken()).assertEqual('');

      FTSDK.setDatawayUrl('https://dataway.example.com', 'runtime-token');
      expect(config.getDatakitUrl()).assertEqual('');
      expect(config.getDatawayUrl()).assertEqual('https://dataway.example.com');
      expect(config.getClientToken()).assertEqual('runtime-token');

      FTSDK.setDatakitUrl('https://datakit-next.example.com');
      expect(config.getDatakitUrl()).assertEqual('https://datakit-next.example.com');
      expect(config.getDatawayUrl()).assertEqual('');
      expect(config.getClientToken()).assertEqual('');
    });

    it('sdkResetClearsEndpointOverride', 0, () => {
      const runtime = new FakeFTSDKRuntime();
      const config = FTSDKConfig.builder('https://startup-datakit.example.com');
      SdkInternalTestAccess.setRuntime(runtime);
      FTSDK.install(config, createFakeContext());

      FTSDK.setDatawayUrl('https://runtime-dataway.example.com', 'runtime-token');
      expect(config.getDatakitUrl()).assertEqual('');
      expect(config.getDatawayUrl()).assertEqual('https://runtime-dataway.example.com');
      expect(config.getClientToken()).assertEqual('runtime-token');

      SdkInternalTestAccess.resetState();
      expect(config.getDatakitUrl()).assertEqual('https://startup-datakit.example.com');
      expect(config.getDatawayUrl()).assertEqual('');
      expect(config.getClientToken()).assertEqual('');
    });

    it('sdkConfigShouldConfigureLocalDataFilters', 0, () => {
      const filterRules: FTDataFilters = new Map<string, Array<string>>();
      filterRules.set('logging', ["{ message match ['password'] }"]);
      filterRules.set('rum', ["{ resource_status in ['404', '503'] }"]);
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setDataFilters(filterRules);

      expect(config.isEnableDataFilter()).assertTrue();
      expect(config.getDataFilters().get('logging')![0]).assertEqual("{ message match ['password'] }");
      expect(config.getDataFilters().get('rum')![0]).assertEqual("{ resource_status in ['404', '503'] }");

      const copiedRules = config.getDataFilters();
      copiedRules.get('logging')![0] = '{ source in [changed] }';
      expect(config.getDataFilters().get('logging')![0]).assertEqual("{ message match ['password'] }");

      config.setEnableDataFilter(false).setDataFilters(null);
      expect(config.isEnableDataFilter()).assertFalse();
      expect(config.getDataFilters().size).assertEqual(0);
    });

    it('sdkConfigStoreUploadProxyAndDnsOptions', 0, () => {
      const configuredProxyExclusionList: string[] = ['localhost'];
      const configuredProxy: FTProxyConfig = {
        host: 'proxy.example.com',
        port: 8080,
        exclusionList: configuredProxyExclusionList
      };
      const configuredAuthenticator: FTProxyAuthenticator = {
        username: 'proxy-user',
        password: 'proxy-password'
      };
      const configuredDns: FTDnsConfig = {
        servers: [' 1.1.1.1 ', '', '8.8.8.8', '9.9.9.9', '208.67.222.222'],
        overHttpsUrl: ' https://dns.example.com/dns-query '
      };
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setProxy(configuredProxy)
        .setProxyAuthenticator(configuredAuthenticator)
        .setDns(configuredDns);
      configuredProxyExclusionList[0] = 'mutated-host';

      const proxy = config.getProxy();
      const authenticator = config.getProxyAuthenticator();
      const dns = config.getDns();
      expect(proxy !== null).assertTrue();
      expect(authenticator !== null).assertTrue();
      expect(dns !== null).assertTrue();
      if (proxy !== null && authenticator !== null && dns !== null) {
        expect(proxy.host).assertEqual('proxy.example.com');
        expect(proxy.port).assertEqual(8080);
        expect((proxy.exclusionList as string[])[0]).assertEqual('localhost');
        expect(authenticator.username).assertEqual('proxy-user');
        expect(authenticator.password).assertEqual('proxy-password');
        expect((dns.servers as string[]).length).assertEqual(3);
        expect((dns.servers as string[])[0]).assertEqual('1.1.1.1');
        expect((dns.servers as string[])[2]).assertEqual('9.9.9.9');
        expect(dns.overHttpsUrl).assertEqual('https://dns.example.com/dns-query');
      }

      config.setProxy(null).setProxyAuthenticator(null).setDns(null);
      expect(config.getProxy() === null).assertTrue();
      expect(config.getProxyAuthenticator() === null).assertTrue();
      expect(config.getDns() === null).assertTrue();
    });

    it('sdkConfigShouldClampBounds', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setSyncPageSize(SyncPageSize.MINI)
        .setSyncSleepTime(10000)
        .setDataSyncRetryCount(100)
        .enableLimitWithDbSize(1)
        .setAutoSync(false);

      expect(config.getPageSize()).assertEqual(SyncPageSize.MINI);
      expect(config.getSyncSleepTime()).assertEqual(SyncTaskManager.SYNC_SLEEP_MAX_TIME_MS);
      expect(config.getDataSyncRetryCount()).assertEqual(SyncTaskManager.MAX_ERROR_COUNT);
      expect(config.getDbCacheLimit()).assertEqual(Constants.MINI_CACHE_LIMIT_SIZE);
      expect(new FTLoggerConfig().setLogCacheLimitCount(0).getLogCacheLimitCount()).assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);
      expect(new FTRUMConfig().setRumCacheLimitCount(0).getRumCacheLimitCount()).assertEqual(Constants.MINI_DB_RUM_CACHE_NUM);
      expect(config.isAutoSyncEnabled()).assertFalse();

      expect(FTSDKConfig.builder(TEST_FAKE_URL).setSyncSleepTime(-1).getSyncSleepTime())
        .assertEqual(SyncTaskManager.SYNC_SLEEP_MINI_TIME_MS);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setDataSyncRetryCount(-1).getDataSyncRetryCount()).assertEqual(0);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setDataSyncRetryCount(2.9).getDataSyncRetryCount()).assertEqual(2);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setCustomSyncPageSize(1).getPageSize())
        .assertEqual(SyncPageSize.MINI);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setCustomSyncPageSize(123.9).getPageSize())
        .assertEqual(123);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setCustomSyncPageSize(1_000_000).getPageSize())
        .assertEqual(SyncTaskManager.MAX_PAGE_SIZE);
    });

    it('sdkShouldExposeRuntimeAutoSyncToggle', 0, () => {
      SyncInternalTestAccess.resetState();
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setAutoSync(false);
      const syncTaskManager = SyncTaskManager.getInstance();
      syncTaskManager.init(config);

      const runtime = new FakeFTSDKRuntime();
      SdkInternalTestAccess.setRuntime(runtime);
      FTSDK.install(config, createFakeContext());

      FTSDK.setAutoSync(true);
      expect(config.isAutoSyncEnabled()).assertTrue();
      expect(syncTaskManager.isAutoSyncEnabled()).assertTrue();

      FTSDK.setAutoSync(false);
      expect(config.isAutoSyncEnabled()).assertFalse();
      expect(syncTaskManager.isAutoSyncEnabled()).assertFalse();

      syncTaskManager.stop();
      SyncInternalTestAccess.resetState();
    });

    it('rumConfigShouldExposeDocumentedDefaults', 0, () => {
      const rumConfig = new FTRUMConfig();

      expect(rumConfig.getRumAppId()).assertEqual('');
      expect(rumConfig.getSamplingRate()).assertEqual(1.0);
      expect(rumConfig.getSessionErrorSampleRate()).assertEqual(0.0);
      expect(rumConfig.isEnableTraceUserAction()).assertFalse();
      expect(rumConfig.isEnableTraceUserView()).assertFalse();
      expect(rumConfig.isEnableTraceUserResource()).assertFalse();
      expect(rumConfig.isEnableTrackAppANR()).assertFalse();
      expect(rumConfig.isEnableTrackAppCrash()).assertFalse();
      expect(rumConfig.isEnableTraceWebView()).assertFalse();
      expect(rumConfig.getBlockDurationMS()).assertEqual(1000);
      expect(rumConfig.getRumCacheLimitCount()).assertEqual(Constants.DEFAULT_DB_RUM_CACHE_NUM);
      expect(rumConfig.getRumCacheDiscardStrategy()).assertEqual(RUMCacheDiscard.DISCARD);
    });

    it('rumConfigStoreAutoViewTrackingHandlers', 0, () => {
      const routerHandler = new TestViewRouterTrackingHandler();
      const navigationHandler = new TestViewNavigationTrackingHandler();
      const rumConfig = new FTRUMConfig()
        .setViewRouterTrackingHandler(routerHandler)
        .setViewNavigationTrackingHandler(navigationHandler);

      expect(rumConfig.getViewRouterTrackingHandler() === routerHandler).assertTrue();
      expect(rumConfig.getViewNavigationTrackingHandler() === navigationHandler).assertTrue();
      expect(rumConfig.getViewRouterTrackingHandler()?.resolveHandlerView('Home')?.getViewName() ?? '')
        .assertEqual('router_Home');
      expect(rumConfig.getViewRouterTrackingHandler()?.resolveHandlerView('IgnoredRoute') === null).assertTrue();
      expect(rumConfig.getViewNavigationTrackingHandler()?.resolveHandlerView('Detail')?.getViewName() ?? '')
        .assertEqual('navigation_Detail');
      expect(rumConfig.getViewNavigationTrackingHandler()?.resolveHandlerView('IgnoredDestination') === null).assertTrue();
    });

    it('sdkConfigShouldStoreCacheOptions', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLogCacheDiscard('discard_oldest')
        .enableLimitWithDbSize()
        .enableDataIntegerCompatible();

      expect(config.getLogCacheDiscard()).assertEqual('discard_oldest');
      expect(config.isLimitWithDbSize()).assertTrue();
      expect(config.getDbCacheLimit()).assertEqual(Constants.DEFAULT_CACHE_LIMIT_SIZE);
      expect(config.isDataIntegerCompatible()).assertTrue();

      const legacyConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheDiscard(DBCacheDiscard.DISCARD_OLDEST);
      expect(legacyConfig.getDBCacheDiscard()).assertEqual('discard_oldest');

      const legacyLimitConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(1);
      expect(legacyLimitConfig.isLimitWithDbSize()).assertTrue();
      expect(legacyLimitConfig.getDbCacheLimit()).assertEqual(Constants.MINI_CACHE_LIMIT_SIZE);
    });

    it('sdkOptionsShouldApplyToManagers', 0, () => {
      const dbLimit = 67108864;
      const logLimit = 2345;
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .enableLimitWithDbSize(dbLimit)
        .setDbCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
        .setLogCacheDiscard('discard_oldest')
        .enableDataIntegerCompatible();
      const cachePolicy = FTDBCachePolicy.getInstance();

      cachePolicy.initSDKParams(new TestConfigRecord(config));

      expect(config.getDbCacheLimit()).assertEqual(dbLimit);
      expect(config.getDBCacheDiscard()).assertEqual('discard_oldest');
      expect(config.getLogCacheDiscard()).assertEqual('discard_oldest');
      expect(config.isDataIntegerCompatible()).assertTrue();
      expect(cachePolicy.isEnableLimitWithDbSize()).assertTrue();
      expect(cachePolicy.getDbLimitSize()).assertEqual(dbLimit);
      cachePolicy.updateLogCacheLimitCount(logLimit);
      cachePolicy.updateRumCacheLimitCount(34567);
      expect(cachePolicy.getLogLimitCount()).assertEqual(Constants.DEFAULT_DB_LOG_CACHE_NUM);
      expect(cachePolicy.getRumLimitCount()).assertEqual(Constants.DEFAULT_DB_RUM_CACHE_NUM);
      expect(cachePolicy.getDBCacheDiscard()).assertEqual(DBCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.LOG)).assertEqual(LogCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_APP)).assertEqual(RUMCacheDiscard.DISCARD);

      const helper = new SyncDataHelper();
      const fields: Map<string, string> = new Map<string, string>();
      fields.set('integer_value', '12');
      fields.set('float_value', '3.14');
      helper.initBaseConfig(config);
      const lineProtocol =
        helper.getBodyContent(
          'df_rum_harmonyos_log',
          new Map<string, string>(),
          fields,
          123456789,
          DataType.LOG,
          'uuid-integer'
        );

      expect(lineProtocol.includes('integer_value=12i')).assertFalse();
      expect(lineProtocol.includes('integer_value=12')).assertTrue();
      expect(lineProtocol.includes('float_value=3.14')).assertTrue();
    });

    it('samplingRatesShouldClampBounds', 0, () => {
      expect(new FTRUMConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(new FTRUMConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);
      expect(new FTRUMConfig().setSessionErrorSampleRate().getSessionErrorSampleRate()).assertEqual(0.0);
      expect(new FTRUMConfig().setSessionErrorSampleRate(-1).getSessionErrorSampleRate()).assertEqual(0);
      expect(new FTRUMConfig().setSessionErrorSampleRate(2).getSessionErrorSampleRate()).assertEqual(1);
      expect(new FTLoggerConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(new FTLoggerConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);
      expect(new FTTraceConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(new FTTraceConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);
      expect(Number.isNaN(new FTLoggerConfig().setSamplingRate(Number.NaN).getSamplingRate())).assertTrue();
    });

    it('rumConfigShouldKeepSwitches', 0, () => {
      const config = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true, 90)
        .setEnableTrackAppCrash(true)
        .setEnableTrackAppANR(true)
        .setEnableTraceUserAction(true)
        .setEnableTraceUserView(true)
        .setEnableTraceUserResource(true)
        .setEnableTraceWebView(true)
        .setExtraMonitorTypeWithError(ErrorMonitorType.CPU)
        .setDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY)
        .setDeviceMetricsDetectFrequency(DetectFrequency.FREQUENT);

      expect(config.getRumAppId()).assertEqual(TEST_FAKE_RUM_ID);
      expect(config.getBlockDurationMS()).assertEqual(100);
      expect(config.isEnableTrackAppCrash()).assertTrue();
      expect(config.isEnableTrackAppANR()).assertTrue();
      expect(config.isEnableTraceUserAction()).assertTrue();
      expect(config.isEnableTraceUserView()).assertTrue();
      expect(config.isEnableTraceUserResource()).assertTrue();
      expect(config.isEnableTraceWebView()).assertTrue();
      expect(config.getExtraMonitorTypeWithError()).assertEqual(ErrorMonitorType.CPU);
      expect(config.getDeviceMetricsMonitorType()).assertEqual(DeviceMetricsMonitorType.MEMORY);
      expect(config.getDeviceMetricsDetectFrequency()).assertEqual(DetectFrequency.FREQUENT);

      const combinedConfig = new FTRUMConfig().setDeviceMetricsMonitorType(
        DeviceMetricsMonitorType.CPU,
        DetectFrequency.RARE
      );
      expect(combinedConfig.getDeviceMetricsMonitorType()).assertEqual(DeviceMetricsMonitorType.CPU);
      expect(combinedConfig.getDeviceMetricsDetectFrequency()).assertEqual(DetectFrequency.RARE);
    });

    it('rumConfigShouldRequireUiFeatures', 0, () => {
      expect(SdkInternalTestAccess.requiresUIFeatures(new FTRUMConfig())).assertFalse();
      expect(SdkInternalTestAccess.requiresUIFeatures(new FTRUMConfig().setEnableTraceUserResource(true))).assertFalse();
      expect(SdkInternalTestAccess.requiresUIFeatures(new FTRUMConfig().setEnableTraceWebView(true))).assertFalse();
      expect(SdkInternalTestAccess.requiresUIFeatures(new FTRUMConfig().setEnableTraceUserAction(true))).assertTrue();
      expect(SdkInternalTestAccess.requiresUIFeatures(new FTRUMConfig().setEnableTraceUserView(true))).assertTrue();
      expect(SdkInternalTestAccess.requiresUIFeatures(new FTRUMConfig().setEnableTrackAppCrash(true))).assertTrue();
      expect(SdkInternalTestAccess.requiresUIFeatures(new FTRUMConfig().setEnableTrackAppANR(true))).assertTrue();
    });

    it('rumCrashSwitchControlsNativeLogs', 0, () => {
      const runtime = new FakeFTSDKRuntime();
      runtime.uiContext = new FakeUIContext() as Object as UIContext;
      SdkInternalTestAccess.setRuntime(runtime);
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL), createFakeContext());

      expect(SdkInternalTestAccess.isNativeCrashLogCollectionEnabled()).assertFalse();

      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
      expect(SdkInternalTestAccess.isNativeCrashLogCollectionEnabled()).assertFalse();

      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppCrash(true));
      expect(SdkInternalTestAccess.isNativeCrashLogCollectionEnabled()).assertTrue();

      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
      expect(SdkInternalTestAccess.isNativeCrashLogCollectionEnabled()).assertFalse();
    });

    it('installRumShouldApplySideEffects', 0, () => {
      const runtime = new FakeFTSDKRuntime();
      runtime.uiContext = new FakeUIContext() as Object as UIContext;
      SdkInternalTestAccess.setRuntime(runtime);
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL), createFakeContext());

      const rumConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setSamplingRate(0.25)
        .setSessionErrorSampleRate(0.5)
        .setEnableTrackAppCrash(true)
        .setEnableTrackAppANR(true)
        .setEnableTrackAppUIBlock(true, 150);

      FTSDK.installRUMConfig(rumConfig);

      expect(FTSDK.getRumConfig()!.getRumAppId()).assertEqual(TEST_FAKE_RUM_ID);
      expect(FTRUMConfigManager.getInstance().getConfig()!.getRumAppId()).assertEqual(TEST_FAKE_RUM_ID);
      expect(String(rumConfig.getGlobalContext().get(Constants.KEY_RUM_APP_ID))).assertEqual(TEST_FAKE_RUM_ID);
      expect(String(rumConfig.getGlobalContext().get(Constants.KEY_RUM_SESSION_TYPE))).assertEqual('user');
      expect(String(rumConfig.getGlobalContext().get(Constants.KEY_SERVICE))).assertEqual(Constants.DEFAULT_SERVICE_NAME);
      const rumLineProtocol = FTTrackInner.getInstance().getDataHelper().getBodyContent(
        'view',
        new Map<string, string>(),
        new Map<string, string>(),
        123456789,
        DataType.RUM_APP,
        'uuid-rum-config'
      );
      expect(rumLineProtocol.includes('session_sample_rate=0.25')).assertTrue();
      expect(rumLineProtocol.includes('session_on_error_sample_rate=0.5')).assertTrue();
      expect(runtime.exceptionHandlerInitCount).assertEqual(1);
      expect(runtime.uiBlockStartCount).assertEqual(1);
      expect(runtime.lifecycleRegisterCount).assertEqual(1);
      expect(runtime.anrManager.initializeCount).assertEqual(1);
      expect(runtime.anrManager.startMonitoringCount).assertEqual(1);
      expect(runtime.mainWindowSetCount).assertEqual(1);
    });

    it('rumConfigShouldApplyRumCacheLimit', 0, () => {
      const runtime = new FakeFTSDKRuntime();
      SdkInternalTestAccess.setRuntime(runtime);
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL), createFakeContext());
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumCacheLimitCount(12345)
        .setRumCacheDiscardStrategy(RUMCacheDiscard.DISCARD_OLDEST));

      expect(runtime.syncTaskInitCount).assertEqual(1);
      expect(FTDBCachePolicy.getInstance().getRumLimitCount()).assertEqual(12345);
      expect(FTDBCachePolicy.getInstance().getDiscardStrategy(DataType.RUM_APP))
        .assertEqual(RUMCacheDiscard.DISCARD_OLDEST);
      expect(FTDBCachePolicy.getInstance().getDiscardStrategy(DataType.RUM_WEBVIEW))
        .assertEqual(RUMCacheDiscard.DISCARD_OLDEST);

      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumCacheLimitCount(1)
        .setRumCacheDiscardStrategy('discard'));
      expect(FTDBCachePolicy.getInstance().getRumLimitCount()).assertEqual(Constants.MINI_DB_RUM_CACHE_NUM);
      expect(FTDBCachePolicy.getInstance().getDiscardStrategy(DataType.RUM_APP)).assertEqual(RUMCacheDiscard.DISCARD);

      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).enableLimitWithDbSize(), createFakeContext());
      FTSDK.installRUMConfig(new FTRUMConfig().setRumCacheLimitCount(12345));
      expect(FTDBCachePolicy.getInstance().getRumLimitCount()).assertEqual(Constants.DEFAULT_DB_RUM_CACHE_NUM);
    });

    it('rumFastDiscardPreservesDiscardOldest', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.setTestLimits(0, 2);
      cachePolicy.optRumCount(2);

      cachePolicy.updateRumCacheDiscardStrategy(RUMCacheDiscard.DISCARD);
      expect(cachePolicy.isRumCacheDiscardingAtLimit()).assertTrue();

      cachePolicy.updateRumCacheDiscardStrategy(RUMCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.isRumCacheDiscardingAtLimit()).assertFalse();

      const sizeConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .enableLimitWithDbSize(1024)
        .setDbCacheDiscard(DBCacheDiscard.DISCARD_OLDEST);
      cachePolicy.initSDKParams(new TestConfigRecord(sizeConfig));
      cachePolicy.setCurrentDbSize(1024);
      expect(cachePolicy.isRumCacheDiscardingAtLimit()).assertFalse();
    });

    it('logConfigShouldApplyLogCacheLimit', 0, () => {
      const runtime = new FakeFTSDKRuntime();
      SdkInternalTestAccess.setRuntime(runtime);
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL), createFakeContext());
      FTSDK.installLogConfig(new FTLoggerConfig().setLogCacheLimitCount(12345));

      expect(runtime.syncTaskInitCount).assertEqual(1);
      expect(FTDBCachePolicy.getInstance().getLogLimitCount()).assertEqual(12345);

      FTSDK.installLogConfig(new FTLoggerConfig().setLogCacheLimitCount(1));
      expect(FTDBCachePolicy.getInstance().getLogLimitCount()).assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);

      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).enableLimitWithDbSize(), createFakeContext());
      FTSDK.installLogConfig(new FTLoggerConfig().setLogCacheLimitCount(12345));
      expect(FTDBCachePolicy.getInstance().getLogLimitCount()).assertEqual(Constants.DEFAULT_DB_LOG_CACHE_NUM);
    });

    it('loggerConfigShouldStoreFilters', 0, () => {
      const loggerConfig = new FTLoggerConfig()
        .setLogCacheLimitCount(12345)
        .setLogLevelFilters(['ERROR', 'WARNING', 'INFO', 'DEBUG']);

      expect(loggerConfig.getLogCacheLimitCount()).assertEqual(12345);
      expect(loggerConfig.getLogLevelFilters().length).assertEqual(4);
      expect(loggerConfig.getLogLevelFilters()[0]).assertEqual(LogLevel.ERROR.name);
      expect(loggerConfig.getLogLevelFilters()[1]).assertEqual(LogLevel.WARN.name);
      expect(loggerConfig.getLogLevelFilters()[2]).assertEqual(LogLevel.INFO.name);
      expect(loggerConfig.getLogLevelFilters()[3]).assertEqual(LogLevel.DEBUG.name);
      expect(loggerConfig.checkLogLevel(LogLevel.ERROR.name)).assertTrue();
      expect(loggerConfig.checkLogLevel(LogLevel.WARN.name)).assertTrue();
      expect(loggerConfig.checkLogLevel(LogLevel.INFO.name)).assertTrue();
      expect(loggerConfig.checkLogLevel(LogLevel.DEBUG.name)).assertTrue();
      expect(loggerConfig.checkLogLevel(LogLevel.TRACE.name)).assertFalse();

      const minConfig = new FTLoggerConfig().setLogCacheLimitCount(0);
      expect(minConfig.getLogCacheLimitCount()).assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);
    });

    it('loggerConfigShouldStoreObjectFilters', 0, () => {
      const loggerConfig = new FTLoggerConfig()
        .setLogLevelFilters([
          { name: LogLevel.ERROR.name },
          { name: LogLevel.WARN.name },
          { name: 'custom_level' }
        ]);

      expect(loggerConfig.getLogLevelFilters().length).assertEqual(3);
      expect(loggerConfig.getLogLevelFilters()[0]).assertEqual(LogLevel.ERROR.name);
      expect(loggerConfig.getLogLevelFilters()[1]).assertEqual(LogLevel.WARN.name);
      expect(loggerConfig.getLogLevelFilters()[2]).assertEqual('custom_level');
      expect(loggerConfig.checkLogLevel(LogLevel.ERROR.name)).assertTrue();
      expect(loggerConfig.checkLogLevel(LogLevel.WARN.name)).assertTrue();
      expect(loggerConfig.checkLogLevel('custom_level')).assertTrue();
      expect(loggerConfig.checkLogLevel(LogLevel.INFO.name)).assertFalse();
    });

    it('loggerTraceShouldKeepOptions', 0, () => {
      const loggerConfig = new FTLoggerConfig()
        .setEnableCustomLog(true)
        .setEnableConsoleLog(true, 'FT-')
        .setEnableLinkRumData(true)
        .setLogLevelFilters([LogLevel.ERROR, 'warn'])
        .setLogCacheDiscardStrategy(LogCacheDiscard.DISCARD_OLDEST)
        .setPrintCustomLogToConsole(true);
      const traceContext = new Map<string, object>();
      traceContext.set('trace_env', 'prod' as Object);
      const traceConfig = new FTTraceConfig()
        .setTraceType(TraceType.TRACEPARENT)
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setEnableWebTrace(true)
        .setServiceName('trace-service')
        .setGlobalContext(traceContext);

      expect(loggerConfig.isEnableCustomLog()).assertTrue();
      expect(loggerConfig.isEnableConsoleLog()).assertTrue();
      expect(loggerConfig.isEnableLinkRumData()).assertTrue();
      expect(loggerConfig.checkConsoleLogPrefix('FT-message')).assertTrue();
      expect(loggerConfig.checkPrefix('FT-message')).assertTrue();
      expect(loggerConfig.checkLogLevel(LogLevel.ERROR.name)).assertTrue();
      expect(loggerConfig.checkLogLevel('warn')).assertTrue();
      expect(loggerConfig.getLogCacheDiscardStrategy()).assertEqual(LogCacheDiscard.DISCARD_OLDEST);
      expect(new FTLoggerConfig().setLogCacheDiscardStrategy('discard_oldest').getLogCacheDiscardStrategy())
        .assertEqual(LogCacheDiscard.DISCARD_OLDEST);
      expect(loggerConfig.isPrintCustomLogToConsole()).assertTrue();
      expect(traceConfig.getTraceType()).assertEqual(TraceType.TRACEPARENT);
      expect(traceConfig.isEnableAutoTrace()).assertTrue();
      expect(traceConfig.isEnableLinkRUMData()).assertTrue();
      expect(traceConfig.isEnableWebTrace()).assertTrue();
      expect(traceConfig.getServiceName()).assertEqual('trace-service');
      expect(traceConfig.getGlobalContext().get('trace_env')).assertEqual('prod');
    });

    it('consoleCaptureIsIndependent', 0, () => {
      const logManager = TrackLogManager.getInstance();
      const config = new FTLoggerConfig().setEnableConsoleLog(true, 'capture:');
      logManager.setLogConfig(config);

      const delegate = new RecordingConsoleDelegate();
      FTConsoleLogBridge.console('log', (): void => delegate.log('capture: console-only'), 'capture: console-only');
      expect(delegate.callCount).assertEqual(1);
      expect(logManager.getQueueStatus().acceptedCount).assertEqual(1);

      logManager.trackLog(new LogBean('capture: manual-disabled', Date.now()));
      expect(logManager.getQueueStatus().acceptedCount).assertEqual(1);

      config.setEnableCustomLog(true);
      logManager.trackLog(new LogBean('manual-without-console-prefix', Date.now()));
      expect(logManager.getQueueStatus().acceptedCount).assertEqual(2);

      FTConsoleLogBridge.console('log', (): void => delegate.log('outside-console-prefix'), 'outside-console-prefix');
      expect(delegate.callCount).assertEqual(2);
      expect(logManager.getQueueStatus().acceptedCount).assertEqual(2);
    });

    it('consoleCaptureSkipsBeforeLogConfig', 0, () => {
      const logManager = TrackLogManager.getInstance();
      const delegate = new RecordingConsoleDelegate();

      FTConsoleLogBridge.console('log', (): void => delegate.log('pre-init console'), 'pre-init console');
      FTConsoleLogBridge.hilog('info', 0, 'pre-init', '%{public}s',
        (): void => delegate.info('pre-init hilog'), 'pre-init hilog');

      expect(delegate.callCount).assertEqual(2);
      expect(logManager.getQueueStatus().submittedCount).assertEqual(0);
      expect(logManager.getQueueStatus().acceptedCount).assertEqual(0);
      expect(logManager.getQueueStatus().filteredCount).assertEqual(0);
    });

    it('remoteDefaultsMatchAndroid', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL);

      expect(config.isRemoteConfiguration()).assertFalse();
      expect(config.getRemoteConfigMiniUpdateInterval()).assertEqual(43200);
      expect(config.setRemoteConfiguration(true).isRemoteConfiguration()).assertTrue();
      expect(config.setRemoteConfigMiniUpdateInterval(-1).getRemoteConfigMiniUpdateInterval()).assertEqual(0);
      expect(config.setRemoteConfigMiniUpdateInterval(12.9).getRemoteConfigMiniUpdateInterval()).assertEqual(12);
    });

    it('runtimeUpdatesEndpointAndDeviceId', 0, () => {
      const runtime = new FakeFTSDKRuntime();
      SdkInternalTestAccess.setRuntime(runtime);
      const config = FTSDKConfig.builder();

      expect(config.getDatakitUrl()).assertEqual('');
      expect(config.getDatawayUrl()).assertEqual('');
      FTSDK.install(config, createFakeContext());
      FTSDK.setDatakitUrl('http://datakit.example.com');
      expect(config.getDatakitUrl()).assertEqual('http://datakit.example.com');
      expect(config.getDatawayUrl()).assertEqual('');

      FTSDK.setDatawayUrl('https://dataway.example.com', 'client-token');
      expect(config.getDatakitUrl()).assertEqual('');
      expect(config.getDatawayUrl()).assertEqual('https://dataway.example.com');
      expect(config.getClientToken()).assertEqual('client-token');

      FTSDK.setEnableAccessDeviceID(false);
      expect(config.isAccessODIDEnabled()).assertFalse();
      expect(config.getGlobalContext().has(Constants.KEY_DEVICE_UUID)).assertTrue();
    });

    it('installedConfigsShouldReachManagers', 0, () => {
      const runtime = new FakeFTSDKRuntime();
      SdkInternalTestAccess.setRuntime(runtime);
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setAutoSync(false), createFakeContext());

      const loggerConfig = new FTLoggerConfig()
        .setEnableCustomLog(true)
        .setPrintCustomLogToConsole(true)
        .setLogLevelFilters([LogLevel.ERROR]);
      FTSDK.installLogConfig(loggerConfig);

      const installedLogConfig = TrackLogManager.getInstance().getLogConfig();
      expect(installedLogConfig !== null).assertTrue();
      if (installedLogConfig) {
        expect(installedLogConfig.isPrintCustomLogToConsole()).assertTrue();
      }
      FTLogger.logBackground('unit-print-custom-log-to-console', LogLevel.INFO);
      expect(TrackLogManager.getInstance().getQueueStatus().queueSize).assertEqual(0);

      const headerHandler = new RecordingConfigHeaderHandler();
      FTSDK.installTraceConfig(new FTTraceConfig()
        .setEnableAutoTrace(true)
        .setTraceHeaderHandler(headerHandler));

      const traceHeaderHandler = FTTraceConfigManager.getInstance().getTraceHeaderHandler();
      expect(traceHeaderHandler === headerHandler).assertTrue();
      if (traceHeaderHandler) {
        const traceContext = traceHeaderHandler.getTraceContext({
          url: 'http://example.com/config',
          method: 'GET',
          headers: {
            'Accept': 'application/json'
          }
        });

        expect(headerHandler.requestTraceId.length > 0).assertTrue();
        expect(headerHandler.requestSpanId.length > 0).assertTrue();
        expect(traceContext.headers['x-config-handler-trace-id']).assertEqual(headerHandler.requestTraceId);
      }
    });
  });
}
