import { FTInnerLogger } from '@guancecloud/ft_sdk/src/main/ets/components/log/FTLogger';
import { FTInnerLogFileManager } from '@guancecloud/ft_sdk/src/main/ets/components/log/FTInnerLogFileManager';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'InnerLogFileTestPage';

@Entry
@Component
export struct InnerLogFileTestPage {
  @State enabledText: string = 'Unknown';
  @State initializedText: string = 'Unknown';
  @State logDir: string = '';
  @State currentFilePath: string = '';
  @State totalSize: string = '0 B';
  @State fileCount: number = 0;
  @State queueSize: number = 0;
  @State droppedCount: number = 0;
  @State lastError: string = '';
  @State resultText: string = '';
  @State isRunning: boolean = false;

  aboutToAppear(): void {
    this.refreshStatus();
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        TestPageHeader({
          title: 'Inner Log File Test'
        })

        Column({ space: 8 }) {
          Text(`Enabled: ${this.enabledText}`)
            .fontSize(15)
          Text(`Initialized: ${this.initializedText}`)
            .fontSize(15)
          Text(`Total Size: ${this.totalSize}`)
            .fontSize(15)
          Text(`File Count: ${this.fileCount}`)
            .fontSize(15)
          Text(`Queue Size: ${this.queueSize}`)
            .fontSize(15)
          Text(`Dropped: ${this.droppedCount}`)
            .fontSize(15)
          Text(`Directory: ${this.logDir.length > 0 ? this.logDir : 'Unavailable'}`)
            .fontSize(12)
            .fontColor(Color.Gray)
            .width('100%')
          Text(`Current File: ${this.currentFilePath.length > 0 ? this.currentFilePath : 'Unavailable'}`)
            .fontSize(12)
            .fontColor(Color.Gray)
            .width('100%')
          if (this.lastError.length > 0) {
            Text(`Last Error: ${this.lastError}`)
              .fontSize(12)
              .fontColor(Color.Red)
              .width('100%')
          }
        }
        .padding(16)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .width('90%')

        Button('Generate 10 Inner Logs')
          .width('90%')
          .height(48)
          .enabled(!this.isRunning)
          .backgroundColor('#007DFF')
          .onClick(() => {
            this.generateInnerLogs(10);
          })

        Button('Generate 25 Inner Logs')
          .width('90%')
          .height(48)
          .enabled(!this.isRunning)
          .backgroundColor('#28A745')
          .onClick(() => {
            this.generateInnerLogs(25);
          })

        Button('Flush Now')
          .width('90%')
          .height(48)
          .enabled(!this.isRunning)
          .backgroundColor('#FFC107')
          .onClick(() => {
            this.flushNow();
          })

        Button('Clear Inner Log Files')
          .width('90%')
          .height(48)
          .enabled(!this.isRunning)
          .backgroundColor('#DC3545')
          .onClick(() => {
            this.clearFiles();
          })

        Button('Refresh Status')
          .width('90%')
          .height(40)
          .backgroundColor('#6C757D')
          .onClick(() => {
            this.refreshStatus();
          })

        Text('Result Output')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .width('90%')
          .textAlign(TextAlign.Start)

        Column() {
          Text(this.resultText.length > 0 ? this.resultText : 'No output yet')
            .fontSize(12)
            .fontColor('#333333')
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .padding(12)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .width('90%')
        .margin({ bottom: 10 })
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }

  private async refreshStatus(): Promise<void> {
    try {
      const manager = FTInnerLogFileManager.getInstance();
      const status = manager.getStatus();
      this.enabledText = status.enabled ? 'Enabled' : 'Disabled';
      this.initializedText = status.initialized ? 'Initialized' : 'Not Initialized';
      this.logDir = status.logDir;
      this.currentFilePath = status.currentFilePath;
      this.queueSize = status.queueSize;
      this.droppedCount = status.droppedCount;
      this.lastError = status.lastError;
      this.totalSize = this.formatBytes(await manager.getTotalLogSize());
      this.fileCount = await manager.getLogFileCount();
    } catch (error) {
      this.appendResult(`Refresh status failed: ${error}\n`);
    }
  }

  private generateInnerLogs(count: number): void {
    this.isRunning = true;
    this.appendResult(`Generating ${count} inner logs...\n`);
    try {
      for (let i = 0; i < count; i++) {
        FTInnerLogger.i(TAG, `Inner log file demo record ${i + 1}/${count}, ts=${Date.now()}`);
      }

      setTimeout(() => {
        this.refreshStatus();
        this.appendResult(`Generated ${count} inner logs\n`);
        this.isRunning = false;
      }, 500);
    } catch (error) {
      this.appendResult(`Generate inner logs failed: ${error}\n`);
      this.isRunning = false;
    }
  }

  private async flushNow(): Promise<void> {
    this.isRunning = true;
    this.appendResult('Flushing inner log file queue...\n');
    try {
      await FTInnerLogFileManager.getInstance().flushNow();
      await this.refreshStatus();
      this.appendResult('Flush completed\n');
    } catch (error) {
      this.appendResult(`Flush failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private async clearFiles(): Promise<void> {
    this.isRunning = true;
    this.appendResult('Clearing inner log files...\n');
    try {
      await FTInnerLogFileManager.getInstance().clear();
      await this.refreshStatus();
      this.appendResult('Inner log files cleared\n');
    } catch (error) {
      this.appendResult(`Clear files failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private appendResult(text: string): void {
    this.resultText += text;
    const lines = this.resultText.split('\n');
    if (lines.length > 80) {
      this.resultText = lines.slice(lines.length - 80).join('\n');
    }
    DemoLogger.i(TAG, text.trim());
  }

  private formatBytes(bytes: number): string {
    if (bytes < 0 || isNaN(bytes) || !isFinite(bytes)) {
      return '0 B';
    }
    if (bytes === 0) {
      return '0 B';
    }

    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const index = Math.floor(Math.log(bytes) / Math.log(k));
    if (index < 0 || index >= sizes.length) {
      return '0 B';
    }
    return `${(bytes / Math.pow(k, index)).toFixed(2)} ${sizes[index]}`;
  }
}
