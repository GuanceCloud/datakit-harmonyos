import router from '@ohos.router';
import { TestPageTheme } from '../constants/TestPageTheme';

@Component
export struct TestPageHeader {
  title: string = '';
  backText: string = 'Back';
  onBack: () => void = () => {
    router.back();
  };
  backCustomPropertyGroup: string = 'test-page-header';
  backCustomPropertyValue: string = 'back';

  build() {
    Row({ space: TestPageTheme.HEADER_CONTENT_GAP }) {
      Button() {
        Text(`← ${this.backText}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(TestPageTheme.BACK_BUTTON_TEXT)
      }
      .type(ButtonType.Capsule)
      .height(TestPageTheme.BACK_BUTTON_HEIGHT)
      .backgroundColor(TestPageTheme.BACK_BUTTON_BACKGROUND)
      .borderRadius(TestPageTheme.BACK_BUTTON_RADIUS)
      .padding({ left: 14, right: 14 })
      .customProperty(this.backCustomPropertyGroup, this.backCustomPropertyValue)
      .onClick(() => {
        this.onBack();
      })

      Text(this.title)
        .layoutWeight(1)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(TestPageTheme.TITLE_COLOR)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({
      left: TestPageTheme.HEADER_HORIZONTAL_PADDING,
      right: TestPageTheme.HEADER_HORIZONTAL_PADDING,
      top: TestPageTheme.HEADER_VERTICAL_PADDING,
      bottom: TestPageTheme.HEADER_VERTICAL_PADDING
    })
    .backgroundColor(TestPageTheme.HEADER_BACKGROUND)
    .border({
      width: { bottom: 1 },
      color: TestPageTheme.HEADER_BORDER
    })
  }
}
