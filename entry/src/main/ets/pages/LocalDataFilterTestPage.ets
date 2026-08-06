import { Context, common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import preferences from '@ohos.data.preferences';
import {
  FTLogger,
  FTRUMGlobalManager,
  FTSDK,
  NetStatusBean,
  ResourceParams
} from '@guancecloud/ft_sdk/Index';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import {
  RUNTIME_TEST_ACTIVE_CLIENT_TOKEN,
  RUNTIME_TEST_ACTIVE_ENDPOINT,
  RUNTIME_TEST_ACTIVE_MODE,
  RUNTIME_TEST_MODE_DATAKIT,
  RUNTIME_TEST_MODE_DATAWAY
} from '../constants/RuntimeEndpointTestState';
import {
  KEY_CLIENT_TOKEN,
  KEY_DATAKIT_URL,
  KEY_DATAWAY_URL,
  KEY_LOCAL_DATA_FILTER_ENABLED,
  KEY_LOCAL_DATA_FILTER_LOG_RULE,
  KEY_LOCAL_DATA_FILTER_RUM_RULE,
  RUNTIME_CONFIG_PREFERENCES_NAME
} from '../entryability/EntryAbility';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'LocalDataFilterTestPage';
const DEFAULT_LOG_RULE = "{ source in ['df_rum_harmonyos_log'] and message match ['.*local_filter_drop_log.*'] }";
const DEFAULT_RUM_RULE = "{ source in ['resource'] and resource_status in ['404'] }";

/**
 * Manual verification surface for FTSDKConfig local data filtering.
 * Rules are persisted here and are read by EntryAbility before the next SDK install.
 */
@Entry
@Component
export struct LocalDataFilterTestPage {
  @State enableDataFilter: boolean = true;
  @State loggingRule: string = DEFAULT_LOG_RULE;
  @State rumRule: string = DEFAULT_RUM_RULE;
  @State settingsSaved: boolean = false;
  @State restartRequired: boolean = true;
  @State resultOutput: string = 'Load the saved startup configuration before sending test data.';
  @State lastMarker: string = '';
  @State activeLocalRules: string = 'Loading saved startup rules...';
  @State activeRemoteRules: string = 'Loading remote Mock response...';
  @State remoteFilterEndpoint: string = '';
  @State remoteFilterEndpointSource: string = 'saved startup config';
  @State savedLoggingRule: string = '';
  @State savedRumRule: string = '';
  @StorageLink(RUNTIME_TEST_ACTIVE_ENDPOINT) runtimeTestEndpoint: string = '';
  @StorageLink(RUNTIME_TEST_ACTIVE_CLIENT_TOKEN) runtimeTestClientToken: string = '';
  @StorageLink(RUNTIME_TEST_ACTIVE_MODE) runtimeTestEndpointMode: string = '';
  private abilityContext: Context = getContext(this) as Context;
  private preferencesStore: preferences.Preferences | null = null;
  private remoteFilterUsesDataway: boolean = false;
  private remoteFilterClientToken: string = '';

  aboutToAppear(): void {
    this.loadSettings();
  }

  private async loadSettings(): Promise<void> {
    try {
      this.preferencesStore = await preferences.getPreferences(this.abilityContext, RUNTIME_CONFIG_PREFERENCES_NAME);
      const savedEnabled = await this.preferencesStore.get(KEY_LOCAL_DATA_FILTER_ENABLED, 'true') as string;
      const savedLoggingRule = await this.preferencesStore.get(KEY_LOCAL_DATA_FILTER_LOG_RULE, '') as string;
      const savedRumRule = await this.preferencesStore.get(KEY_LOCAL_DATA_FILTER_RUM_RULE, '') as string;
      const savedDatakitUrl = await this.preferencesStore.get(KEY_DATAKIT_URL, '') as string;
      const savedDatawayUrl = await this.preferencesStore.get(KEY_DATAWAY_URL, '') as string;
      const savedClientToken = await this.preferencesStore.get(KEY_CLIENT_TOKEN, '') as string;

      this.enableDataFilter = this.toBoolean(savedEnabled);
      this.settingsSaved = savedLoggingRule.trim().length > 0 || savedRumRule.trim().length > 0;
      this.savedLoggingRule = savedLoggingRule.trim();
      this.savedRumRule = savedRumRule.trim();
      this.remoteFilterUsesDataway = savedDatawayUrl.trim().length > 0;
      this.remoteFilterEndpoint = this.remoteFilterUsesDataway ? savedDatawayUrl.trim() : savedDatakitUrl.trim();
      this.remoteFilterClientToken = savedClientToken.trim();
      this.remoteFilterEndpointSource = this.remoteFilterUsesDataway
        ? 'saved startup DataWay'
        : 'saved startup DataKit';
      if (savedLoggingRule.trim().length > 0) {
        this.loggingRule = savedLoggingRule;
      }
      if (savedRumRule.trim().length > 0) {
        this.rumRule = savedRumRule;
      }
      this.restartRequired = !this.settingsSaved;
      this.refreshSavedLocalRules();
      void this.refreshRemoteMockRules();
      this.appendResult(this.settingsSaved
        ? 'Saved startup configuration loaded. You can send verification data.'
        : 'No filter rules are saved. The recommended rules are prefilled; save them and restart the Demo.');
    } catch (error) {
      this.appendResult(`Failed to load filter settings: ${error}`);
    }
  }

  private toBoolean(value: string): boolean {
    const normalized = value.trim().toLowerCase();
    return normalized !== 'false' && normalized !== '0' && normalized !== 'off';
  }

  private markSettingsChanged(): void {
    this.restartRequired = true;
  }

  private useRecommendedRules(): void {
    this.loggingRule = DEFAULT_LOG_RULE;
    this.rumRule = DEFAULT_RUM_RULE;
    this.enableDataFilter = true;
    this.markSettingsChanged();
    this.appendResult('Recommended rules restored. Save and restart before verification.');
  }

  private async saveSettings(): Promise<void> {
    try {
      if (this.loggingRule.trim().length === 0 && this.rumRule.trim().length === 0) {
        promptAction.showToast({ message: 'Configure at least one logging or RUM rule.' });
        return;
      }
      if (this.preferencesStore === null) {
        this.preferencesStore = await preferences.getPreferences(this.abilityContext, RUNTIME_CONFIG_PREFERENCES_NAME);
      }
      await this.preferencesStore.put(KEY_LOCAL_DATA_FILTER_ENABLED, this.enableDataFilter ? 'true' : 'false');
      await this.preferencesStore.put(KEY_LOCAL_DATA_FILTER_LOG_RULE, this.loggingRule.trim());
      await this.preferencesStore.put(KEY_LOCAL_DATA_FILTER_RUM_RULE, this.rumRule.trim());
      await this.preferencesStore.flush();
      AppStorage.setOrCreate(KEY_LOCAL_DATA_FILTER_ENABLED, this.enableDataFilter ? 'true' : 'false');
      AppStorage.setOrCreate(KEY_LOCAL_DATA_FILTER_LOG_RULE, this.loggingRule.trim());
      AppStorage.setOrCreate(KEY_LOCAL_DATA_FILTER_RUM_RULE, this.rumRule.trim());
      this.settingsSaved = true;
      this.savedLoggingRule = this.loggingRule.trim();
      this.savedRumRule = this.rumRule.trim();
      this.restartRequired = true;
      this.refreshSavedLocalRules();
      this.appendResult('Settings saved. Close and reopen the Demo application before sending verification data.');
      promptAction.showToast({ message: 'Settings saved. Close and reopen Demo to apply them.' });
    } catch (error) {
      this.appendResult(`Failed to save filter settings: ${error}`);
    }
  }

  /**
   * Local filtering is compiled during FTSDK.install, so this page cannot apply
   * a changed startup configuration to the already-running SDK instance.
   */
  private closeDemoToApplySettings(): void {
    promptAction.showToast({ message: 'Demo is closing. Open it again to apply the saved settings.' });
    setTimeout(() => {
      try {
        const uiAbilityContext = this.abilityContext as common.UIAbilityContext;
        uiAbilityContext.terminateSelf().catch((error: Error) => {
          this.appendResult(`Failed to close Demo: ${error}`);
        });
      } catch (error) {
        this.appendResult(`Failed to close Demo: ${error}`);
      }
    }, 300);
  }

  private sendVerificationData(): void {
    try {
      const marker = `${Date.now()}`;
      this.lastMarker = marker;
      FTLogger.i('LocalDataFilterDemo', `local_filter_drop_log_${marker}`);
      FTLogger.i('LocalDataFilterDemo', `local_filter_keep_log_${marker}`);
      this.sendResource(200, marker);
      this.sendResource(404, marker);
      setTimeout(() => {
        FTLogger.flush();
        FTSDK.flushSyncData();
      }, 180);
      this.appendResult(
        `Sent marker=${marker}. Expected with the recommended rules: drop log + resource 404 are absent; keep log + resource 200 are uploaded.`
      );
    } catch (error) {
      this.appendResult(`Failed to send verification data: ${error}`);
    }
  }

  private sendResource(status: number, marker: string): void {
    const resourceId = `local_data_filter_${status}_${marker}`;
    const rumManager = FTRUMGlobalManager.getInstance();
    const params = new ResourceParams();
    params.setUrl(`https://demo.guance.local/local-data-filter/${status}?marker=${marker}`);
    params.setResourceMethod('GET');
    params.setResourceStatus(status);
    params.setResponseContentLength(128);
    params.setResponseContentType('application/json');
    params.setResponseBody(`{"status":${status},"marker":"${marker}"}`);
    const networkStatus = new NetStatusBean();
    networkStatus.setHoleRequestTime(80);

    rumManager.startResource(resourceId);
    setTimeout(() => {
      rumManager.stopResource(resourceId);
      rumManager.addResource(resourceId, params, networkStatus);
    }, 80);
  }

  private refreshFilterTestRules(): void {
    this.refreshSavedLocalRules();
    void this.refreshRemoteMockRules();
  }

  private refreshSavedLocalRules(): void {
    if (!this.settingsSaved) {
      this.activeLocalRules = '(none saved)';
      return;
    }
    const enabled = this.enableDataFilter ? 'true' : 'false';
    const logging = this.savedLoggingRule.length > 0 ? this.savedLoggingRule : '(none)';
    const rum = this.savedRumRule.length > 0 ? this.savedRumRule : '(none)';
    this.activeLocalRules = `enabled: ${enabled}\nlogging:\n  ${logging}\nrum:\n  ${rum}`;
  }

  private async refreshRemoteMockRules(): Promise<void> {
    this.updateRemoteFilterEndpointFromRuntimeTest();
    const baseUrl = this.trimTrailingSlashes(this.remoteFilterEndpoint);
    if (baseUrl.length === 0) {
      this.activeRemoteRules = '(no runtime test or saved intake URL)';
      return;
    }

    let requestUrl = `${baseUrl}/v1/datakit/pull?precision=ns`;
    if (this.remoteFilterUsesDataway) {
      requestUrl += `&token=${encodeURIComponent(this.remoteFilterClientToken)}&to_headless=true`;
    }
    requestUrl += '&filters=true';

    const request = http.createHttp();
    try {
      const response = await request.request(requestUrl, {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/json' }
      });
      if (response.responseCode !== http.ResponseCode.OK) {
        this.activeRemoteRules = `Request failed: HTTP ${response.responseCode}`;
        this.appendResult(`Remote Mock response request failed: HTTP ${response.responseCode}.`);
        return;
      }
      this.activeRemoteRules = this.formatRemoteResponse(String(response.result));
      this.appendResult(`Remote Mock filter response refreshed from ${baseUrl}.`);
    } catch (error) {
      this.activeRemoteRules = `Request failed: ${error}`;
      this.appendResult(`Remote Mock response request failed: ${error}`);
    } finally {
      request.destroy();
    }
  }

  /**
   * Prefer the endpoint most recently applied in Runtime Endpoint Verification.
   * AppStorage is process-only, so a restart falls back to the saved startup
   * configuration loaded above without changing SDK persistence semantics.
   */
  private updateRemoteFilterEndpointFromRuntimeTest(): void {
    if (this.runtimeTestEndpointMode === RUNTIME_TEST_MODE_DATAWAY) {
      this.remoteFilterUsesDataway = true;
      this.remoteFilterEndpoint = this.runtimeTestEndpoint.trim();
      this.remoteFilterClientToken = this.runtimeTestClientToken.trim();
      this.remoteFilterEndpointSource = 'runtime test DataWay';
      return;
    }
    if (this.runtimeTestEndpointMode === RUNTIME_TEST_MODE_DATAKIT) {
      this.remoteFilterUsesDataway = false;
      this.remoteFilterEndpoint = this.runtimeTestEndpoint.trim();
      this.remoteFilterClientToken = '';
      this.remoteFilterEndpointSource = 'runtime test DataKit';
    }
  }

  private trimTrailingSlashes(value: string): string {
    let result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  private formatRemoteResponse(body: string): string {
    try {
      return JSON.stringify(JSON.parse(body) as Object, null, 2);
    } catch (_error) {
      return body;
    }
  }

  private appendResult(message: string): void {
    const timestamp = new Date().toLocaleTimeString();
    const nextOutput = `[${timestamp}] ${message}\n${this.resultOutput}`;
    this.resultOutput = nextOutput.length > 3000 ? nextOutput.substring(0, 3000) : nextOutput;
    DemoLogger.i(TAG, message);
  }

  private clearResults(): void {
    this.resultOutput = 'Result output cleared.';
    this.lastMarker = '';
  }

  build() {
    Column() {
      TestPageHeader({ title: 'Local Data Filter Test' })

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 8 }) {
            Text('Startup Configuration')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
            Text('Rules are read when FTSDK installs. Save changes, then close and reopen the Demo application to apply them.')
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')

            Row() {
              Toggle({ type: 0, isOn: this.enableDataFilter })
                .onChange((isOn: boolean) => {
                  this.enableDataFilter = isOn;
                  this.markSettingsChanged();
                })
              Text(`Enable local data filter: ${this.enableDataFilter ? 'ON' : 'OFF'}`)
                .fontSize(16)
                .margin({ left: 12 })
            }
            .width('100%')

            Text('Logging rule')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')
            TextInput({ text: this.loggingRule, placeholder: DEFAULT_LOG_RULE })
              .width('100%')
              .height(48)
              .fontSize(12)
              .backgroundColor('#FFFFFF')
              .border({ width: 1, color: '#D7DFEA' })
              .borderRadius(6)
              .onChange((value: string) => {
                this.loggingRule = value;
                this.markSettingsChanged();
              })

            Text('RUM rule')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')
            TextInput({ text: this.rumRule, placeholder: DEFAULT_RUM_RULE })
              .width('100%')
              .height(48)
              .fontSize(12)
              .backgroundColor('#FFFFFF')
              .border({ width: 1, color: '#D7DFEA' })
              .borderRadius(6)
              .onChange((value: string) => {
                this.rumRule = value;
                this.markSettingsChanged();
              })

            Button('Use Recommended Rules')
              .width('100%')
              .height(42)
              .backgroundColor('#6C757D')
              .onClick(() => this.useRecommendedRules())

            Button('Save Settings (Restart Required)')
              .width('100%')
              .height(48)
              .backgroundColor('#2563EB')
              .onClick(() => this.saveSettings())
            if (this.restartRequired && this.settingsSaved) {
              Button('Close Demo to Apply Settings')
                .width('100%')
                .height(42)
                .backgroundColor('#B45309')
                .onClick(() => this.closeDemoToApplySettings())
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)

          Column({ space: 8 }) {
            Row() {
              Text('Filter Test Configuration')
                .layoutWeight(1)
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
              Button('Refresh')
                .height(34)
                .backgroundColor('#2563EB')
                .onClick(() => this.refreshFilterTestRules())
            }
            .width('100%')

            Text('Local shows the saved startup configuration and becomes active after the Demo restarts. Remote directly requests the current-process endpoint from Runtime Endpoint Verification when available, otherwise the saved intake URL; it does not inspect SDK internal state. Check the Mock request log to confirm that the SDK fetched the same response.')
              .fontSize(12)
              .fontColor(Color.Gray)
              .lineHeight(18)
              .width('100%')

            Text('Local rules (saved startup config)')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')
            Text(this.activeLocalRules)
              .fontSize(12)
              .fontColor(TestPageTheme.RESULT_TEXT_COLOR)
              .fontFamily(TestPageTheme.RESULT_FONT_FAMILY)
              .lineHeight(18)
              .width('100%')
              .padding(10)
              .backgroundColor(TestPageTheme.RESULT_ROW_BACKGROUND)
              .borderRadius(6)

            Text(`Remote Mock response (${this.remoteFilterEndpointSource}: ${this.remoteFilterEndpoint.length > 0 ? this.remoteFilterEndpoint : 'no intake URL'})`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')
            Text(this.activeRemoteRules)
              .fontSize(12)
              .fontColor(TestPageTheme.RESULT_TEXT_COLOR)
              .fontFamily(TestPageTheme.RESULT_FONT_FAMILY)
              .lineHeight(18)
              .width('100%')
              .padding(10)
              .backgroundColor(TestPageTheme.RESULT_ROW_BACKGROUND)
              .borderRadius(6)
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)

          Column({ space: 8 }) {
            Text('Verification Data')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
            Text(this.restartRequired
              ? 'Test data can be sent now. Saved settings apply after the Demo is reopened; this send uses the current SDK configuration.'
              : 'Ready. Sends two logs and two RUM resources (200 / 404).')
              .fontSize(13)
              .fontColor(this.restartRequired ? '#B45309' : '#15803D')
              .width('100%')
            Button('Send Log and RUM Verification Data')
              .width('100%')
              .height(50)
              .backgroundColor('#16A34A')
              .onClick(() => this.sendVerificationData())
            Text('Expected for the recommended enabled rules: `local_filter_drop_log_*` and resource status 404 are filtered; `local_filter_keep_log_*` and status 200 remain.')
              .fontSize(12)
              .fontColor(Color.Gray)
              .width('100%')
            if (this.lastMarker.length > 0) {
              Text(`Latest marker: ${this.lastMarker}`)
                .fontSize(12)
                .fontColor('#2563EB')
                .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)

          Column({ space: 8 }) {
            Row() {
              Text('Result Output')
                .layoutWeight(1)
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
              Button('Clear')
                .height(32)
                .backgroundColor('#6C757D')
                .onClick(() => this.clearResults())
            }
            .width('100%')
            Text(this.resultOutput)
              .width('100%')
              .fontSize(12)
              .fontColor(TestPageTheme.RESULT_TEXT_COLOR)
              .fontFamily(TestPageTheme.RESULT_FONT_FAMILY)
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(TestPageTheme.RESULT_PANEL_BACKGROUND)
          .borderRadius(10)
          .margin({ bottom: 20 })
        }
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
