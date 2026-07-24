import { FTLogger, FTSDK, Status } from '@guancecloud/ft_sdk/Index';
import { TestPageHeader } from '../components/TestPageHeader';
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
  @State datakitUrl: string = '';
  @State datawayUrl: string = '';
  @State clientToken: string = '';
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
    this.activeMode = url.length > 0 ? `DataKit: ${url}` : 'DataKit: empty URL';
    this.appendResult(`Applied DataKit URL: ${url.length > 0 ? url : '(empty)'}\n`);
  }

  private applyDataway(): void {
    const url = this.datawayUrl.trim();
    const token = this.clientToken.trim();
    FTSDK.setDatawayUrl(url, token);
    this.activeMode = url.length > 0 ? `Dataway: ${url}` : 'Dataway: empty URL';
    this.appendResult(`Applied Dataway URL: ${url.length > 0 ? url : '(empty)'}, token=${token.length > 0 ? 'provided' : 'empty'}\n`);
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
