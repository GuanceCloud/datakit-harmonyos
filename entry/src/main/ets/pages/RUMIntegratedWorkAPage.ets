import { RUMIntegratedWorkContent } from '../components/RUMIntegratedWorkContent';

@Entry
@Component
struct RUMIntegratedWorkAPage {
  build() { Column() { RUMIntegratedWorkContent({ variant: 'A' }) }.width('100%').height('100%') }
}
