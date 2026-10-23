import { hilog as __ftHiLogTag } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';
import { FTSDK, FTWebViewHandler } from '@guancecloud/ft_sdk';
import { FTSessionReplay } from '@guancecloud/ft_session_replay';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';

// These names intentionally overlap with names allocated by the plugin.
const __ftConsoleLogBridge: string = 'user-console-bridge';
const __ftConsoleCall: string = 'user-console-call';
const __ftConsoleArgs: string[] = ['user-a', 'user-b'];
const __ftHiLogDomain: number = 0xD003;
const __ftHiLogArgs: string[] = ['hilog-a', 'hilog-b'];
const HILOG_TAG: string = 'HvigorSyntax';

class SyntaxLocalLogger {
  calls: number = 0;

  info(message: string): string {
    this.calls++;
    return message;
  }
}

// @Entry in a comment must not turn this single-line component into a page.
@Component
struct SyntaxInlineSample { build() { Row() { Text('单行 struct：成员边界验证').fontSize(13) } } }

@Entry
@Component
struct HvigorSyntaxVerificationPage { private __ftSessionReplayRootToken: string = 'user-replay-token';
  @State private queryToken: string = `HVIGOR_SYNTAX_${Date.now()}`;
  @State private result: string = '点击“运行全部日志案例”，再按本轮标识查询采集日志。';
  @State private rootVersion: number = 1;
  @State private showWeb: boolean = false;
  @State private replayEnabled: boolean = false;
  @State private uploading: boolean = false;
  private __ftWebReplayBridge: string = 'user-web-bridge';
  private controller: webview.WebviewController = new webview.WebviewController();
  private webHandler: FTWebViewHandler = new FTWebViewHandler();
  private evaluations: string[] = [];
  private rootEvaluations: number = 0;
  private touchCalls: number = 0;
  private copyMode: CopyOptions = CopyOptions.LocalDevice;
  private pageBackground: string = TestPageTheme.PAGE_BACKGROUND;
  private transitionCurve: Curve = Curve.Linear;
  private transitionSlide: SlideEffect = SlideEffect.Right;

  onPageShow(): void /* a comment with ) must remain intact */ {
    this.replayEnabled = FTSessionReplay.getInstance().isEnabled();
    console.info(`${this.queryToken} PAGE_SHOW rootEvaluations=${this.rootEvaluations}`);
  }

  onPageHide(): void {
    console.info(`${this.queryToken} PAGE_HIDE rootEvaluations=${this.rootEvaluations}`);
  }

  aboutToDisappear(): void {
    this.webHandler.clearWebController();
  }

  private toggleWeb(): void {
    if (this.showWeb) {
      this.webHandler.clearWebController();
    }
    this.showWeb = !this.showWeb;
  }

  private append(message: string): void {
    this.result += `\n${message}`;
  }

  private record(label: string): string {
    this.evaluations.push(label);
    return label;
  }

  private recordSpread(label: string): string[] {
    this.evaluations.push(label);
    return [`${label}-1`, `${label}-2`];
  }

  private runAll(): void {
    this.queryToken = `HVIGOR_SYNTAX_${Date.now()}`;
    this.result = `本轮：${this.queryToken}`;
    this.runAsi();
    this.runSpread();
    this.runEvaluation();
    this.runControlFlow();
    this.runScope();
    this.runOptional();
    this.runNamesAndText();
    FTSDK.flushSyncData();
    this.append('已请求上传日志；请在系统日志和观测云中核对参数、顺序与条数。');
  }

  private runAsi(): void {
    // Intentionally omit semicolons before calls that become IIFEs.
    const values: string[] = ['array-a', 'array-b']
    console.info(`${this.queryToken} ASI_ARRAY`, ...values)
    const text: string = `template-${values.length}`
    console.info(`${this.queryToken} ASI_TEMPLATE`, text)
    this.append('ASI：应有 ASI_ARRAY array-a array-b、ASI_TEMPLATE template-2。');
  }

  private runSpread(): void {
    const empty: string[] = [];
    const middle: string[] = ['a', 'b'];
    const nullable: string | null | undefined = null;
    const values: (string | null | undefined)[] = ['value', nullable, undefined];
    console.info(`${this.queryToken} SPREAD`, 'start', ...middle, 'end', ...empty);
    console.info(`${this.queryToken} NULLABLE`, nullable, undefined, ...values);
    __ftHiLogTag.info(__ftHiLogDomain, HILOG_TAG, '%{public}s %{public}s %{public}s',
      `${this.queryToken} HILOG_SPREAD`, ...__ftHiLogArgs, ...empty);
    __ftHiLogTag.info(__ftHiLogDomain, HILOG_TAG, '%{public}s %{public}s %{public}s %{public}s',
      `${this.queryToken} HILOG_NULLABLE`, ...values);
    this.append('展开：SPREAD=start a b end；NULLABLE=null undefined value null undefined。');
    this.append('HiLog：HILOG_SPREAD=hilog-a hilog-b；HILOG_NULLABLE=value null undefined。');
  }

  private runEvaluation(): void {
    this.evaluations = [];
    console.info(`${this.queryToken} EVALUATION`, this.record('A'), ...this.recordSpread('B'), this.record('C'));
    const order = this.evaluations.join(',');
    this.append(`${order === 'A,B,C' ? '通过' : '失败'}：参数求值顺序=${order}，预期 A,B,C，各一次。`);
    console.info(`${this.queryToken} NESTED_OUTER`, (() => {
      console.info(`${this.queryToken} NESTED_INNER`);
      return 'nested-return';
    })());
    this.append('嵌套：NESTED_INNER 先于 NESTED_OUTER，后者带 nested-return。');
  }

  private runControlFlow(): void {
    const enabled: boolean = true;
    if (enabled)
      console.info(`${this.queryToken} IF_TRUE`);
    else
      console.info(`${this.queryToken} IF_FALSE_UNEXPECTED`);
    for (let index: number = 0; index < 2; index++)
      console.info(`${this.queryToken} LOOP`, index);
    this.append('控制流：IF_TRUE 一条、LOOP 两条（0/1）；不应有 IF_FALSE_UNEXPECTED。');
  }

  private localConsole(console: SyntaxLocalLogger): string {
    return console.info(`${this.queryToken} LOCAL_PARAM_NOT_COLLECTED`);
  }

  private localHiLog(__ftHiLogTag: SyntaxLocalLogger): string {
    return __ftHiLogTag.info(`${this.queryToken} LOCAL_HILOG_NOT_COLLECTED`);
  }

  private localWeb(Web: (value: string) => string): string {
    return Web('local-web');
  }

  private runScope(): void {
    const logger: SyntaxLocalLogger = new SyntaxLocalLogger();
    const parameterValue = this.localConsole(logger);
    const hiLogValue = this.localHiLog(logger);
    let blockValue: string = '';
    {
      const console: SyntaxLocalLogger = logger;
      blockValue = console.info(`${this.queryToken} LOCAL_BLOCK_NOT_COLLECTED`);
    }
    const webValue = this.localWeb((value: string): string => value);
    const valid = logger.calls === 3 && parameterValue.endsWith('LOCAL_PARAM_NOT_COLLECTED') &&
      hiLogValue.endsWith('LOCAL_HILOG_NOT_COLLECTED') && blockValue.endsWith('LOCAL_BLOCK_NOT_COLLECTED') &&
      webValue === 'local-web';
    this.append(`${valid ? '通过' : '失败'}：局部 console/HiLog 调用=${logger.calls} 次，局部 Web 返回=${webValue}。`);
    console.info(`${this.queryToken} SCOPE_SYSTEM_CONSOLE`);
    __ftHiLogTag.info(__ftHiLogDomain, HILOG_TAG, '%{public}s', `${this.queryToken} SCOPE_SYSTEM_HILOG`);
    this.append('作用域：只应采集两个 SCOPE_SYSTEM 标识；三个 LOCAL_*_NOT_COLLECTED 均不应采集。');
  }

  private optionalConsole(console?: SyntaxLocalLogger): void {
    console?.info(this.record('UNEXPECTED_OPTIONAL_ARGUMENT'));
  }

  private runOptional(): void {
    this.evaluations = [];
    this.optionalConsole();
    this.append(`${this.evaluations.length === 0 ? '通过' : '失败'}：空接收者可选链的参数求值次数=${this.evaluations.length}，预期 0。`);
    console.info?.(`${this.queryToken} OPTIONAL_NATIVE_ONLY`);
    __ftHiLogTag.info?.(__ftHiLogDomain, HILOG_TAG, '%{public}s', `${this.queryToken} OPTIONAL_HILOG_NATIVE_ONLY`);
    this.append('可选调用：两个 OPTIONAL_* 标识仅输出系统日志，当前插件不自动采集。');
  }

  private runNamesAndText(): void {
    // @Entry @Component struct FakeComment { build() { Column() {} } }
    const literal: string = '@Entry @Component struct FakeString { build() { Column() {} } }';
    const template: string = `@Entry struct FakeTemplate { value: string = '${__ftConsoleCall}' }`;
    console.info(`${this.queryToken} GENERATED_NAMES`, __ftConsoleLogBridge, __ftConsoleCall, ...__ftConsoleArgs,
      this.__ftSessionReplayRootToken, this.__ftWebReplayBridge);
    console.info(`${this.queryToken} FAKE_ENTRY_TEXT`, literal, template);
    this.append('名称：GENERATED_NAMES 保持 user-console-bridge/user-console-call/user-a/user-b/user-replay-token/user-web-bridge。');
    this.append('文本：FAKE_ENTRY_TEXT 保留两个原始 @Entry 文本；单行组件正常显示。');
  }

  private resolveRootId(): string {
    this.rootEvaluations++;
    return `hvigor-syntax-root-${this.rootVersion}`;
  }

  private inspectRoot(): void {
    const actual = this.getUIContext().getFrameNodeById(`hvigor-syntax-root-${this.rootVersion}`);
    this.append(`Replay：当前根 ID=hvigor-syntax-root-${this.rootVersion}，节点${actual === null ? '未找到' : '存在'}；` +
      `ID 表达式累计求值=${this.rootEvaluations}，原触摸回调=${this.touchCalls} 次。`);
    this.append('对照 PAGE_SHOW/PAGE_HIDE：只在实际渲染时求值，显示/隐藏钩子不应额外求值。');
  }

  private startReplay(): void {
    const rumConfig = FTSDK.getRumConfig();
    if (rumConfig === null || rumConfig.getRumAppId().trim().length === 0) {
      this.append('请先按 Demo 原有方式配置非空 appId，再验证 Replay。');
      return;
    }
    FTSessionReplay.getInstance().start();
    this.replayEnabled = FTSessionReplay.getInstance().isEnabled();
    this.append(this.replayEnabled ? 'Replay 已开启，可切换根 ID、触摸页面，再上传并查看回放。' : 'Replay 未开启，请检查 Demo 配置。');
  }

  private upload(): void {
    FTSDK.flushSyncData();
    const replay = FTSessionReplay.getInstance();
    if (!replay.isEnabled()) {
      this.append('已请求上传日志；Replay 尚未开启。');
      return;
    }
    this.uploading = true;
    replay.flush().then((upload) => {
      this.append(`Replay 上传${upload.success ? '成功' : '未成功'}：${upload.uploadedSegments} 段，剩余 ${upload.remainingSegments} 段。`);
    }).catch(() => {
      this.append('Replay 上传失败，请检查网络和采集地址。');
    }).finally(() => {
      this.uploading = false;
    });
  }

  build() {
    Column() {
      TestPageHeader({ title: '构建插件语法验证', backText: '返回' })
      Scroll() {
        Column({ space: 12 }) {
          Text('构建成功后运行案例，用本轮标识查询日志；本地结果仅检查代码执行，采集结果请人工核对。')
            .fontSize(13).fontColor('#475569').width('100%')
          Text(this.queryToken).fontSize(14).fontColor('#1D4ED8').copyOption(this.copyMode)
          Button('运行全部日志案例').width('100%').height(46).backgroundColor('#2563EB')
            .onClick(() => this.runAll())
          Button('1. IIFE 前补分号 / 无分号语句').width('100%').height(40)
            .onClick(() => this.runAsi())
          Button('2. console / HiLog 展开与可空参数').width('100%').height(40)
            .onClick(() => this.runSpread())
          Button('3. 单次求值 / 参数顺序 / 嵌套日志').width('100%').height(40)
            .onClick(() => this.runEvaluation())
          Button('4. 无花括号 if / else / for').width('100%').height(40)
            .onClick(() => this.runControlFlow())
          Button('5. console / HiLog / Web 局部遮蔽').width('100%').height(40)
            .onClick(() => this.runScope())
          Button('6. 可选链与参数短路').width('100%').height(40)
            .onClick(() => this.runOptional())
          Button('7. 生成名称冲突 / 注释与模板字符串').width('100%').height(40)
            .onClick(() => this.runNamesAndText())
          SyntaxInlineSample()
          Divider()
          Text(`Replay / Web：${this.replayEnabled ? '录制已开启' : '录制未开启'}`).fontWeight(700)
          Text('根节点同时使用动态 ID、尾逗号、原 onTouch 回调与转场。Web 使用之前的本地 HTML，可操作页面中的 Browser Replay 案例。')
            .fontSize(12).fontColor('#475569')
          Button('开启 Replay').width('100%').height(40).onClick(() => this.startReplay())
          Button('切换动态根 ID').width('100%').height(40)
            .onClick(() => { this.rootVersion = this.rootVersion === 1 ? 2 : 1; })
          Button('查看实际根节点与求值次数').width('100%').height(40).onClick(() => this.inspectRoot())
          Button(this.showWeb ? '收起 Web' : '显示系统 Web').width('100%').height(40)
            .onClick(() => this.toggleWeb())
          if (this.showWeb) {
            Web({ src: $rawfile('session_replay_web.html'), controller: this.controller })
              .id('hvigor-syntax-web').width('100%').height(420)
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .onControllerAttached(() => this.webHandler.setWebView(this.controller))
              .onPageEnd(() => {
                console.info(`${this.queryToken} WEB_PAGE_END`);
                this.append('本地 session_replay_web.html 已加载，Web 原 onPageEnd 回调已执行。');
              })
          }
          Button(this.uploading ? '上传中…' : '上传日志与 Replay').width('100%').height(42)
            .enabled(!this.uploading).onClick(() => this.upload())
          Text('执行结果 / 查询预期').fontSize(17).fontWeight(700).width('100%')
          Text(this.result).fontSize(12).fontColor('#334155').width('100%')
            .copyOption(this.copyMode).padding(12).backgroundColor('#EEF4FF').borderRadius(8)
        }
        .width('100%').padding(16)
      }.width('100%').layoutWeight(1)
    }
    .id(this.resolveRootId(), /* trailing comma is intentional */)
    .onTouch(() => { this.touchCalls++; })
    .width('100%').height('100%').backgroundColor(this.pageBackground)
  }

  pageTransition(): void {
    PageTransitionEnter({ duration: 300, curve: this.transitionCurve }).slide(this.transitionSlide)
    PageTransitionExit({ duration: 300, curve: this.transitionCurve }).slide(this.transitionSlide)
  }
}
