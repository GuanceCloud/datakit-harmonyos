import { Context } from '@kit.AbilityKit';
import { BuilderNode, ComponentContent, FrameNode, NodeController, UIContext } from '@kit.ArkUI';
import { FTSessionReplay } from '@guancecloud/ft_session_replay';

const CATEGORIES: Array<string> = [
  '增量更新与动画', '文字与富文本', '输入与编辑', '按钮与选择', '日期与时间',
  '滑动与列表', '布局与容器', '图片、绘制与媒体', '弹层与导航'
];

interface ReplayPopupState {
  isVisible: boolean;
}

class ReplayNodeParameters {
  label: string;
  id: string;

  constructor(label: string, id: string) {
    this.label = label;
    this.id = id;
  }
}

@Builder
function replayDynamicNode(params: ReplayNodeParameters) {
  Text(params.label).id(params.id).width('100%').height(44).padding(10).backgroundColor('#DBEAFE')
}

class ReplaySampleNodeController extends NodeController {
  private node: BuilderNode<[ReplayNodeParameters]> | null = null;
  private revision: number = 0;

  makeNode(uiContext: UIContext): FrameNode | null {
    this.disposeNode();
    this.node = new BuilderNode<[ReplayNodeParameters]>(uiContext);
    this.node.build(wrapBuilder(replayDynamicNode), new ReplayNodeParameters('NodeContainer 初始文字', 'session-replay-node-text'));
    return this.node.getFrameNode();
  }

  updateText(): void {
    this.revision++;
    this.node?.update(new ReplayNodeParameters(`NodeContainer 更新 ${this.revision}`, 'session-replay-node-text'));
  }

  disposeNode(): void {
    this.node?.dispose();
    this.node = null;
  }
}

@Component
export struct SessionReplayComponentSamples {
  @State category: number = 0;
  @State fixedSizeProbe: string = 'Replay text A';
  @State partialText: string = '局部 A';
  @State orderedProbes: Array<string> = ['Replay node A', 'Replay node B'];
  @State showMutationProbe: boolean = false;
  @State touchResult: string = 'Touch and drag here';
  @State animationX: number = 0;
  @State animationOpacity: number = 1;
  @State styleChanged: boolean = false;
  @State input: string = '';
  @State password: string = '';
  @State passwordVisible: boolean = false;
  @State area: string = '';
  @State search: string = '';
  @State checked: boolean = false;
  @State switched: boolean = false;
  @State buttonToggle: boolean = false;
  @State radio: string = 'A';
  @State selectedOption: number = 0;
  @State slider: number = 35;
  @State rating: number = 3;
  @State count: number = 0;
  @State controlResult: string = '操作控件，观察选中态与文字变化';
  @State pickerResult: string = '滑动选择器或打开日历';
  @State selectedDate: Date = new Date(2026, 9, 10);
  @State selectedTime: Date = new Date(2026, 9, 10, 12, 30);
  @State textPickerIndex: number = 0;
  @State refreshing: boolean = false;
  @State refreshCount: number = 0;
  @State listItems: Array<number> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
  @State scrollResult: string = '上下、左右滑动，观察滚动位置、裁剪和复用节点';
  @State layoutChanged: boolean = false;
  @State sidebarVisible: boolean = true;
  @State imageChanged: boolean = false;
  @State imageAnimation: boolean = false;
  @State canvasChanged: boolean = false;
  @State videoUrl: string = '';
  @State videoSource: string = '';
  @State popupVisible: boolean = false;
  @State sheetVisible: boolean = false;
  @State navigationResult: string = '切换 Tab、Stepper，打开菜单、弹层与子页面';
  @State step: number = 0;
  @State timerRunning: boolean = false;
  @State contentRevision: number = 0;
  @State inlineSampleChanged: boolean = false;
  private readonly outerScroller: Scroller = new Scroller();
  private readonly horizontalScroller: Scroller = new Scroller();
  private readonly swiper: SwiperController = new SwiperController();
  private readonly timer: TextTimerController = new TextTimerController();
  private readonly clock: TextClockController = new TextClockController();
  private readonly editor: RichEditorController = new RichEditorController();
  private readonly pattern: PatternLockController = new PatternLockController();
  private replayPatternPoints: Array<number> = [];
  private readonly canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private readonly paths: NavPathStack = new NavPathStack();
  private readonly nodeController: ReplaySampleNodeController = new ReplaySampleNodeController();
  private slotContent: ComponentContent<ReplayNodeParameters> | null = null;
  private refreshTimer: number = -1;

  aboutToAppear(): void {
    this.slotContent = new ComponentContent(this.getUIContext(), wrapBuilder(replayDynamicNode),
      new ReplayNodeParameters('ContentSlot 初始文字', 'session-replay-slot-text'));
    const context = getContext(this) as Context;
    context.resourceManager.getMediaContent($r('app.media.startIcon'))
      .then((bytes: Uint8Array): void => {
        const replay = FTSessionReplay.getInstance();
        replay.registerImageAsset('session-replay-component-image', bytes, 'image/png');
        replay.registerImageAsset('session-replay-inline-image', bytes, 'image/png');
      })
      .catch((): void => {});
    context.resourceManager.getMediaContent($r('app.media.foreground'))
      .then((bytes: Uint8Array): void => {
        FTSessionReplay.getInstance().registerImageAsset('session-replay-component-image-alternate', bytes, 'image/png');
      })
      .catch((): void => {});
  }

  aboutToDisappear(): void {
    if (this.refreshTimer !== -1) clearTimeout(this.refreshTimer);
    this.timer.pause();
    this.clock.stop();
    this.nodeController.disposeNode();
    this.slotContent?.dispose();
    this.slotContent = null;
  }

  private selectCategory(index: number): void {
    this.timer.pause();
    this.clock.stop();
    this.timerRunning = false;
    this.category = index;
    this.outerScroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  private drawCanvas(): void {
    this.canvas.clearRect(0, 0, 280, 120);
    this.canvas.fillStyle = this.canvasChanged ? '#16A34A' : '#2563EB';
    this.canvas.fillRect(this.canvasChanged ? 100 : 16, 12, 100, 64);
    this.canvas.fillStyle = '#0F172A';
    this.canvas.font = '16px sans-serif';
    this.canvas.fillText(this.canvasChanged ? 'Canvas B' : 'Canvas A', 16, 105);
  }

  @Builder
  private section(title: string, instruction: string) {
    Column({ space: 6 }) {
      Text(title).fontSize(18).fontWeight(FontWeight.Medium)
      Text(instruction).fontSize(13).fontColor('#64748B')
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private mutationSamples() {
    this.section('Text 固定尺寸与 Span 局部更新', '文字更新时保持容器尺寸不变；局部更新仅替换中间文字，检查前后文字和样式。')
    Text(this.fixedSizeProbe)
      .id('session-replay-fixed-text').width('100%').height(32).fontSize(16)
    Button('Change Fixed-size Text')
      .id('session-replay-fixed-text-button').width('100%').height(44)
      .onClick(() => {
        this.fixedSizeProbe = this.fixedSizeProbe === 'Replay text A' ? 'Replay text B' : 'Replay text A';
      })
    Text() {
      Span('固定前缀 · ').fontColor('#64748B')
      Span(this.partialText).fontColor('#2563EB').fontWeight(FontWeight.Bold)
      Span(' · 固定后缀').fontColor('#64748B')
    }
    .id('session-replay-partial-text').width('100%').height(44).fontSize(16)
    Button('仅更新中间 Span')
      .id('session-replay-partial-text-button').width('100%').height(44)
      .onClick(() => { this.partialText = this.partialText === '局部 A' ? '局部 B' : '局部 A'; })
    Divider()
    this.section('ForEach 排序与条件节点', '反转同一组节点、添加和移除节点，检查回放顺序与增量变化。')
    Column() {
      ForEach(this.orderedProbes, (label: string) => {
        Text(label)
          .id(label === 'Replay node A' ? 'session-replay-order-a' : 'session-replay-order-b')
          .width('100%').height(28)
      }, (label: string): string => label)
      if (this.showMutationProbe) {
        Text('Incremental layout probe')
          .id('session-replay-component-mutation').width('100%').padding(12).backgroundColor('#DDF4FF')
      }
    }
    .width('100%')
    Button('Reorder Replay Nodes')
      .id('session-replay-reorder-button').width('100%').height(44)
      .onClick(() => { this.orderedProbes = this.orderedProbes.slice().reverse(); })
    Button('添加 / 移除节点')
      .id('session-replay-mutation-button').width('100%').height(44)
      .onClick(() => { this.showMutationProbe = !this.showMutationProbe; })
    Divider()
    this.section('触摸、Swiper 与属性动画', '在触摸板拖动、滑动轮播或点击动画按钮，检查轨迹、动画中间位置和透明度。')
    Text(this.touchResult)
      .id('session-replay-touch-pad').width('100%').height(120)
      .textAlign(TextAlign.Center).backgroundColor('#DDF4FF')
      .onTouch((event: TouchEvent) => {
        const point = event.changedTouches[0];
        if (point !== undefined) this.touchResult = `Touch ${event.type}: ${Math.round(point.windowX)}, ${Math.round(point.windowY)}`;
      })
    Swiper(this.swiper) {
      Text('Replay slide A').id('session-replay-slide-a')
        .fontSize(24).width('100%').height('100%').backgroundColor('#DDF4FF')
      Text('Replay slide B').id('session-replay-slide-b')
        .fontSize(24).width('100%').height('100%').backgroundColor('#DCFCE7')
      Text('Replay slide C').id('session-replay-slide-c')
        .fontSize(24).width('100%').height('100%').backgroundColor('#FEF3C7')
    }
    .id('session-replay-swiper').width('100%').height(150).loop(false).duration(800)
    .onAnimationStart(() => FTSessionReplay.getInstance().notifyTransition())
    .onAnimationEnd(() => FTSessionReplay.getInstance().notifyPageChanged())
    Button('Animate Next Slide')
      .id('session-replay-swiper-next').width('100%').height(44)
      .onClick(() => this.swiper.showNext())
    Text('Replay moving probe')
      .id('session-replay-moving-probe').width(160).height(40).backgroundColor('#93C5FD')
      .translate({ x: this.animationX }).opacity(this.animationOpacity)
    Button('Animate Translation and Fade')
      .id('session-replay-animation-button').width('100%').height(44)
      .onClick(() => {
        FTSessionReplay.getInstance().notifyTransition();
        this.getUIContext().animateTo({ duration: 800, curve: Curve.Linear,
          onFinish: () => FTSessionReplay.getInstance().notifyPageChanged() }, () => {
          this.animationX = this.animationX === 0 ? 120 : 0;
          this.animationOpacity = this.animationOpacity === 1 ? 0.25 : 1;
        });
      })
    Text('样式变化：字体、背景、边框、圆角')
      .id('session-replay-style-probe').width('100%').padding(12)
      .fontSize(this.styleChanged ? 20 : 14).fontColor(this.styleChanged ? '#FFFFFF' : '#0F172A')
      .backgroundColor(this.styleChanged ? '#0E7490' : '#E2E8F0')
      .border({ width: this.styleChanged ? 3 : 1, color: '#2563EB' })
      .borderRadius(this.styleChanged ? 20 : 4)
    Button('切换文字和容器样式').width('100%').height(44)
      .onClick(() => { this.styleChanged = !this.styleChanged; })
  }

  @Builder
  private textSamples() {
    this.section('Text / Span / ImageSpan / SymbolSpan', '长文本换行、省略、文字选择、行内图片和符号，检查位置与样式。')
    Text('这是一段用于验证换行和裁剪的长文本。请对照回放中的换行、行高、字号与实际页面。'.repeat(3))
      .id('session-replay-long-text').width('100%').fontSize(16).lineHeight(26)
      .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
    Text('长按这段可选择的文本，检查文本选择效果。')
      .id('session-replay-selectable-text').copyOption(CopyOptions.InApp).fontSize(16)
    Text() {
      Span('行内图片 ')
      ImageSpan($r('app.media.startIcon')).id('session-replay-inline-image').width(24).height(24)
      Span(' 与符号 ')
      SymbolSpan($r('sys.symbol.ohos_wifi')).fontSize(24)
    }
    .id('session-replay-image-span').fontSize(18).height(48)
    Text() {
      Span(this.inlineSampleChanged ? '更新图片旁文字 ' : '独立文字与图片 ')
      ImageSpan($r('app.media.startIcon')).id('session-replay-inline-image-model').width(24).height(24)
      Span(' 图片资源保持不变').fontColor('#2563EB')
    }
    .id('session-replay-inline-model').width('100%').fontSize(18).height(64)
    Button('更新行内图片旁文字').id('session-replay-inline-model-update').width('100%')
      .onClick(() => { this.inlineSampleChanged = !this.inlineSampleChanged; })
    Text() {
      Span('行内符号 ')
      SymbolSpan($r('sys.symbol.ohos_wifi')).fontSize(24).fontColor(['#16A34A'])
    }
    .id('session-replay-symbol-span-only').fontSize(18).height(48)
    SymbolGlyph($r('sys.symbol.ohos_wifi')).id('session-replay-symbol-glyph').fontSize(40).fontColor(['#2563EB'])
    this.section('Marquee / Hyperlink / RichText', '跑马灯移动、超链接和 HTML 富文本。')
    Marquee({ start: true, step: 3, loop: -1, fromStart: true, src: 'Session Replay · 跑马灯文字采集测试 · 长文本持续移动' })
      .id('session-replay-marquee').width('100%').height(40).fontSize(18)
    Hyperlink('https://www.guance.com', '观测云链接').color('#2563EB')
    RichText('<div style="color:#2563eb;font-size:18px"><b>HTML 富文本</b><p>段落与颜色采集测试</p></div>')
      .id('session-replay-rich-text').width('100%').height(110)
    this.section('TextClock / TextTimer', '启动时钟、计时器，观察局部文字持续更新；离开分类时停止。')
    TextClock({ controller: this.clock }).format('HH:mm:ss').fontSize(28)
      .id('session-replay-clock')
    Button('启动时钟').onClick(() => this.clock.start())
    TextTimer({ isCountDown: false, controller: this.timer }).format('HH:mm:ss.SS').fontSize(28)
      .id('session-replay-timer')
    Row({ space: 12 }) {
      Button(this.timerRunning ? '暂停计时' : '开始计时').onClick(() => {
        if (this.timerRunning) this.timer.pause(); else this.timer.start();
        this.timerRunning = !this.timerRunning;
      })
      Button('重置').onClick(() => { this.timer.reset(); this.timerRunning = false; })
    }
  }

  @Builder
  private inputSamples() {
    this.section('TextInput / TextArea / Search', '输入、删除、替换内容，切换焦点并弹出键盘；使用演示文本验证普通输入与密码遮罩。')
    TextInput({ text: this.input, placeholder: '普通输入：输入演示文字' })
      .id('session-replay-input').type(InputType.Normal).width('100%')
      .onChange((value: string) => { this.input = value; })
    TextInput({ text: this.password, placeholder: '密码输入：仅使用演示密码' })
      .id('session-replay-password').type(InputType.Password).width('100%')
      .showPassword(this.passwordVisible)
      .onSecurityStateChange((visible: boolean) => { this.passwordVisible = visible; })
      .onChange((value: string) => { this.password = value; })
    TextArea({ text: this.area, placeholder: '多行输入：验证换行、编辑和内部滚动' })
      .id('session-replay-text-area').type(TextAreaType.NORMAL).width('100%').height(120)
      .onChange((value: string) => { this.area = value; })
    Search({ value: this.search, placeholder: '搜索内容' })
      .id('session-replay-search').width('100%').searchButton('搜索')
      .onChange((value: string) => { this.search = value; })
      .onSubmit(() => { this.controlResult = '已提交搜索'; })
    Row({ space: 8 }) {
      Button('填充演示文字').onClick(() => {
        this.input = 'Replay input B';
        this.area = '第一行演示文字\n第二行局部更新\n第三行滚动测试';
        this.search = 'Replay search';
      })
      Button('清空').onClick(() => { this.input = ''; this.password = ''; this.area = ''; this.search = ''; })
    }
    this.section('RichEditor', '编辑文字、插入富文本，观察 Span 与光标附近的局部更新。')
    RichEditor({ controller: this.editor })
      .id('session-replay-rich-editor').width('100%').height(160).backgroundColor(Color.White)
      .onReady(() => { this.editor.addTextSpan('RichEditor 演示文字'); })
    Button('追加富文本').width('100%').height(44)
      .onClick(() => {
        this.editor.addTextSpan(' · 新增内容', { style: { fontColor: '#2563EB', fontSize: 20 } });
      })
  }

  @Builder
  private controlSamples() {
    this.section('Button / Toggle / Checkbox / CheckboxGroup / Radio', '点击、切换、全选，检查选中态与禁用态。')
    Row({ space: 8 }) {
      Button('普通按钮', { type: ButtonType.Normal }).id('session-replay-button-normal').onClick(() => { this.count++; })
      Button('+', { type: ButtonType.Circle }).id('session-replay-button-circle').width(40).height(40).onClick(() => { this.count++; })
      Button('禁用').id('session-replay-button-disabled').enabled(false)
    }
    Row({ space: 12 }) {
      Toggle({ type: ToggleType.Switch, isOn: this.switched })
        .id('session-replay-toggle-switch').onChange((value: boolean) => { this.switched = value; })
      Toggle({ type: ToggleType.Checkbox, isOn: this.checked })
        .id('session-replay-toggle-checkbox').onChange((value: boolean) => { this.checked = value; })
      Toggle({ type: ToggleType.Button, isOn: this.buttonToggle }) { Text('状态按钮') }
        .id('session-replay-toggle-button')
        .onChange((value: boolean) => { this.buttonToggle = value; })
    }
    Row({ space: 12 }) {
      CheckboxGroup({ group: 'replay-options' }).id('session-replay-checkbox-group')
        .onChange((value: CheckboxGroupResult) => { this.controlResult = `勾选数量：${value.name.length}`; })
      Text('全选')
      Checkbox({ name: 'A', group: 'replay-options' }).id('session-replay-checkbox-a')
      Text('A')
      Checkbox({ name: 'B', group: 'replay-options' }).id('session-replay-checkbox-b')
      Text('B')
    }
    Row({ space: 12 }) {
      Radio({ value: 'A', group: 'replay-radio' }).checked(this.radio === 'A')
        .id('session-replay-radio-a')
        .onChange((value: boolean) => { if (value) this.radio = 'A'; })
      Text('选项 A')
      Radio({ value: 'B', group: 'replay-radio' }).checked(this.radio === 'B')
        .id('session-replay-radio-b')
        .onChange((value: boolean) => { if (value) this.radio = 'B'; })
      Text('选项 B')
    }
    Select([{ value: '选项一' }, { value: '选项二' }, { value: '选项三' }])
      .id('session-replay-select').selected(this.selectedOption).value(`选项 ${this.selectedOption + 1}`)
      .onSelect((index: number) => { this.selectedOption = index; })
    Text(`点击 ${this.count} 次 · 开关 ${this.switched ? '开' : '关'} · 单选 ${this.radio}`).fontSize(14)
    Text(this.controlResult).fontSize(14)
    this.section('Slider / Rating / Counter / Progress', '拖动滑块、修改评分和计数，进度、仪表和数据面板联动变化。')
    Slider({ value: this.slider, min: 0, max: 100, step: 1 }).width('100%').showTips(true)
      .id('session-replay-slider').onChange((value: number) => { this.slider = value; })
    Rating({ rating: this.rating, indicator: false }).stars(5).stepSize(0.5)
      .id('session-replay-rating').onChange((value: number) => { this.rating = value; })
    Counter() { Text(`${this.count}`) }
      .id('session-replay-counter')
      .width(180).height(40).onInc(() => { this.count++; }).onDec(() => { this.count--; })
    Progress({ value: this.slider, total: 100, type: ProgressType.Linear }).width('100%')
      .id('session-replay-progress-linear')
    Row({ space: 16 }) {
      Progress({ value: this.slider, total: 100, type: ProgressType.Ring }).width(64).height(64)
        .id('session-replay-progress-ring')
      LoadingProgress().id('session-replay-loading-progress').width(40).height(40)
      Gauge({ value: this.slider, min: 0, max: 100 }).width(120).height(120)
        .id('session-replay-gauge')
    }
    DataPanel({ values: [this.slider, 100 - this.slider], max: 100, type: DataPanelType.Line })
      .id('session-replay-data-panel')
      .width('100%').height(32)
    this.section('PatternLock', '连接图案节点，再重置；观察手势路径和节点状态。')
    PatternLock(this.pattern).id('session-replay-pattern-lock').width(240).height(240)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) this.replayPatternPoints = [];
        FTSessionReplay.getInstance().recordPatternTouch('session-replay-pattern-lock', event);
      })
      .onDotConnect((index: number) => {
        if (!this.replayPatternPoints.includes(index)) this.replayPatternPoints.push(index);
        FTSessionReplay.getInstance().updatePatternLockState('session-replay-pattern-lock', this.replayPatternPoints, false);
      })
      .onPatternComplete((value: Array<number>) => {
        FTSessionReplay.getInstance().updatePatternLockState('session-replay-pattern-lock', value);
        this.controlResult = `图案连接 ${value.length} 个节点`;
      })
    Button('重置图案').id('session-replay-pattern-reset').onClick(() => {
        this.pattern.reset();
        this.replayPatternPoints = [];
        FTSessionReplay.getInstance().updatePatternLockState('session-replay-pattern-lock', []);
      })
  }

  @Builder
  private pickerSamples() {
    this.section('DatePicker / TimePicker / TextPicker / CalendarPicker', '滚动年月日、时分和文本选项，检查选中值、滚动裁剪与日历弹窗。')
    DatePicker({ start: new Date(2020, 0, 1), end: new Date(2030, 11, 31), selected: this.selectedDate })
      .id('session-replay-date-picker').width('100%').height(180)
      .onDateChange((value: Date) => { this.selectedDate = value; this.pickerResult = value.toLocaleDateString(); })
    TimePicker({ selected: this.selectedTime }).useMilitaryTime(true).width('100%').height(150)
      .id('session-replay-time-picker')
      .onChange((value: TimePickerResult) => { this.pickerResult = `时间：${value.hour}:${value.minute}`; })
    TextPicker({ range: ['文本选项 A', '文本选项 B', '文本选项 C'], selected: this.textPickerIndex })
      .id('session-replay-text-picker').width('100%').height(150)
      .onChange((value: string | Array<string>, index: number | Array<number>) => {
        if (typeof index === 'number') this.textPickerIndex = index;
        this.pickerResult = `文本：${value}`;
      })
    CalendarPicker({ selected: this.selectedDate }).id('session-replay-calendar-picker')
      .onChange((value: Date) => { this.selectedDate = value; this.pickerResult = value.toLocaleDateString(); })
    Text(this.pickerResult).fontSize(14)
  }

  @Builder
  private scrollingSamples() {
    this.section('Scroll / ScrollBar', '横向滑动和拖动滚动条，检查超出区域的裁剪。')
    Scroll(this.horizontalScroller) {
      Row({ space: 8 }) {
        ForEach(this.listItems, (item: number) => {
          Text(`横向 ${item}`).width(96).height(72).textAlign(TextAlign.Center)
            .backgroundColor(item % 2 === 0 ? '#DCFCE7' : '#DBEAFE')
        }, (item: number): string => `horizontal-${item}`)
      }
    }
    .id('session-replay-horizontal-scroll').width('100%').height(90).scrollable(ScrollDirection.Horizontal)
    .onScroll(() => FTSessionReplay.getInstance().notifyScroll())
    ScrollBar({ scroller: this.horizontalScroller, direction: ScrollBarDirection.Horizontal, state: BarState.On })
      .width('100%').height(12)
    this.section('Refresh / List / ListItem / ListItemGroup', '上下滑动列表、下拉刷新、追加数据，检查节点变化和嵌套滚动。')
    Refresh({ refreshing: $$this.refreshing }) {
      List({ space: 8 }) {
        ListItemGroup({ header: this.listHeader }) {
          ForEach(this.listItems, (item: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(`${item}`).width(32).height(32).textAlign(TextAlign.Center).backgroundColor('#DBEAFE')
                Text(`列表条目 ${item}`).layoutWeight(1)
                Button('点选').height(32).onClick(() => { this.scrollResult = `已点击条目 ${item}`; })
              }
              .width('100%').padding(10).backgroundColor(Color.White)
            }
            .id(`session-replay-list-item-${item}`)
          }, (item: number): string => `list-${item}`)
        }
      }
      .id('session-replay-list').width('100%').height(280).scrollBar(BarState.On)
      .onScroll(() => FTSessionReplay.getInstance().notifyScroll())
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    }
    .width('100%')
    .onRefreshing(() => {
      this.refreshTimer = setTimeout(() => {
        this.refreshCount++;
        this.refreshing = false;
        this.refreshTimer = -1;
      }, 800);
    })
    Button('追加列表条目').width('100%').height(44)
      .onClick(() => { this.listItems = [...this.listItems, this.listItems.length + 1]; })
    this.section('Grid / GridItem / WaterFlow / FlowItem', '滑动网格与瀑布流，检查不同高度的卡片、裁剪和复用。')
    Grid() {
      ForEach(this.listItems, (item: number) => {
        GridItem() { Text(`网格 ${item}`).width('100%').height(72).textAlign(TextAlign.Center).backgroundColor('#DBEAFE') }
          .id(`session-replay-grid-item-${item}`)
      }, (item: number): string => `grid-${item}`)
    }
    .id('session-replay-grid').columnsTemplate('1fr 1fr 1fr').columnsGap(8).rowsGap(8)
    .width('100%').height(200)
    .onScroll(() => FTSessionReplay.getInstance().notifyScroll())
    .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    WaterFlow() {
      ForEach(this.listItems, (item: number) => {
        FlowItem() {
          Text(`瀑布流 ${item}`).width('100%').height(70 + item % 3 * 30)
            .textAlign(TextAlign.Center).backgroundColor(item % 2 === 0 ? '#FEF3C7' : '#DCFCE7')
        }
        .id(`session-replay-flow-item-${item}`)
      }, (item: number): string => `flow-${item}`)
    }
    .id('session-replay-water-flow').columnsTemplate('1fr 1fr').columnsGap(8).rowsGap(8)
    .width('100%').height(240)
    .onScroll(() => FTSessionReplay.getInstance().notifyScroll())
    .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    Row({ space: 16 }) {
      Text(this.scrollResult).layoutWeight(1).fontSize(14)
      AlphabetIndexer({ arrayValue: ['A', 'B', 'C', 'D', 'E'], selected: 0 }).itemSize(24)
        .onSelected((index: number) => { this.scrollResult = `索引 ${index + 1}`; })
    }
  }

  @Builder
  private listHeader() {
    Text(`列表分组 · 已刷新 ${this.refreshCount} 次`).width('100%').padding(10).backgroundColor('#E0F2FE')
  }

  @Builder
  private layoutSamples() {
    this.section('Row / Column / Flex / Stack / Blank / Divider', '改变尺寸、对齐、边距和覆盖层，检查位置、背景与层级。')
    Button('切换布局尺寸与层级').width('100%').height(44)
      .onClick(() => { this.layoutChanged = !this.layoutChanged; })
    Row({ space: 8 }) {
      Text('Row 左').padding(10).backgroundColor('#DBEAFE')
      Blank()
      Column({ space: 4 }) { Text('Column 上'); Divider(); Text('Column 下') }
        .padding(10).backgroundColor('#DCFCE7')
    }
    .width('100%').height(this.layoutChanged ? 120 : 80).backgroundColor('#F1F5F9')
    Flex({ wrap: FlexWrap.Wrap, justifyContent: this.layoutChanged ? FlexAlign.SpaceBetween : FlexAlign.Start }) {
      ForEach([1, 2, 3, 4, 5], (item: number) => {
        Text(`Flex ${item}`).width(this.layoutChanged ? 110 : 80).padding(12).margin(4).backgroundColor('#FEF3C7')
      }, (item: number): string => `flex-${item}`)
    }
    .width('100%')
    Stack({ alignContent: Alignment.Center }) {
      Text('底层').width('100%').height(100).backgroundColor('#DBEAFE')
      Text('覆盖层').width(100).height(50).backgroundColor('#FBBF24')
        .translate({ x: this.layoutChanged ? 60 : 0 }).zIndex(this.layoutChanged ? 2 : 1)
    }
    .width('100%').height(100).clip(true)
    this.section('RelativeContainer / GridRow / GridCol', '相对定位与栅格布局，检查对齐锚点和多列尺寸。')
    RelativeContainer() {
      Text('左上锚点').id('replay-relative-anchor').width(110).height(36).backgroundColor('#DBEAFE')
        .alignRules({ left: { anchor: '__container__', align: HorizontalAlign.Start },
          top: { anchor: '__container__', align: VerticalAlign.Top } })
      Text('跟随锚点').width(110).height(36).backgroundColor('#DCFCE7')
        .alignRules({ left: { anchor: 'replay-relative-anchor', align: HorizontalAlign.End },
          top: { anchor: 'replay-relative-anchor', align: VerticalAlign.Bottom } })
    }
    .width('100%').height(90)
    GridRow({ columns: 4, gutter: 8 }) {
      GridCol({ span: this.layoutChanged ? 3 : 2 }) { Text('GridCol A').width('100%').padding(12).backgroundColor('#DBEAFE') }
      GridCol({ span: this.layoutChanged ? 1 : 2 }) { Text('B').width('100%').padding(12).backgroundColor('#DCFCE7') }
    }
    .width('100%')
    this.section('RowSplit / ColumnSplit / SideBarContainer / FolderStack', '拖动分隔条，收起侧边栏；折叠布局在对应设备上对照测试。')
    RowSplit() {
      Text('左右分割 A').width('50%').height(72).backgroundColor('#DBEAFE')
      Text('B').width('50%').height(72).backgroundColor('#DCFCE7')
    }
    .resizeable(true).width('100%').height(72)
    ColumnSplit() {
      Text('上下分割 A').width('100%').height(52).backgroundColor('#DBEAFE')
      Text('B').width('100%').height(52).backgroundColor('#DCFCE7')
    }
    .resizeable(true).width('100%').height(120)
    SideBarContainer(SideBarContainerType.Embed) {
      Column() { Text('侧栏内容').padding(12) }.width('100%').height('100%').backgroundColor('#DBEAFE')
      Column() { Text('主内容').padding(12) }.width('100%').height('100%').backgroundColor('#DCFCE7')
    }
    .width('100%').height(160).sideBarWidth(100).minSideBarWidth(80).maxSideBarWidth(140)
    .showSideBar(this.sidebarVisible).onChange((value: boolean) => { this.sidebarVisible = value; })
    Button('显示 / 隐藏侧栏').onClick(() => { this.sidebarVisible = !this.sidebarVisible; })
    FolderStack() {
      Text('FolderStack 内容').id('session-replay-folder-text').width('100%').height(64).backgroundColor('#E0F2FE')
    }
    .id('session-replay-folder-stack').width('100%').height(80)
    Badge({ count: this.layoutChanged ? 12 : 3, position: BadgePosition.RightTop, style: { color: Color.White, badgeColor: '#2563EB' } }) {
      Text('Badge 角标').padding(14).backgroundColor('#DBEAFE')
    }
    this.section('NodeContainer / ContentSlot / WithTheme', '更新动态创建的节点和插槽内容，检查采集树中的文字与节点生命周期。')
    NodeContainer(this.nodeController).id('session-replay-node-container').width('100%').height(44)
    Button('更新 NodeContainer').id('session-replay-node-update').onClick(() => this.nodeController.updateText())
    if (this.slotContent !== null) {
      ContentSlot(this.slotContent)
    }
    Button('更新 ContentSlot').onClick(() => {
      this.contentRevision++;
      this.slotContent?.update(new ReplayNodeParameters(`ContentSlot 更新 ${this.contentRevision}`, 'session-replay-slot-text'));
    })
    WithTheme({ colorMode: this.layoutChanged ? ThemeColorMode.DARK : ThemeColorMode.LIGHT }) {
      Button('WithTheme 主题按钮').width('100%').height(44)
    }
  }

  @Builder
  private mediaSamples() {
    this.section('Image / ImageAnimator / QRCode', '切换图片、适配方式和帧动画，对照资源、边界与显示状态。')
    Row({ space: 16 }) {
      if (this.imageChanged) {
        Image($r('app.media.foreground')).id('session-replay-component-image-alternate')
          .width(96).height(96).objectFit(ImageFit.Cover).borderRadius(16)
      } else {
        Image($r('app.media.startIcon')).id('session-replay-component-image')
          .width(96).height(96).objectFit(ImageFit.Contain).borderRadius(4)
      }
      QRCode(this.imageChanged ? 'replay-image-B' : 'replay-image-A').width(96).height(96)
    }
    Button('切换图片与二维码').onClick(() => { this.imageChanged = !this.imageChanged; })
    ImageAnimator().images([
      { src: $r('app.media.startIcon'), width: 80, height: 80 },
      { src: $r('app.media.foreground'), width: 80, height: 80 }
    ]).width(80).height(80).duration(1200).iterations(-1)
      .state(this.imageAnimation ? AnimationStatus.Running : AnimationStatus.Paused)
    Button('开始 / 暂停图片动画').onClick(() => { this.imageAnimation = !this.imageAnimation; })
    this.section('Shape / Rect / Circle / Ellipse / Line / Polygon / Polyline / Path', '检查图形颜色、边界和路径在回放中的表现。')
    Shape() {
      Rect().width(60).height(40).fill('#2563EB').radius(8)
      Circle({ width: 40, height: 40 }).translate({ x: 80 })
      Ellipse().width(70).height(40).fill('#F59E0B').translate({ x: 150 })
      Polygon().points([[0, 110], [30, 75], [60, 110]]).fill('#7C3AED')
      Polyline().points([[80, 110], [110, 75], [140, 110]]).stroke('#2563EB').strokeWidth(3).fill(Color.Transparent)
      Path().commands('M 160 110 L 190 75 L 220 110 Z').fill('#EC4899')
    }
    .width('100%').height(130).fill('#16A34A')
    Line().width('100%').height(8).startPoint([0, 4]).endPoint([220, 4]).stroke('#0F172A').strokeWidth(2)
    this.section('Canvas / Video / XComponent', '操作绘制和独立渲染区域，核对内容或占位边界；这些区域需单独确认回放支持情况。')
    Canvas(this.canvas).id('session-replay-canvas').width(280).height(120).backgroundColor(Color.White)
      .onReady(() => this.drawCanvas())
    Button('更新 Canvas 绘制').onClick(() => { this.canvasChanged = !this.canvasChanged; this.drawCanvas(); })
    TextInput({ text: this.videoUrl, placeholder: '输入可访问的 MP4 地址后加载 Video' })
      .width('100%').onChange((value: string) => { this.videoUrl = value; })
    Button('加载视频').enabled(this.videoUrl.trim().length > 0)
      .onClick(() => { this.videoSource = this.videoUrl.trim(); })
    Video({ src: this.videoSource, previewUri: $r('app.media.startIcon') })
      .id('session-replay-video').width('100%').height(180).controls(true).autoPlay(false)
    XComponent({ id: 'session-replay-xcomponent', type: XComponentType.SURFACE })
      .id('session-replay-xcomponent').width('100%').height(90).backgroundColor('#CBD5E1')
    Text('XComponent 为 Surface 边界样例；自绘内容需结合实际 Native 渲染模块测试。')
      .fontSize(12).fontColor('#64748B')
  }

  @Builder
  private menuContent() {
    Menu() {
      MenuItemGroup({ header: '采集测试菜单' }) {
        MenuItem({ content: '菜单选项 A' }).onClick(() => { this.navigationResult = '已选菜单 A'; })
        MenuItem({ content: '菜单选项 B' }).onClick(() => { this.navigationResult = '已选菜单 B'; })
      }
    }
  }

  @Builder
  private sheetContent() {
    Column({ space: 16 }) {
      Text('Sheet 采集测试').id('session-replay-sheet-title').fontSize(22)
      TextInput({ placeholder: '弹层内输入演示文本' }).width('90%')
      Button('关闭 Sheet').id('session-replay-sheet-close').onClick(() => { this.sheetVisible = false; })
    }
    .id('session-replay-sheet-content').width('100%').padding(24)
  }

  @Builder
  private destination(name: string) {
    NavDestination() {
      Column({ space: 12 }) {
        Text(`NavDestination：${name}`).fontSize(20)
        Text('测试同页 Navigation 子页面的进入、返回和 View 关联。').fontSize(14)
        Button('返回 Navigation').onClick(() => { this.paths.pop(); })
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('#DCFCE7')
    }
    .title('采集子页面')
  }

  @Builder
  private overlaySamples() {
    this.section('Tabs / TabContent / Stepper / StepperItem', '切换标签页和步骤，检查子树替换、动画和当前内容。')
    Tabs() {
      TabContent() { Text('Tab A 内容').width('100%').height('100%').backgroundColor('#DBEAFE') }.tabBar('Tab A')
      TabContent() { Text('Tab B 内容').width('100%').height('100%').backgroundColor('#DCFCE7') }.tabBar('Tab B')
    }
    .id('session-replay-tabs').width('100%').height(160)
      .onChange((index: number) => { this.navigationResult = `Tab ${index + 1}`; })
    Stepper({ index: this.step }) {
      StepperItem() { Text('步骤一：选择').fontSize(18) }.nextLabel('下一步')
      StepperItem() { Text('步骤二：确认').fontSize(18) }.prevLabel('上一步').nextLabel('完成')
    }
    .width('100%').height(160).onChange((index: number) => { this.step = index; })
    this.section('Menu / MenuItem / MenuItemGroup / Popup / Sheet / AlertDialog / ActionSheet', '展开、选择和关闭浮层，检查浮层是否进入回放、遮挡和返回后的页面状态。')
    Button('展开 Menu').width('100%').height(44).bindMenu(this.menuContent)
    Button('显示 / 隐藏 Popup').width('100%').height(44)
      .id('session-replay-popup-open')
      .onClick(() => { this.popupVisible = !this.popupVisible; })
      .bindPopup(this.popupVisible, { message: 'Popup 演示文字',
        onStateChange: (event: ReplayPopupState) => { this.popupVisible = event.isVisible; } })
    Button('打开 Sheet').width('100%').height(44)
      .id('session-replay-sheet-open')
      .onClick(() => { this.sheetVisible = true; })
      .bindSheet($$this.sheetVisible, this.sheetContent(), { height: SheetSize.MEDIUM })
    Button('打开 AlertDialog').width('100%').height(44)
      .id('session-replay-alert-open')
      .onClick(() => {
        AlertDialog.show({ title: 'Replay 对话框', message: '观察对话框文字与背景遮挡',
          confirm: { value: '确认', action: () => { this.navigationResult = '对话框已确认'; } } });
      })
    Button('打开 ActionSheet').width('100%').height(44)
      .id('session-replay-action-sheet-open')
      .onClick(() => {
        ActionSheet.show({ title: 'Replay 操作列表', message: '选择一项验证弹层关闭与文字更新', sheets: [
          { title: '选项 A', action: () => { this.navigationResult = 'ActionSheet A'; } },
          { title: '选项 B', action: () => { this.navigationResult = 'ActionSheet B'; } }
        ] });
      })
    this.section('Navigation / NavDestination', '进入同页子页面，再返回；整页 Router 动画通过顶部返回功能测试验证。')
    Navigation(this.paths) {
      Column({ space: 12 }) {
        Text('Navigation 首页')
        Button('进入采集子页面').id('session-replay-nav-push')
          .onClick(() => { this.paths.pushPath({ name: 'Replay detail' }); })
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
    }
    .id('session-replay-navigation').width('100%').height(260)
    .mode(NavigationMode.Stack).title('嵌套导航').navDestination(this.destination)
    Text(this.navigationResult).fontSize(14)
  }

  build() {
    Column({ space: 8 }) {
      Select(CATEGORIES.map((title: string): SelectOption => { return { value: title }; }))
        .id('session-replay-category-select').selected(this.category).value(CATEGORIES[this.category])
        .width('90%').onSelect((index: number) => this.selectCategory(index))
      Scroll(this.outerScroller) {
        Column({ space: 16 }) {
          if (this.category === 0) {
            this.mutationSamples()
          } else if (this.category === 1) {
            this.textSamples()
          } else if (this.category === 2) {
            this.inputSamples()
          } else if (this.category === 3) {
            this.controlSamples()
          } else if (this.category === 4) {
            this.pickerSamples()
          } else if (this.category === 5) {
            this.scrollingSamples()
          } else if (this.category === 6) {
            this.layoutSamples()
          } else if (this.category === 7) {
            this.mediaSamples()
          } else {
            this.overlaySamples()
          }
          Divider()
          Text('按当前工程 API 12+ 组件分类验证。系统卡片、扩展能力及 3D 等依赖外部资源的组件，需要在相应宿主和资源配置下另行测试。')
            .fontSize(12).fontColor('#64748B')
        }
        .width('100%').padding(20).alignItems(HorizontalAlign.Start)
      }
      .id('session-replay-components-scroll').width('100%').layoutWeight(1)
      .onScroll(() => FTSessionReplay.getInstance().notifyScroll())
    }
    .width('100%').height('100%')
  }
}
