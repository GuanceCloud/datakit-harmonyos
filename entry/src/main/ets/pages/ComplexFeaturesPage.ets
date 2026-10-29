import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import process from '@ohos.process';
import { CommonConstants } from '../constants/CommonConstants';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';

@Entry
@Component
struct ComplexFeaturesPage {
  build() {
    Column() {
      TestPageHeader({ title: '复杂功能与相关复现', backText: '返回' })

      List() {
        ListItem() {
          Button('构建插件语法验证')
            .id('hvigor-syntax-open').width(CommonConstants.FULL_PERCENT).height(50)
            .backgroundColor('#2563EB')
            .onClick(() => { router.pushUrl({ url: 'pages/HvigorSyntaxVerificationPage' }); })
        }.margin({ bottom: 10 })

        ListItem() {
          Button('启动来源与挂起计时（重启测试）')
            .id('launch-suspend-open').width(CommonConstants.FULL_PERCENT).height(50)
            .backgroundColor('#0F766E')
            .onClick(() => {
              const context = getContext(this) as common.UIAbilityContext;
              context.restartApp({ bundleName: context.abilityInfo.bundleName,
                moduleName: 'entry', abilityName: 'LaunchSuspendTestAbility' })
                .catch((error: Error): void => {
                  promptAction.showToast({ message: `无法打开启动挂起测试：${error.message}` });
                });
            })
        }.margin({ bottom: 10 })

        ListItem() {
          Button('应用对象堆压力（273 MiB）')
            .id('app-heap-open').width(CommonConstants.FULL_PERCENT).height(50)
            .backgroundColor('#9A3412')
            .onClick(() => {
              const context = getContext(this) as common.UIAbilityContext;
              context.restartApp({ bundleName: context.abilityInfo.bundleName,
                moduleName: 'entry', abilityName: 'HeapPressureTestAbility' })
                .catch((error: Error): void => {
                  promptAction.showToast({ message: `无法启动堆压力入口：${error.message}` });
                });
            })
        }.margin({ bottom: 10 })

        ListItem() {
          Button('RUM 完整集成崩溃复现')
            .id('rum-integrated-open').width(CommonConstants.FULL_PERCENT).height(50)
            .backgroundColor('#B45309')
            .onClick(() => { router.pushUrl({ url: 'pages/RUMIntegratedReproPage' }); })
        }.margin({ bottom: 10 })

        ListItem() {
          Button('RUM Session Lifecycle A/B（重启测试）')
            .id('rum-lifecycle-open')
            .width(CommonConstants.FULL_PERCENT)
            .height(50)
            .backgroundColor('#7C3AED')
            .onClick(() => {
              const context = getContext(this) as common.UIAbilityContext;
              AlertDialog.show({
                title: '重启到专用测试入口',
                message: '将重启 Demo，不清除应用数据。测试进程不初始化正常业务 SDK，在真实主线程运行生命周期验证。完成后可重启回 Demo。',
                primaryButton: { value: '取消', action: (): void => {} },
                secondaryButton: { value: '重启进入', action: (): void => {
                  context.restartApp({
                    bundleName: context.abilityInfo.bundleName,
                    abilityName: 'RUMSessionLifecycleTestAbility',
                    moduleName: 'entry',
                    parameters: { lifecycleParentPid: process.pid }
                  }).catch((error: Error): void => {
                    promptAction.showToast({ message: `无法打开隔离测试页：${error.message}` });
                  });
                } }
              });
            })
        }.margin({ bottom: 10 })

        // Separate-process WorkScheduler background-launch diagnostics
        ListItem() {
          Button() {
            Text("WorkScheduler Background Launch")
          }.width(CommonConstants.FULL_PERCENT)
          .fontColor(Color.White)
          .height(50)
          .backgroundColor('#1D4ED8')
          .onClick(() => {
            router.pushUrl({ url: 'pages/BackgroundLaunchWorkSchedulerPage' })
          })
        }
        .margin({ bottom: 10 })
      }
      .layoutWeight(1)
      .width(CommonConstants.FULL_PERCENT)
      .padding({ left: 20, right: 20, top: 20, bottom: 36 })
      .scrollBar(BarState.Off)
    }
    .height(CommonConstants.FULL_PERCENT)
    .width(CommonConstants.FULL_PERCENT)
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
