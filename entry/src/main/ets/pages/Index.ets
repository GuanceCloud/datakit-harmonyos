import { webview } from '@kit.ArkWeb';
import router from '@ohos.router';
import { CommonConstants } from '../constants/CommonConstants';
import { Context } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'Index';

@Entry
@Component
struct Index {
  @State message: string = 'FT SDK HarmonyOS Test App';
  @State context: Context = getContext(this) as Context;

  build() {
    Column() {
      // Home page
        Column() {
          Text(this.message)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .margin({ top: 20, bottom: 20 })
            .textAlign(TextAlign.Center)

          List() {
            // Unified RUM data test page
            ListItem() {
              Button() {
                Text("RUM Unified Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#4CAF50')
              .onClick(() => {
                router.pushUrl({ url: 'pages/RUMDataTestPage' })
              })
            }
            .margin({ bottom: 10 })


            // Session Replay protocol POC page
            ListItem() {
              Button() {
                Text("Session Replay POC")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#0E7490')
              .onClick(() => {
                router.pushUrl({ url: 'pages/SessionReplayPocPage' })
              })
            }
            .margin({ bottom: 10 })

            // Action Count test page
            ListItem() {
              Button() {
                Text("Action Count Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#9C27B0')
              .onClick(() => {
                router.pushUrl({ url: 'pages/ActionCountTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // View update time test page
            ListItem() {
              Button() {
                Text("View Update Time Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#673AB7')
              .onClick(() => {
                router.pushUrl({ url: 'pages/ViewUpdateTimeTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // UI Block test page
            ListItem() {
              Button() {
                Text("UI Block Detection Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#FF6B35')
              .onClick(() => {
                router.pushUrl({ url: 'pages/UIBlockTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // Crash and ANR test page
            ListItem() {
              Button() {
                Text("Crash & ANR")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#FF5252')
              .onClick(() => {
                router.pushUrl({ url: 'pages/CrashTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // Button click auto-tracking test page
            ListItem() {
              Button() {
                Text("Button Click Auto-Tracking Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50).onClick(() => {
                router.pushUrl({ url: 'pages/ButtonClickTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // Navigation Stack Demo (application-track)
            ListItem() {
              Button() {
                Text("Navigation Stack Demo")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50).onClick(() => {
                router.pushUrl({ url: 'pages/NavigationStackDemoPage' })
              })
            }
            .margin({ bottom: 10 })

            // Navigation + Web NavDestination switch verification page
            ListItem() {
              Button() {
                Text("Navigation Web Switch Verification")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#0F766E')
              .onClick(() => {
                router.pushUrl({ url: 'pages/NavigationWebSwitchVerificationPage' })
              })
            }
            .margin({ bottom: 10 })

            // WebView test page
            ListItem() {
              Button() {
                Text("WebView Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50).onClick(() => {
                router.pushUrl({ url: 'pages/WebViewPage' })
              })
            }
            .margin({ bottom: 10 })

            // Trace test page
            ListItem() {
              Button() {
                Text("Trace Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50).onClick(() => {
                router.pushUrl({ url: 'pages/TraceTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // HTTP Interceptor Test
            ListItem() {
              Button() {
                Text("HTTP Interceptor Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50).onClick(() => {
                router.pushUrl({ url: 'pages/HttpAutoTrackTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // LogBackground test page
            ListItem() {
              Button() {
                Text("LogBackground Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50).onClick(() => {
                router.pushUrl({ url: 'pages/LogBackgroundTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // Local data filter test page
            ListItem() {
              Button() {
                Text("Local Data Filter Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#0F766E')
              .onClick(() => {
                router.pushUrl({ url: 'pages/LocalDataFilterTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // Data modification and masking test page
            ListItem() {
              Button() {
                Text("Data Modifier Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#00838F')
              .onClick(() => {
                router.pushUrl({ url: 'pages/DataModifierTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // Inner log file test page
            ListItem() {
              Button() {
                Text("Inner Log File Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#546E7A')
              .onClick(() => {
                router.pushUrl({ url: 'pages/InnerLogFileTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // Batch Upload Test
            ListItem() {
              Button() {
                Text("Batch Upload Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50).onClick(() => {
                router.pushUrl({ url: 'pages/BatchUploadTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // Data Sync & Clear test page
            ListItem() {
              Button() {
                Text("Data Sync & Clear Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50).onClick(() => {
                router.pushUrl({ url: 'pages/DataSyncTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // Runtime reporting endpoint manual verification page
            ListItem() {
              Button() {
                Text("Runtime Endpoint Verification")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#0F766E')
              .onClick(() => {
                router.pushUrl({ url: 'pages/RuntimeEndpointVerificationPage' })
              })
            }
            .margin({ bottom: 10 })

            // Rate limit test page
            ListItem() {
              Button() {
                Text("Rate Limiting Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50).onClick(() => {
                router.pushUrl({ url: 'pages/RateLimitTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // DB Cache Limit test page
            ListItem() {
              Button() {
                Text("DB Cache Limit Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50).onClick(() => {
                router.pushUrl({ url: 'pages/DBCacheLimitTestPage' })
              })
            }
            .margin({ bottom: 10 })

            // Real App Stress Test Page
            ListItem() {
              Button() {
                Text("Real App Stress Test")
              }.width(CommonConstants.FULL_PERCENT)
              .fontColor(Color.White)
              .height(50)
              .backgroundColor('#4CAF50')
              .onClick(() => {
                router.pushUrl({ url: 'pages/RealAppStressTestPage' })
              })
            }
            .margin({ bottom: 10 })
          }
          .layoutWeight(1)
          .backgroundColor(Color.White)
          .scrollBar(BarState.Off)
          .borderRadius($r('app.float.ohos_id_corner_radius_default_l'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({ left: 20, right: 20, top: 20, bottom: 36 })
        }
        .width(CommonConstants.FULL_PERCENT)
        .height(CommonConstants.FULL_PERCENT)
    }
    .height(CommonConstants.FULL_PERCENT)
    .width(CommonConstants.FULL_PERCENT)
    .backgroundColor($r('app.color.list_exchange_background_color'))
    .padding({
      left: $r('app.float.ohos_id_card_padding_start'),
      right: $r('app.float.ohos_id_card_padding_start')
    })
  }

  aboutToAppear(): void {
    webview
      .WebviewController
      .setWebDebuggingAccess(true)
    
    // Ensure Context is correctly obtained
    this.context = getContext(this) as Context;
    
    // SDK is initialized in EntryAbility
    DemoLogger.i(TAG, 'SDK already initialized in EntryAbility');
  }



}
