import router from '@ohos.router';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';

@Entry
@Component
export struct NavigationStackDemoPage {
  build() {
    Column() {
      TestPageHeader({
        title: 'Navigation Stack Demo'
      })

      Column() {
        Text('Main Navigation Page').fontSize(24).margin({ bottom: 20 })
        Button('Go To SubPage1')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => { router.pushUrl({ url: 'pages/NavSubPage1' }); })
        Button('Go To SubPage2')
          .width('100%')
          .height(50)
          .onClick(() => { router.pushUrl({ url: 'pages/NavSubPage2' }); })
      }.padding(20)
    }.width('100%').height('100%').backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}

