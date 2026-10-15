export interface BrowserReplayState {
  bridgePresent: boolean;
  sdkPresent: boolean;
  capabilities: Array<string>;
  recording: boolean | null;
  visibility: string;
  focused: boolean;
  error: string;
}

export interface NativeReplayState {
  enabled: boolean;
  webTracing: boolean;
  slotId: string;
}

export interface BrowserReplayProbeResult {
  state: BrowserReplayState | null;
  error: string;
}

/** Read-only: never initializes, starts, stops or modifies the inspected page. */
export const WEB_REPLAY_STATE_SCRIPT: string = `JSON.stringify((function () {
  var bridge = window.FTWebViewJavascriptBridge, rum = window.DATAFLUX_RUM;
  var state = { bridgePresent: !!bridge, sdkPresent: !!rum, capabilities: [],
    recording: null, visibility: document.visibilityState, focused: document.hasFocus(), error: '' };
  try {
    var raw = bridge && bridge.getCapabilities && bridge.getCapabilities();
    var capabilities = typeof raw === 'string' && raw ? JSON.parse(raw) : [];
    if (Array.isArray(capabilities)) state.capabilities = capabilities.filter(function (v) { return typeof v === 'string'; });
    if (rum && typeof rum.isRecording === 'function') state.recording = rum.isRecording() === true;
  } catch (error) { state.error = String(error && error.message || error); }
  return state;
})())`;

/** ArkWeb versions may return JSON directly or as a quoted JS string result. */
export function parseBrowserReplayState(result: string): BrowserReplayState {
  const decoded = JSON.parse(result) as BrowserReplayState | string;
  const state = typeof decoded === 'string' ? JSON.parse(decoded) as BrowserReplayState : decoded;
  if (state === null || typeof state !== 'object' || typeof state.bridgePresent !== 'boolean' ||
    typeof state.sdkPresent !== 'boolean' || !Array.isArray(state.capabilities) ||
    !state.capabilities.every((value: string): boolean => typeof value === 'string') ||
    (state.recording !== null && typeof state.recording !== 'boolean') ||
    typeof state.visibility !== 'string' || typeof state.focused !== 'boolean' || typeof state.error !== 'string') {
    throw new Error('网页返回的录制状态无效，请等待加载完成后重试。');
  }
  return state;
}

export function formatWebReplayState(native: NativeReplayState, browser: BrowserReplayState | null,
  error: string = ''): string {
  const nativeText = `原生 Replay=${native.enabled ? '已开启' : '未开启'}；Web 追踪=${native.webTracing ? '已开启' : '未开启'}`;
  const slotText = `slot=${native.slotId || '待原生采集'}`;
  let browserText = 'Browser=未检查（点击“检查状态”读取）';
  if (browser !== null) {
    browserText = `Bridge=${browser.bridgePresent ? '存在' : '缺失'}；records=${browser.capabilities.includes('records')}` +
      `；recording=${browser.recording === null ? '接口不可用' : String(browser.recording)}` +
      `\nvisibility=${browser.visibility}；focused=${browser.focused}`;
  }
  let hint = '';
  if (!native.enabled) hint = '先开启原生 Replay；Browser 录制不等于原生已接收。';
  else if (!native.webTracing) hint = '全局 FTRUMConfig 需设置 setEnableTraceWebView(true)。';
  else if (error.length > 0 || (browser?.error.length ?? 0) > 0) hint = `读取失败：${(error || browser?.error || '').slice(0,180)}`;
  else if (browser !== null) {
    if (!browser.bridgePresent || !browser.capabilities.includes('records')) hint = 'Bridge 未就绪，检查绑定；开启 Replay 后可重建 Web 再试。';
    else if (!browser.sdkPresent) hint = 'Browser SDK 未加载；内置页请点“启动 Browser Replay”。';
    else if (browser.recording === null) hint = 'isRecording() 不可用，检查 SDK 是否加载完成及其版本。';
    else if (!browser.recording) hint = 'Browser 未录制。启动 Browser Replay；若 SDK 提前加载，可重建 Web 后重试。';
    else if (native.slotId.length === 0) hint = 'Browser 正在录制，等待原生 Web 容器采集后再次检查。';
    else hint = '录制状态就绪；是否接收、采样和上传成功仍需看日志/上传结果。';
  }
  return `${nativeText}\n${slotText}\n${browserText}${hint.length > 0 ? '\n' + hint : ''}`;
}

/** Discard a retired controller's callbacks and bound the diagnostic wait. */
export class WebReplayProbe {
  private generation: number = 0;
  private readonly timeoutMs: number;

  constructor(timeoutMs: number = 3000) { this.timeoutMs = timeoutMs; }

  public cancel(): void { this.generation++; }

  public async read(execute: (script: string) => Promise<string>): Promise<BrowserReplayProbeResult | null> {
    const generation = ++this.generation;
    let timeout: number = -1;
    try {
      const deadline = new Promise<string>((_resolve, reject): void => {
        timeout = setTimeout((): void => reject(new Error('读取超时，请等待网页加载完成后重试。')), this.timeoutMs);
      });
      const result = await Promise.race([execute(WEB_REPLAY_STATE_SCRIPT), deadline]);
      if (generation !== this.generation) return null;
      return { state: parseBrowserReplayState(result), error: '' };
    } catch (error) {
      if (generation !== this.generation) return null;
      return { state: null, error: String(error) };
    } finally {
      if (timeout !== -1) clearTimeout(timeout);
    }
  }
}
