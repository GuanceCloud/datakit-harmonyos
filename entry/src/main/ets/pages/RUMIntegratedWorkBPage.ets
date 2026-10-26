import { RUMIntegratedWorkContent } from '../components/RUMIntegratedWorkContent';

@Entry
@Component
struct RUMIntegratedWorkBPage {
  build() { Column() { RUMIntegratedWorkContent({ variant: 'B' }) }.width('100%').height('100%') }
}
