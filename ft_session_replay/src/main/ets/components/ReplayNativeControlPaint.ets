interface ControlPaintState {
  signature: string;
  changedAt: number;
}

export interface ReplayControlPaintSample { signature: string; active: boolean; }

/** Public paint attributes only; native state changes receive a bounded animation tail. */
export class ReplayNativeControlPaint {
  private readonly states: Map<number, ControlPaintState> = new Map();
  private selectionRevision: number = 0;
  private selectionUntil: number = 0;
  private paintRevision: number = 0;

  public isSupported(type: string): boolean {
    return ['Button', 'Toggle', 'Switch', 'Checkbox', 'CheckboxGroup', 'Radio', 'Slider',
      'Rating', 'Progress', 'LoadingProgress', 'Gauge', 'DataPanel', 'PatternLock'].includes(type);
  }

  /** PatternLock keeps its chosen points in native paint state, outside Inspector. */
  public invalidatePaint(): void { this.paintRevision++; }

  public clear(): void {
    this.states.clear(); this.selectionRevision = 0; this.selectionUntil = 0; this.paintRevision = 0;
  }

  public sample(id: number, type: string, info: Object | null, time: number, visible: boolean): ReplayControlPaintSample {
    const object = (info ?? {}) as Record<string, Object>;
    const attrs = (object['$attrs'] ?? object) as Record<string, Object>;
    const keys = new Set(Object.keys(attrs));
    let signature = `${type}|`;
    for (const key of ['type', 'style', 'label', 'constructor', 'options', 'value', 'values', 'total', 'min', 'max',
      'checked', 'select', 'selectAll', 'isOn', 'enabled', 'focused', 'selectedColor', 'unselectedColor',
      'backgroundColor', 'foregroundColor', 'color', 'colors', 'fontSize', 'fontColor', 'fontWeight', 'fontFamily', 'fontStyle',
      'borderRadius', 'padding', 'mark', 'switchPointColor', 'trackBorderRadius', 'rating', 'stars', 'starStyle',
      'indicator', 'trackColor', 'blockColor', 'blockSize', 'blockType', 'blockBorderColor', 'blockBorderWidth',
      'trackThickness', 'showSteps', 'stepColor', 'strokeWidth', 'progressGradientColor', 'startAngle', 'endAngle',
      'trackShadow', 'trackBackgroundColor', 'valueColors', 'enableLoading', 'circleRadius', 'regularColor',
      'activeColor', 'pathColor', 'pathStrokeWidth', 'autoReset', 'activeCircleColor', 'activeCircleRadius',
      'enableWaveEffect', 'enableForeground', 'skipUnselectedPoint']) {
      if (keys.has(key) && attrs[key] !== undefined) {
        try { signature += `${key}:${JSON.stringify(attrs[key]).substring(0, 2048)}|`; } catch (_) {}
      }
    }
    signature = signature.substring(0, 16384);
    if (type === 'PatternLock') signature += `native-paint:${this.paintRevision}|`;
    // Offscreen controls must not evict visible paint state or restart its
    // animation tail on every pass through a long Scroll/List.
    if (!visible) return { signature: `${signature}|0|paint:3`, active: false };
    let state = this.states.get(id);
    if (state === undefined || state.signature !== signature) {
      state = { signature, changedAt: time };
      this.states.delete(id);
      this.states.set(id, state);
      while (this.states.size > 64) this.states.delete(this.states.keys().next().value as number);
      if (visible && (type === 'Checkbox' || type === 'CheckboxGroup' || type === 'Toggle')) {
        this.selectionRevision++;
        this.selectionUntil = time + 600;
      }
    }
    const loading = type === 'LoadingProgress' && String(attrs['enableLoading'] ?? 'true') !== 'false' &&
      String(attrs['enabled'] ?? 'true') !== 'false';
    const groupChanging = type === 'CheckboxGroup' && time < this.selectionUntil;
    const active = visible && (loading || groupChanging || time - state.changedAt < 500);
    const phase = loading || groupChanging ? Math.floor(time / 200) : Math.min(3, Math.floor((time - state.changedAt) / 200));
    // Group paint can change when a sibling Checkbox changes even if its
    // configured selectAll property stays unchanged (including partial selection).
    return { signature: `${signature}|${type === 'CheckboxGroup' ? this.selectionRevision : 0}|paint:${phase}`, active };
  }
}
