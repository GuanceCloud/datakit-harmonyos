import {
  AppState,
  ErrorType,
  FTLogger,
  FTRUMGlobalManager,
  FTSDK,
  NetStatusBean,
  ResourceParams,
  Status
} from '@guancecloud/ft_sdk/Index';
import { TestPageHeader } from '../components/TestPageHeader';
import {
  RUNTIME_TEST_ACTIVE_CLIENT_TOKEN,
  RUNTIME_TEST_ACTIVE_ENDPOINT,
  RUNTIME_TEST_ACTIVE_MODE,
  RUNTIME_TEST_MODE_DATAKIT,
  RUNTIME_TEST_MODE_DATAWAY
} from '../constants/RuntimeEndpointTestState';
import { TestPageTheme } from '../constants/TestPageTheme';

const TAG = 'RuntimeEndpointVerificationPage';
const RESULT_LIMIT = 6000;

/**
 * A hands-on verification page for runtime DataKit/Dataway endpoint updates.
 * Network delivery is intentionally verified by a person through a proxy,
 * mock collector, or server logs; the SDK cannot infer remote acceptance.
 */
@Entry
@Component
export struct RuntimeEndpointVerificationPage {
  @State datakitUrl: string = 'http://10.100.64.166:9529';
  @State datawayUrl: string = 'http://testing-openway.dataflux.cn';
  @State clientToken: string = '6f9661e3a4d048dd8571a7b7ddaca06e';
  @State activeMode: string = 'Not changed on this page';
  @State resultLog: string = '';
  @State datakitVerified: boolean = false;
  @State datawayVerified: boolean = false;
  @State invalidEndpointVerified: boolean = false;
  @State restartVerified: boolean = false;

  aboutToAppear(): void {
    this.appendResult('Page ready. Configure a collector URL, then apply an endpoint.\n');
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        TestPageHeader({ title: 'Runtime Endpoint Verification' })

        this.buildOverviewCard();
        this.buildEndpointForm();
        this.buildActionButtons();
        this.buildDataFilterButtons();
        this.buildManualChecklist();
        this.buildResultLog();
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 28 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }

  @Builder
  private buildOverviewCard() {
    Column({ space: 7 }) {
      Text('Manual verification guide')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(TestPageTheme.TITLE_COLOR)
      Text('Use a proxy, mock collector, or server log to check each marker. This page records your observations; it does not claim that the remote server accepted data.')
        .fontSize(13)
        .fontColor(TestPageTheme.RESULT_TEXT_COLOR)
        .lineHeight(19)
      Text(`Active mode: ${this.activeMode}`)
        .fontSize(13)
        .fontColor('#2563EB')
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(TestPageTheme.RESULT_CARD_BACKGROUND)
    .borderRadius(10)
  }

  @Builder
  private buildEndpointForm() {
    Column({ space: 8 }) {
      Text('Runtime endpoint configuration')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)

      Text('DataKit URL')
        .fontSize(13)
        .fontColor(Color.Gray)
      TextInput({ placeholder: 'https://datakit.example.com', text: this.datakitUrl })
        .width('100%')
        .height(44)
        .backgroundColor(Color.White)
        .borderRadius(8)
        .onChange((value: string) => {
          this.datakitUrl = value;
        })

      Text('Dataway URL')
        .fontSize(13)
        .fontColor(Color.Gray)
      TextInput({ placeholder: 'https://dataway.example.com', text: this.datawayUrl })
        .width('100%')
        .height(44)
        .backgroundColor(Color.White)
        .borderRadius(8)
        .onChange((value: string) => {
          this.datawayUrl = value;
        })

      Text('Dataway client token')
        .fontSize(13)
        .fontColor(Color.Gray)
      TextInput({ placeholder: 'Required for Dataway', text: this.clientToken })
        .width('100%')
        .height(44)
        .backgroundColor(Color.White)
        .borderRadius(8)
        .onChange((value: string) => {
          this.clientToken = value;
        })

      Text('Both modes require a complete http:// or https:// URL. Applying DataKit clears Dataway and its token; applying Dataway clears DataKit.')
        .fontSize(12)
        .fontColor(Color.Gray)
        .lineHeight(18)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  @Builder
  private buildActionButtons() {
    Column({ space: 9 }) {
      Button('Apply DataKit URL')
        .width('100%')
        .height(46)
        .backgroundColor('#2563EB')
        .onClick(() => {
          this.applyDatakit();
        })

      Button('Apply Dataway URL and Token')
        .width('100%')
        .height(46)
        .backgroundColor('#0F766E')
        .onClick(() => {
          this.applyDataway();
        })

      Button('Write Marker and Flush Now')
        .width('100%')
        .height(46)
        .backgroundColor('#D97706')
        .onClick(() => {
          this.writeMarkerAndFlush();
        })

      Button('Write Marker for Auto Upload Test')
        .width('100%')
        .height(46)
        .backgroundColor('#7C3AED')
        .onClick(() => {
          this.writeMarkerForAutoUpload();
        })
    }
    .width('100%')
  }

  @Builder
  private buildDataFilterButtons() {
    Column({ space: 9 }) {
      Text('Data filter verification')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)

      Text('Each action sends one or more matching markers and an unmatched control marker. For local filters, save rules in Local Data Filter Test and restart the Demo first. For remote filters, apply the Mock rules and wait for the pull request before sending data.')
        .fontSize(12)
        .fontColor(Color.Gray)
        .lineHeight(18)

      Button('Send Local Filter Log Pair')
        .width('100%')
        .height(46)
        .backgroundColor('#0F766E')
        .onClick(() => {
          this.sendLocalFilterLogPair();
        })

      Button('Send Local Filter RUM Pair')
        .width('100%')
        .height(46)
        .backgroundColor('#0F766E')
        .onClick(() => {
          this.sendLocalFilterRumPair();
        })

      Button('Send Remote Filter Log Set')
        .width('100%')
        .height(46)
        .backgroundColor('#B45309')
        .onClick(() => {
          this.sendRemoteFilterLogSet();
        })

      Button('Send Remote Filter RUM Set')
        .width('100%')
        .height(46)
        .backgroundColor('#B45309')
        .onClick(() => {
          this.sendRemoteFilterRumSet();
        })

      Button('Send Remote Filter View Pair')
        .width('100%')
        .height(46)
        .backgroundColor('#B45309')
        .onClick(() => {
          this.sendRemoteFilterViewPair();
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  @Builder
  private buildManualChecklist() {
    Column({ space: 9 }) {
      Text('Human verification results')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)

      this.buildChecklistRow(
        'DataKit request reached the configured DataKit endpoint',
        this.datakitVerified,
        (checked: boolean) => {
          this.datakitVerified = checked;
        }
      );
      this.buildChecklistRow(
        'Dataway request used the configured endpoint and client token',
        this.datawayVerified,
        (checked: boolean) => {
          this.datawayVerified = checked;
        }
      );
      this.buildChecklistRow(
        'Invalid URL or missing Dataway token caused no automatic request after 10 seconds',
        this.invalidEndpointVerified,
        (checked: boolean) => {
          this.invalidEndpointVerified = checked;
        }
      );
      this.buildChecklistRow(
        'After app restart, the runtime endpoint was set again before uploading',
        this.restartVerified,
        (checked: boolean) => {
          this.restartVerified = checked;
        }
      );

      Button('Clear Manual Results')
        .width('100%')
        .height(40)
        .backgroundColor('#64748B')
        .onClick(() => {
          this.clearManualResults();
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  @Builder
  private buildChecklistRow(label: string, checked: boolean, onChange: (value: boolean) => void) {
    Row({ space: 10 }) {
      Checkbox({ name: label })
        .select(checked)
        .onChange((value: boolean) => {
          onChange(value);
          this.appendResult(`Manual result updated: ${label} = ${value ? 'PASS' : 'NOT VERIFIED'}\n`);
        })
      Text(label)
        .layoutWeight(1)
        .fontSize(13)
        .fontColor(TestPageTheme.RESULT_TEXT_COLOR)
        .lineHeight(18)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(TestPageTheme.RESULT_ROW_BACKGROUND)
    .borderRadius(7)
  }

  @Builder
  private buildResultLog() {
    Column({ space: 8 }) {
      Text('Verification activity')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
      Text(this.resultLog.length > 0 ? this.resultLog : 'No activity yet')
        .fontSize(12)
        .fontColor(TestPageTheme.RESULT_TEXT_COLOR)
        .fontFamily(TestPageTheme.RESULT_FONT_FAMILY)
        .lineHeight(18)
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  private applyDatakit(): void {
    const url = this.datakitUrl.trim();
    FTSDK.setDatakitUrl(url);
    this.updateRuntimeTestEndpoint(RUNTIME_TEST_MODE_DATAKIT, url, '');
    this.activeMode = url.length > 0 ? `DataKit: ${url}` : 'DataKit: empty URL';
    this.appendResult(`Applied DataKit URL: ${url.length > 0 ? url : '(empty)'}\n`);
  }

  private applyDataway(): void {
    const url = this.datawayUrl.trim();
    const token = this.clientToken.trim();
    FTSDK.setDatawayUrl(url, token);
    this.updateRuntimeTestEndpoint(RUNTIME_TEST_MODE_DATAWAY, url, token);
    this.activeMode = url.length > 0 ? `Dataway: ${url}` : 'Dataway: empty URL';
    this.appendResult(`Applied Dataway URL: ${url.length > 0 ? url : '(empty)'}, token=${token.length > 0 ? 'provided' : 'empty'}\n`);
  }

  /**
   * Allows Demo verification pages to observe an endpoint switch in the
   * current process. It intentionally does not write Preferences.
   */
  private updateRuntimeTestEndpoint(mode: string, endpoint: string, clientToken: string): void {
    AppStorage.setOrCreate(RUNTIME_TEST_ACTIVE_MODE, mode);
    AppStorage.setOrCreate(RUNTIME_TEST_ACTIVE_ENDPOINT, endpoint);
    AppStorage.setOrCreate(RUNTIME_TEST_ACTIVE_CLIENT_TOKEN, clientToken);
  }

  private writeMarkerAndFlush(): void {
    const marker = this.createMarker('manual-flush');
    this.writeMarker(marker);
    FTSDK.flushSyncData();
    this.appendResult(`Wrote marker and called flushSyncData(): ${marker}\n`);
    this.appendResult('Inspect the request target and payload marker in your proxy, mock collector, or server logs.\n');
  }

  private writeMarkerForAutoUpload(): void {
    const marker = this.createMarker('auto-upload');
    this.writeMarker(marker);
    this.appendResult(`Wrote auto-upload marker: ${marker}\n`);
    this.appendResult('For invalid-address verification, wait at least 10 seconds and confirm no automatic request was sent.\n');
  }

  private writeMarker(marker: string): void {
    const properties: Map<string, object> = new Map();
    properties.set('manual_endpoint_marker', new String(marker));
    properties.set('manual_endpoint_mode', new String(this.activeMode));
    FTLogger.logBackground(marker, Status.INFO, properties);
  }

  private sendLocalFilterLogPair(): void {
    const marker = this.createMarker('local-filter-log');
    FTLogger.i(TAG, `local_filter_drop_log_${marker}`);
    FTLogger.i(TAG, `local_filter_keep_log_${marker}`);
    this.flushFilterVerificationData();
    this.appendResult(
      `Local log marker=${marker}. Expected with the recommended local rule: local_filter_drop_log is absent; local_filter_keep_log reaches /v1/write/logging.\n`
    );
  }

  private sendLocalFilterRumPair(): void {
    const marker = this.createMarker('local-filter-rum');
    this.sendVerificationResource(404, `local-filter-drop-${marker}`);
    this.sendVerificationResource(200, `local-filter-keep-${marker}`);
    this.flushFilterVerificationData();
    this.appendResult(
      `Local RUM marker=${marker}. Expected with the recommended local rule: Resource 404 is absent; Resource 200 reaches /v1/write/rum.\n`
    );
  }

  private sendRemoteFilterLogSet(): void {
    const marker = this.createMarker('remote-filter-log');
    FTLogger.i(TAG, `remote-secret-num-${marker}`);
    FTLogger.i(TAG, `remote-password-num-${marker}`);
    FTLogger.i(TAG, `remote-token-num-${marker}`);
    FTLogger.i(TAG, `filter-test-log-num-${marker}`);
    FTLogger.i(TAG, `remote-filter-log-keep-${marker}`);
    this.flushFilterVerificationData();
    this.appendResult(
      `Remote log marker=${marker}. The first four messages match the configured *-num rules and should be absent; remote-filter-log-keep should reach /v1/write/logging.\n`
    );
  }

  private sendRemoteFilterRumSet(): void {
    const marker = this.createMarker('remote-filter-rum');
    const rumManager = FTRUMGlobalManager.getInstance();
    const filteredStatuses: Array<number> = [200, 401, 403, 404, 500, 502, 503];
    for (let index = 0; index < filteredStatuses.length; index++) {
      this.sendVerificationResource(filteredStatuses[index], `remote-filter-drop-${marker}`);
    }
    this.sendVerificationResource(200, `remote-filter-keep-${marker}`);
    rumManager.addError(
      `remote-filter-error-stack-${marker}`,
      `remote-secret-${marker}`,
      ErrorType.CUSTOM,
      AppState.RUN
    );
    rumManager.addError(
      `remote-filter-password-stack-${marker}`,
      `remote-password-${marker}`,
      ErrorType.CUSTOM,
      AppState.RUN
    );
    rumManager.addError(
      `remote-filter-control-stack-${marker}`,
      `remote-filter-error-keep-${marker}`,
      ErrorType.CUSTOM,
      AppState.RUN
    );
    rumManager.addAction(`filter-test-action-${marker}`, 'click');
    rumManager.addAction(`remote-filter-action-keep-${marker}`, 'click');
    this.flushFilterVerificationData();
    this.appendResult(
      `Remote RUM marker=${marker}. Resources 401/403/404/500/502/503, errors remote-secret and remote-password, and action filter-test-action should be absent; the 200 resource, remote-filter-error-keep, and remote-filter-action-keep should reach /v1/write/rum.\n`
    );
  }

  private sendRemoteFilterViewPair(): void {
    const marker = this.createMarker('remote-filter-view');
    this.sendVerificationView(`filter-test-view-${marker}`, () => {
      this.sendVerificationView(`remote-filter-view-keep-${marker}`, () => {
        this.flushFilterVerificationData();
      });
    });
    this.appendResult(
      `Remote View marker=${marker}. filter-test-view should be absent; remote-filter-view-keep should reach /v1/write/rum. This action temporarily replaces the active RUM View for the current page.\n`
    );
  }

  private sendVerificationView(viewName: string, onStopped: () => void): void {
    const rumManager = FTRUMGlobalManager.getInstance();
    rumManager.startView(viewName).then(() => {
      setTimeout(() => {
        rumManager.stopView({}).then(() => {
          onStopped();
        }).catch((error: Error) => {
          this.appendResult(`Failed to stop verification View: ${error.message}\n`);
        });
      }, 80);
    }).catch((error: Error) => {
      this.appendResult(`Failed to start verification View: ${error.message}\n`);
    });
  }

  private sendVerificationResource(status: number, marker: string): void {
    const resourceId = `runtime_endpoint_filter_${status}_${marker}`;
    const params = new ResourceParams();
    params.setUrl(`https://demo.guance.local/runtime-endpoint-filter/${status}?marker=${marker}`);
    params.setResourceMethod('GET');
    params.setResourceStatus(status);
    params.setResponseContentLength(128);
    params.setResponseContentType('application/json');
    params.setResponseBody(`{"status":${status},"marker":"${marker}"}`);

    const networkStatus = new NetStatusBean();
    networkStatus.setHoleRequestTime(80);

    const rumManager = FTRUMGlobalManager.getInstance();
    rumManager.startResource(resourceId);
    setTimeout(() => {
      rumManager.stopResource(resourceId);
      rumManager.addResource(resourceId, params, networkStatus);
    }, 80);
  }

  private flushFilterVerificationData(): void {
    setTimeout(() => {
      FTLogger.flush();
      FTSDK.flushSyncData();
    }, 180);
  }

  private createMarker(kind: string): string {
    return `runtime-endpoint-${kind}-${Date.now()}`;
  }

  private clearManualResults(): void {
    this.datakitVerified = false;
    this.datawayVerified = false;
    this.invalidEndpointVerified = false;
    this.restartVerified = false;
    this.resultLog = '';
    this.appendResult('Manual verification results cleared.\n');
  }

  private appendResult(message: string): void {
    const timestamp = new Date().toLocaleTimeString();
    const next = `[${timestamp}] ${message}${this.resultLog}`;
    this.resultLog = next.length > RESULT_LIMIT ? next.slice(0, RESULT_LIMIT) : next;
  }
}
