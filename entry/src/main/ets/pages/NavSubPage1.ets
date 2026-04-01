import router from '@ohos.router';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';

@Entry
@Component
export struct NavSubPage1 {
  build() {
    Column() {
      TestPageHeader({
        title: 'Navigation SubPage1'
      })

      Column() {
        Text('This is SubPage1').fontSize(24).margin({ bottom: 20 })
        Button('Back to Main')
          .width('100%')
          .height(50)
          .onClick(() => { router.back(); })
      }.padding(20)
    }.width('100%').height('100%').backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}

