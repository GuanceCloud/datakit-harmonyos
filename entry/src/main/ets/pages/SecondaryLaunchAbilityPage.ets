@Entry
@Component
struct SecondaryLaunchAbilityPage {
  build() {
    Column({ space: 16 }) {
      Text('UIAbility B')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
      Text('Multi-UIAbility cold-launch verification target')
        .fontSize(16)
        .fontColor(Color.Gray)
      Text('Use coldLaunchNextUIAbility to start A and B in both orders.')
        .fontSize(14)
        .textAlign(TextAlign.Center)
        .margin({ left: 24, right: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
