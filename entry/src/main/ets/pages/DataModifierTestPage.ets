import { FTLogger, Status } from '@guancecloud/ft_sdk/Index';
import { TestPageHeader } from '../components/TestPageHeader';
import {
  FIELD_MASK,
  LINE_MASK,
  LINE_SOURCE_MESSAGE
} from '../utils/DataModifierDemo';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'DataModifierTestPage';

@Entry
@Component
export struct DataModifierTestPage {
  @State results: string[] = [];

  private appendResult(message: string): void {
    const timestamp = new Date().toLocaleTimeString();
    this.results = [`[${timestamp}] ${message}`, ...this.results].slice(0, 20);
    DemoLogger.i(TAG, message);
  }

  private sendFieldModifierLog(): void {
    const properties = new Map<string, object>();
    properties.set('demo_sensitive_tag', new String('field-tag-secret'));
    properties.set('demo_sensitive_field', new String('field-value-secret'));
    properties.set('demo_visible_field', new String('visible-value'));

    FTLogger.logBackground('demo-field-modifier-message', Status.INFO, properties);
    this.appendResult(`Field callback sent. Expect demo_sensitive_*=${FIELD_MASK}; demo_visible_field remains visible.`);
  }

  private sendLineModifierLog(): void {
    const properties = new Map<string, object>();
    properties.set('demo_line_sensitive_field', new String('line-field-secret'));
    properties.set('demo_line_visible_field', new String('line-visible-value'));

    FTLogger.logBackground(LINE_SOURCE_MESSAGE, Status.INFO, properties);
    this.appendResult(`Line callback sent. Expect message and demo_line_sensitive_field=${LINE_MASK}; demo_line_visible_field remains visible.`);
  }

  build() {
    Column() {
      TestPageHeader({ title: 'Data Modifier Test' })

      Scroll() {
        Column({ space: 16 }) {
          Text('The EntryAbility installs demo-only callbacks. They affect only fields prefixed with demo_ and are safe for other test pages.')
            .fontSize(14)
            .fontColor('#666666')
            .width('100%')

          Button('Send Field Modifier Log')
            .width('100%')
            .height(48)
            .backgroundColor('#007DFF')
            .onClick(() => this.sendFieldModifierLog())

          Button('Send Line Modifier Log')
            .width('100%')
            .height(48)
            .backgroundColor('#28A745')
            .onClick(() => this.sendLineModifierLog())

          Text('Verify the cached/uploaded Line Protocol in DataKit or the RUM/Log explorer. The original test secrets must not appear.')
            .fontSize(13)
            .fontColor('#666666')
            .width('100%')

          Divider().width('100%')

          Text('Actions')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          ForEach(this.results, (item: string) => {
            Text(item)
              .fontSize(12)
              .fontColor('#333333')
              .width('100%')
              .padding(10)
              .backgroundColor('#F5F5F5')
              .borderRadius(6)
          }, (item: string) => item)
        }
        .width('100%')
        .padding(20)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
