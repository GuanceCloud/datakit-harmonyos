import { uiObserver } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { DemoLogger } from '../utils/DemoLogger';
import { TestPageTheme } from '../constants/TestPageTheme';

const TAG = 'NavigationWebSwitchVerification';
const WEB_DESTINATION_NAME = '1';
const NATIVE_DESTINATION_NAME = 'NativeNavigationDestination';
const WEB_URL = 'https://www.example.com';

/**
 * Exercises the ArkUI Navigation -> NavDestination transition that is used by
 * uni-app's HarmonyOS page container. The embedded Web component makes the
 * resulting component tree comparable to a uni-app Web page:
 * Navigation -> NavDestination -> Web.
 */
@Entry
@Component
export struct NavigationWebSwitchVerificationPage {
  @State switchCount: number = 0;
  @State switchLog: string[] = [];

  private pathStack: NavPathStack = new NavPathStack();
  private webController: WebviewController = new webview.WebviewController();
  private observerRegistered: boolean = false;
  private navDestinationSwitchObserver: (info: uiObserver.NavDestinationSwitchInfo) => void =
    (info: uiObserver.NavDestinationSwitchInfo): void => {
      const message = `from: ${this.getDestinationDescription(info.from)}\nto: ${this.getDestinationDescription(info.to)}`;

      this.switchCount += 1;
      this.switchLog = [`#${this.switchCount} ${message}`, ...this.switchLog].slice(0, 6);
      DemoLogger.i(TAG, `[navDestinationSwitch] ${message}`);
    };

  aboutToAppear(): void {
    if (this.observerRegistered) {
      return;
    }
    this.getUIContext().getUIObserver().on('navDestinationSwitch', this.navDestinationSwitchObserver);
    this.observerRegistered = true;
    DemoLogger.i(TAG, 'navDestinationSwitch observer registered');
  }

  aboutToDisappear(): void {
    if (!this.observerRegistered) {
      return;
    }
    this.getUIContext().getUIObserver().off('navDestinationSwitch', this.navDestinationSwitchObserver);
    this.observerRegistered = false;
  }

  build() {
    Navigation(this.pathStack) {
      Column({ space: 16 }) {
        Text('Navigation + Web verification')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)

        Text('Open either destination to inspect the id and name fields received by UIObserver.on(\'navDestinationSwitch\').')
          .fontSize(14)
          .fontColor('#666666')
          .lineHeight(20)

        Button('Open Web NavDestination')
          .width('100%')
          .height(48)
          .backgroundColor('#0F766E')
          .onClick((): void => {
            this.pathStack.pushPath({ name: WEB_DESTINATION_NAME });
          })

        Button('Open Plain Native NavDestination')
          .width('100%')
          .height(48)
          .backgroundColor('#2563EB')
          .onClick((): void => {
            this.pathStack.pushPath({ name: NATIVE_DESTINATION_NAME });
          })

        this.buildSwitchLog()
      }
      .width('100%')
      .height('100%')
      .padding(20)
      .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
    }
    .title('Navigation Web Switch')
    .mode(NavigationMode.Stack)
    .id('lizhao-demo')
    .navDestination(this.buildDestination)
  }

  @Builder
  private buildDestination(name: string) {
    if (name === WEB_DESTINATION_NAME) {
      NavDestination() {
        Column({ space: 12 }) {
          Text('Web NavDestination')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)

          Text('Entering this screen should emit: navBar -> WebNavDestination. Returning emits the reverse transition.')
            .fontSize(14)
            .fontColor('#666666')
            .lineHeight(20)

          Web({ src: WEB_URL, controller: this.webController })
            .width('100%')
            .layoutWeight(1)
            .javaScriptAccess(true)

          Button('Back to Navigation home')
            .width('100%')
            .height(48)
            .onClick((): void => {
              this.pathStack.pop();
            })
        }
        .width('100%')
        .height('100%')
        .padding(16)
        .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
      }
      .title('Web NavDestination')
      .onBackPressed((): boolean => {
        this.pathStack.pop();
        return true;
      })
    } else if (name === NATIVE_DESTINATION_NAME) {
      NavDestination() {
        Column({ space: 16 }) {
          Text('Plain Native NavDestination')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)

          Text('This destination contains only native ArkUI components. Its switch event can be compared directly with the Web destination event.')
            .fontSize(14)
            .fontColor('#666666')
            .lineHeight(20)

          Text('Expected destination fields:\nname = NativeNavigationDestination\nnavigationId = lizhao-demo\nnavDestinationId = system generated')
            .fontSize(14)
            .fontColor('#1D4ED8')
            .width('100%')
            .padding(12)
            .backgroundColor('#EFF6FF')
            .borderRadius(8)

          Button('Back to previous destination')
            .width('100%')
            .height(48)
            .onClick((): void => {
              this.pathStack.pop();
            })
        }
        .width('100%')
        .height('100%')
        .padding(16)
        .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
      }
      .id('plain-native-destination-component')
      .title('Plain Native Destination')
      .onBackPressed((): boolean => {
        this.pathStack.pop();
        return true;
      })
    }
  }

  @Builder
  private buildSwitchLog() {
    Column({ space: 8 }) {
      Text(`navDestinationSwitch events: ${this.switchCount}`)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)

      if (this.switchLog.length === 0) {
        Text('No Navigation destination switch has been observed yet.')
          .fontSize(14)
          .fontColor('#666666')
      } else {
        ForEach(this.switchLog, (item: string) => {
          Text(item)
            .fontSize(14)
            .fontColor('#1D4ED8')
            .width('100%')
            .padding(10)
            .backgroundColor('#EFF6FF')
            .borderRadius(6)
        }, (item: string): string => item)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  private getDestinationDescription(item: uiObserver.NavDestinationInfo | 'navBar' | undefined): string {
    if (!item) {
      return 'none';
    }
    if (typeof item === 'string') {
      return item;
    }
    return `name=${this.getResourceString(item.name)}, navigationId=${this.getResourceString(item.navigationId)}, navDestinationId=${item.navDestinationId}, uniqueId=${item.uniqueId ?? 'none'}`;
  }

  private getResourceString(value: ResourceStr): string {
    return typeof value === 'string' ? value : '<resource>';
  }
}
