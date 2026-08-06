import { FTSDK } from '@guancecloud/ft_sdk/Index';
import promptAction from '@ohos.promptAction';
import * as ftcrash from 'libftcrash.so';
import { SimpleAPMManager } from '../utils/SimpleAPMManager';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'CrashTestPage';

@Entry
@Component
export struct CrashTestPage {
  @State message: string = 'Crash & ANR';
  @State testResults: string = '';
  @State isSDKInitialized: boolean = false;

  aboutToAppear(): void {
    this.checkSDKStatus();
    this.addTestResult('Crash & ANR page loaded');
  }

  private checkSDKStatus(): void {
    try {
      const rumConfig = FTSDK.getRumConfig();
      this.isSDKInitialized = rumConfig !== null && rumConfig.getRumAppId().length > 0;
      this.addTestResult(`SDK Status: ${this.isSDKInitialized ? '✅ Initialized' : '❌ Not Initialized'}`);
    } catch (error) {
      this.isSDKInitialized = false;
      this.addTestResult(`❌ Error checking SDK status: ${JSON.stringify(error as object)}`);
    }
  }

  private triggerJsCrash(): void {
    if (!this.isSDKInitialized) {
      this.addTestResult('❌ SDK not initialized, skipping JS crash test');
      this.showToast('SDK not initialized');
      return;
    }

    this.addTestResult('💥 Triggering JS crash...');
    this.addTestResult('⚠️ HarmonyOS may catch the exception without fully exiting the app');
    this.addTestResult('📋 Check logs for "errorManager onException"');

    setTimeout((): void => {
      throw new Error('Intentional JS crash for Crash & ANR testing');
    }, 100);

    this.showToast('JS crash triggered');
  }

  private triggerCppCrash(): void {
    this.addTestResult('💥 Triggering C++ crash...');
    this.addTestResult('⚠️ WARNING: This will cause a native crash');
    this.showToast('Triggering C++ crash...');

    setTimeout(() => {
      try {
        ftcrash.triggerNullPointerCrash();
      } catch (error) {
        this.addTestResult(`❌ C++ crash error: ${JSON.stringify(error as object)}`);
      }
    }, 500);
  }

  private triggerANR(): void {
    if (!this.isSDKInitialized) {
      this.addTestResult('❌ SDK not initialized, skipping ANR test');
      this.showToast('SDK not initialized');
      return;
    }

    try {
      this.addTestResult('⏱️ Triggering ANR test for 10 seconds...');
      this.addTestResult('📋 Check logs for ANR detection output');
      SimpleAPMManager.getInstance().triggerANRTest(10000);
      this.showToast('ANR test started');
    } catch (error) {
      this.addTestResult(`❌ Failed to trigger ANR test: ${JSON.stringify(error as object)}`);
    }
  }

  private clearResults(): void {
    this.testResults = '';
    this.addTestResult('Test results cleared');
  }

  private addTestResult(result: string): void {
    const timestamp = new Date().toLocaleTimeString();
    this.testResults += `[${timestamp}] ${result}\n`;
    const lines = this.testResults.split('\n');
    if (lines.length > 60) {
      this.testResults = lines.slice(lines.length - 60).join('\n');
    }
    DemoLogger.i(TAG, result);
  }

  private showToast(message: string): void {
    promptAction.showToast({
      message: message,
      duration: 2000
    });
  }

  build() {
    Column() {
      TestPageHeader({
        title: this.message
      })

      Column() {
        Text(`SDK: ${this.isSDKInitialized ? '✅ Initialized' : '❌ Not Initialized'}`)
          .fontSize(15)
          .margin({ bottom: 6 })
        Text('This page keeps only JS Crash, C++ Crash, and ANR tests.')
          .fontSize(13)
          .fontColor('#666666')
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#F5F5F5')
      .borderRadius(8)
      .margin({ bottom: 12 })

      Column() {
        Button('JS Crash')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .backgroundColor('#FF5252')
          .fontColor(Color.White)
          .onClick(() => {
            this.triggerJsCrash();
          })

        Button('Cpp Crash')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .backgroundColor('#F44336')
          .fontColor(Color.White)
          .onClick(() => {
            this.triggerCppCrash();
          })

        Button('ANR (10s)')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .backgroundColor('#FF9800')
          .fontColor(Color.White)
          .onClick(() => {
            this.triggerANR();
          })

        Row() {
          Button('Refresh Status')
            .layoutWeight(1)
            .height(40)
            .width('100%')
            .onClick(() => {
              this.checkSDKStatus();
            })
        }
        .width('100%')
        .margin({ top: 10, bottom: 16 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
