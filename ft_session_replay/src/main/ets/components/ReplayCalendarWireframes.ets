import { UIContext } from '@kit.ArkUI';
import { i18n, resourceManager } from '@kit.LocalizationKit';
import { ArkUIReplayLightNode, ReplayCalendarTheme } from './SessionReplayScene';
import { ReplayShapeWireframe, ReplayTextWireframe, ReplayWireframe, ReplayWireframeClip } from './SessionReplayProtocol';

interface CalendarDate { year: number; month: number; day: number; }
interface CalendarMonth { year: number; month: number; }
interface CalendarGrid {
  month: CalendarMonth;
  selected?: CalendarDate;
  today: CalendarDate;
  theme: ReplayCalendarTheme;
  rtl: boolean;
  start?: CalendarDate;
  end?: CalendarDate;
  disabled: Array<CalendarDate>;
  markToday: boolean;
}

export interface ReplayCalendarPresentation {
  labels: Map<number, string>;
  grids: Map<number, CalendarGrid>;
  arrows: Map<number, string>;
}

/** Completes native paint-only CalendarPicker content with semantic mobile wireframes. */
export class ReplayCalendarWireframes {
  private themeCache: ReplayCalendarTheme | null = null;
  private themeKey: string = '';
  private themeAt: number = 0;
  private formatLocale: string = '';
  private weekdays: Array<string> = [];
  private dateOrder: string = '';
  private monthOrder: string = '';
  private monthNames: Array<string> = [];
  private numberFormat: Intl.NumberFormat | null = null;

  /** Only public resource tokens and locale are detached on UI; never a component bitmap. */
  public captureTheme(uiContext: UIContext | null, scale: number, timestamp: number): ReplayCalendarTheme {
    let locale = 'en-US';
    let dark = false;
    try { locale = i18n.System.getSystemLocale(); } catch (_) { }
    try {
      const configuration = uiContext?.getHostContext()?.resourceManager.getConfigurationSync();
      if (configuration !== undefined) {
        if (configuration.locale.length > 0) locale = configuration.locale;
        dark = configuration.colorMode === resourceManager.ColorMode.DARK;
      }
    } catch (_) { }
    // ResourceManager.Configuration uses ICU identifiers (zh_Hans_CN,
    // en__US); Intl requires BCP 47 language tags, including on the Worker.
    locale = this.normalizeLocale(locale);
    const key = `${locale}|${dark}|${scale}`;
    if (this.themeCache !== null && this.themeKey === key && timestamp - this.themeAt < 1000) return this.themeCache;
    let resources: resourceManager.ResourceManager | null = null;
    try { resources = resourceManager.getSystemResourceManager(); } catch (_) { }
    const color = (name: string, fallback: string): string => {
      try {
        const argb = (resources!.getColorByNameSync(name) >>> 0).toString(16).padStart(8, '0').toUpperCase();
        return `#${argb.substring(2)}${argb.substring(0, 2)}`;
      } catch (_) { return fallback; }
    };
    const number = (name: string, fallback: number): number => {
      try { const value = resources!.getNumberByName(name); return Number.isFinite(value) ? value : fallback; }
      catch (_) { return fallback; }
    };
    const suffix = dark ? '_dark' : '';
    const theme: ReplayCalendarTheme = {
      locale,
      primary: color('ohos_id_color_text_primary', dark ? '#FFFFFFFF' : '#000000FF'),
      accent: color('ohos_id_color_text_primary_activated', '#0A59F7FF'),
      selected: color('ohos_id_color_emphasize', '#0A59F7FF'),
      selectedText: color('ohos_id_color_text_primary_contrary', '#FFFFFFFF'),
      primaryAlpha: number('ohos_id_alpha_content_primary', 0.9),
      tertiaryAlpha: number('ohos_id_alpha_content_tertiary', 0.4),
      highlightAlpha: number('ohos_id_alpha_highlight_bg', 0.2),
      dayFontSize: 16,
      shadow: {
        color: color(`ohos_id_shadow_default_sm${suffix}`, dark ? '#00000055' : '#00000026'),
        offsetX: number(`ohos_id_shadow_default_sm_offset_x${suffix}`, 0) / scale,
        offsetY: number(`ohos_id_shadow_default_sm_offset_y${suffix}`, 10) / scale,
        blurRadius: number(dark ? 'ohos_id_radius_default_sm_shadow_dark' : 'ohos_id_shadow_default_sm_shadow', 40) / scale
      }
    };
    this.themeCache = theme; this.themeKey = key; this.themeAt = timestamp;
    return theme;
  }

  public prepare(nodes: Array<ArkUIReplayLightNode>, timestamp: number): ReplayCalendarPresentation {
    const presentation: ReplayCalendarPresentation = { labels: new Map(), grids: new Map(), arrows: new Map() };
    if (!nodes.some((node): boolean => node.nodeType === 'CalendarDialog')) return presentation;
    const entries = nodes.filter((node): boolean => node.nodeType === 'CalendarPicker');
    for (let index = 0; index < nodes.length; index++) {
      const panel = nodes[index];
      if (panel.nodeType !== 'CalendarDialog' || panel.calendarTheme === undefined) continue;
      const theme = panel.calendarTheme;
      const locale = this.normalizeLocale(theme.locale);
      const descendants: Array<ArkUIReplayLightNode> = [];
      for (let next = index + 1; next < nodes.length && descendants.length < 64; next++) {
        const candidate = nodes[next];
        if (candidate.sceneLayer !== panel.sceneLayer || candidate.nodeType === 'Dialog' || candidate.nodeType === 'CalendarDialog') break;
        descendants.push(candidate);
      }
      // Navigation is static control geometry. Never couple it to localized
      // month parsing, the visible grid count, or weekday text availability.
      for (const descendant of descendants) {
        const arrow = /^resource:\/\/\/ohos_ic_public_(double_)?arrow_(left|right)\.svg$/.exec(this.string(descendant, 'src'));
        if (descendant.nodeType === 'Image' && arrow !== null) presentation.arrows.set(descendant.id,
          this.arrow(arrow[2] === 'left', arrow[1] !== undefined, this.color(this.string(descendant, 'fillColor'), theme.primary)));
      }
      if (!this.prepareFormats(locale)) continue;
      const grids = descendants.filter((node): boolean => node.nodeType === 'Calendar' &&
        this.attrs(node)['dayWidth'] !== undefined && this.visible(node));
      // Do not guess the month of an offscreen/swiping sibling calendar.
      if (grids.length !== 1) continue;
      const grid = grids[0];
      const title = descendants.find((node): boolean => node.nodeType === 'Text' &&
        this.string(node, 'content').length > 0 && node.y < grid.y);
      const month = title === undefined ? null : this.readMonth(this.string(title, 'content'), locale);
      if (month === null) continue;
      const weekdays = descendants.filter((node): boolean => node.nodeType === 'Text' && node !== title &&
        node.y > (title?.y ?? panel.y) && node.y < grid.y && node.width <= grid.width / 4);
      if (weekdays.length !== 7) continue;
      for (let day = 0; day < 7; day++) {
        // Native CalendarPicker constructs weekdays Sunday first, independently of generic Calendar.startOfWeek.
        if (this.string(weekdays[day], 'content').length === 0) {
          presentation.labels.set(weekdays[day].id, this.weekdays[day]);
        }
      }
      // A single entry is unambiguous. With multiple pickers, omit selection rather than borrow another entry's value.
      const owners = entries.filter((entry): boolean => entry.sceneLayer === undefined ||
        entry.sceneLayer !== panel.sceneLayer);
      const entry = owners.length === 1 ? owners[0] : undefined;
      const selected = entry === undefined ? undefined : this.readSelection(entry, nodes, locale);
      const attrs = entry === undefined ? {} as Record<string, Object> : this.attrs(entry);
      const now = new Date(timestamp);
      presentation.grids.set(grid.id, {
        month, selected, theme, rtl: weekdays[0].x > weekdays[6].x,
        today: { year: now.getFullYear(), month: now.getMonth() + 1, day: now.getDate() },
        start: this.readDate(String(attrs['start'] ?? ''), 'yMd'),
        end: this.readDate(String(attrs['end'] ?? ''), 'yMd'),
        disabled: String(attrs['disabledDateRange'] ?? '').split(',').map((value): CalendarDate | undefined =>
          this.readDate(value, 'yMd')).filter((value): boolean => value !== undefined) as Array<CalendarDate>,
        markToday: String(attrs['markToday'] ?? 'false') === 'true'
      });
    }
    return presentation;
  }

  /** Native entry borders are layout paint; Inspector can report a zero RenderContext width. */
  public completeEntry(entry: ArkUIReplayLightNode, nodes: Array<ArkUIReplayLightNode>, index: number,
    frame: ReplayShapeWireframe, scale: number, limit: number): Array<ReplayWireframe> {
    let up: ArkUIReplayLightNode | undefined;
    let down: ArkUIReplayLightNode | undefined;
    for (let next = index + 1; next + 1 < nodes.length && next < index + 24; next++) {
      const button = nodes[next];
      if (button.sceneLayer !== entry.sceneLayer || button.nodeType === 'CalendarPicker' ||
        button.nodeType === 'CalendarDialog' || button.nodeType === 'Dialog') break;
      const icon = nodes[next + 1];
      if (button.nodeType !== 'Button' || button.componentId.length > 0 || icon.nodeType !== 'Image' ||
        button.x < entry.x || button.y < entry.y || button.x + button.width > entry.x + entry.width + 0.5 ||
        button.y + button.height > entry.y + entry.height + 0.5 || icon.sceneLayer !== entry.sceneLayer ||
        icon.x < button.x || icon.y < button.y || icon.x + icon.width > button.x + button.width + 0.5 ||
        icon.y + icon.height > button.y + button.height + 0.5) continue;
      const source = this.string(icon, 'src');
      if (source === 'resource:///ohos_ic_public_arrow_up.svg') up = button;
      if (source === 'resource:///ohos_ic_public_arrow_down.svg') down = button;
    }
    // Require the real, stacked native buttons, not arbitrary content near a picker.
    if (up === undefined || down === undefined || Math.abs(up.x - down.x) > 0.5 ||
      Math.abs(up.width - down.width) > 0.5 || Math.abs(up.y + up.height - down.y) > 0.5) return [];
    const span = down.y + down.height - up.y;
    const padding = this.attrs(entry)['padding'];
    let paddingTop = 0;
    let paddingBottom = 0;
    try {
      const value = typeof padding === 'string' && padding.trim().startsWith('{') ?
        JSON.parse(padding) as Record<string, Object> : padding as Record<string, Object>;
      if (value !== undefined && value !== null && typeof value === 'object') {
        paddingTop = this.length(value['top'], scale, 0);
        paddingBottom = this.length(value['bottom'], scale, 0);
      } else {
        paddingTop = paddingBottom = this.length(padding, scale, 0);
      }
    } catch (_) { return []; }
    const inset = this.round((entry.height - span - paddingTop - paddingBottom) / 2);
    // No hard-coded outer outline: a genuinely borderless entry has no layout inset.
    if (frame.border === undefined && inset > 0 && inset <= Math.min(entry.width, entry.height) / 4) {
      frame.border = { width: inset, color: this.color(this.string(entry, 'borderColor'), '#00000019') };
    }
    if (limit < 2) return [];
    // Native add/sub buttons retain their own theme borders even if the host border is overridden.
    const width = 1;
    const color = this.color(this.string(up, 'borderColor'), '#00000019');
    const rtl = up.x + up.width / 2 < entry.x + entry.width / 2;
    const vertical: ReplayShapeWireframe = {
      id: -(entry.id * 1024 + 817), type: 'shape', x: rtl ? up.x + up.width - width : up.x,
      y: up.y, width, height: span,
      shapeStyle: { backgroundColor: color, opacity: entry.opacity ?? 1, visible: frame.shapeStyle?.visible }
    };
    const horizontal: ReplayShapeWireframe = {
      id: -(entry.id * 1024 + 818), type: 'shape', x: up.x, y: this.round(down.y - width / 2),
      width: up.width, height: width,
      shapeStyle: { backgroundColor: color, opacity: entry.opacity ?? 1, visible: frame.shapeStyle?.visible }
    };
    const parts: Array<ReplayWireframe> = [vertical, horizontal];
    for (const part of parts) part.clip = this.clip(entry, part);
    return parts;
  }

  /** Stable selected/today shapes and at most 42 independently updatable date texts. */
  public create(node: ArkUIReplayLightNode, grid: CalendarGrid, scale: number, limit: number,
    filter: (value: string) => string, allowSelection: boolean): Array<ReplayWireframe> {
    const first = this.date(grid.month.year, grid.month.month, 1);
    const count = this.date(grid.month.year, grid.month.month + 1, 0).getUTCDate();
    const offset = first.getUTCDay();
    const rows = Math.ceil((offset + count) / 7);
    const cells = rows * 7;
    if (rows < 4 || rows > 6 || limit < cells + 2 || !this.prepareFormats(grid.theme.locale)) return [];
    const attrs = this.attrs(node);
    const width = this.length(attrs['dayWidth'], scale, 32);
    const height = this.length(attrs['dayHeight'], scale, width);
    const gapX = this.length(attrs['colSpace'], scale, (node.width - 8 - 7 * width) / 6);
    const gapY = this.length(attrs['weekAndDayRowSpace'], scale, 0);
    const weekHeight = this.length(attrs['weekHeight'], scale, height);
    // SetColRowSpace() derives spacing from the real layout. Invert that relation
    // to retain the native Gregorian text height even when Inspector reports zero.
    const gregorian = this.length(attrs['gregorianCalendarHeight'], scale, 0) ||
      rows * (height + gapY) + height - node.height + 4;
    const startY = weekHeight + gapY - gregorian;
    if (![width, height, gapX, gapY, startY].every((value): boolean => Number.isFinite(value)) ||
      width <= 0 || height <= 0 || gapX < 0 || gapY < 0 || startY < -height || startY > node.height) return [];
    const parts: Array<ReplayWireframe> = [];
    const selected: ReplayShapeWireframe = {
      id: -(node.id * 1024 + 769), type: 'shape', x: node.x, y: node.y, width, height,
      zIndex: 0, shapeStyle: { backgroundColor: '#00000000', cornerRadius: Math.min(width, height) / 2, opacity: node.opacity ?? 1 }
    };
    parts.push(selected);
    const markedToday: ReplayShapeWireframe = {
      id: -(node.id * 1024 + 770), type: 'shape', x: node.x, y: node.y, width, height,
      zIndex: 0, shapeStyle: { backgroundColor: '#00000000', cornerRadius: Math.min(width, height) / 2, opacity: node.opacity ?? 1 }
    };
    parts.push(markedToday);
    for (let index = 0; index < cells; index++) {
      const date = this.date(grid.month.year, grid.month.month, 1 - offset + index);
      const value: CalendarDate = { year: date.getUTCFullYear(), month: date.getUTCMonth() + 1, day: date.getUTCDate() };
      const current = value.year === grid.month.year && value.month === grid.month.month;
      const today = this.equal(value, grid.today);
      const enabled = this.enabled(value, grid);
      const chosen = allowSelection && current && enabled && this.equal(value, grid.selected);
      const column = grid.rtl ? 6 - index % 7 : index % 7;
      const x = this.round(node.x + 4 + column * (width + gapX));
      const y = this.round(node.y + startY + Math.floor(index / 7) * (height + gapY));
      if (chosen) {
        selected.x = x; selected.y = y;
        selected.shapeStyle!.backgroundColor = today ? grid.theme.selected : this.alpha(grid.theme.selected, grid.theme.highlightAlpha);
      }
      if (!chosen && allowSelection && grid.markToday && current && today && enabled) {
        markedToday.x = x; markedToday.y = y;
        markedToday.shapeStyle!.backgroundColor = grid.theme.selected;
      }
      const color = !current || !enabled ? this.alpha(grid.theme.primary, grid.theme.tertiaryAlpha) :
        today ? allowSelection && (chosen || grid.markToday) ? grid.theme.selectedText : grid.theme.accent :
          this.alpha(grid.theme.primary, grid.theme.primaryAlpha);
      const text: ReplayTextWireframe = {
        id: -(node.id * 1024 + 771 + index), type: 'text', x, y, width, height,
        zIndex: 1, text: filter(this.numberFormat!.format(value.day)), shapeStyle: { opacity: node.opacity ?? 1 },
        textStyle: { family: 'sans-serif', size: this.length(attrs['dayFontSize'], scale, grid.theme.dayFontSize), weight: 500, color },
        textPosition: { alignment: { horizontal: 'center', vertical: 'center' } }
      };
      parts.push(text);
    }
    for (const part of parts) part.clip = this.clip(node, part);
    return parts;
  }

  private readSelection(entry: ArkUIReplayLightNode, nodes: Array<ArkUIReplayLightNode>, locale: string): CalendarDate | undefined {
    const index = nodes.indexOf(entry);
    const texts: Array<string> = [];
    for (let next = index + 1; next < nodes.length && next < index + 24; next++) {
      const node = nodes[next];
      if (node.sceneLayer !== entry.sceneLayer || node.nodeType === 'CalendarPicker' ||
        node.nodeType === 'CalendarDialog' || node.nodeType === 'Dialog') break;
      if (node.nodeType === 'Text' && node.x >= entry.x && node.x + node.width <= entry.x + entry.width + 1 &&
        node.y >= entry.y && node.y + node.height <= entry.y + entry.height + 1) texts.push(this.string(node, 'content'));
    }
    return this.prepareFormats(locale) ? this.readDate(texts.join(''), this.dateOrder) : undefined;
  }

  private readMonth(title: string, locale: string): CalendarMonth | null {
    const normalized = this.digits(title);
    const values = normalized.match(/\d+/g) ?? [];
    if (values.length === 2) {
      const year = Number(values[this.monthOrder.indexOf('y')]);
      const month = Number(values[this.monthOrder.indexOf('m')]);
      if (year >= 1 && year <= 9999 && month >= 1 && month <= 12) return { year, month };
    }
    if (values.length !== 1 || Number(values[0]) < 1 || Number(values[0]) > 9999) return null;
    const year = Number(values[0]);
    try {
      if (this.monthNames.length === 0) {
        for (let month = 1; month <= 12; month++) {
          for (const style of ['long', 'short']) {
            const format = new Intl.DateTimeFormat(locale, { month: style as 'long' | 'short', calendar: 'gregory', timeZone: 'UTC' });
            this.monthNames.push(format.format(this.date(2006, month, 1)).toLocaleLowerCase(locale));
          }
        }
      }
      const title = normalized.toLocaleLowerCase(locale);
      const index = this.monthNames.findIndex((name): boolean => title.includes(name));
      if (index >= 0) return { year, month: Math.floor(index / 2) + 1 };
    } catch (_) { }
    return null;
  }

  private prepareFormats(locale: string): boolean {
    // Also normalize detached snapshots supplied by manual capture callers.
    locale = this.normalizeLocale(locale);
    if (this.formatLocale === locale && this.numberFormat !== null) return true;
    try {
      const weekday = new Intl.DateTimeFormat(locale, {
        weekday: /^(zh|ja)(-|$)/i.test(locale) ? 'narrow' : 'short', calendar: 'gregory', timeZone: 'UTC'
      });
      const date = new Intl.DateTimeFormat(locale, { year: 'numeric', month: '2-digit', day: '2-digit', calendar: 'gregory' });
      const month = new Intl.DateTimeFormat(locale, { year: 'numeric', month: 'numeric', calendar: 'gregory' });
      const sample = this.date(2006, 11, 22);
      this.dateOrder = date.formatToParts(sample).filter((part): boolean => part.type === 'year' ||
        part.type === 'month' || part.type === 'day').map((part): string => part.type.charAt(0)).join('');
      this.monthOrder = month.formatToParts(sample).filter((part): boolean => part.type === 'year' ||
        part.type === 'month').map((part): string => part.type.charAt(0)).join('');
      this.weekdays = [];
      for (let day = 0; day < 7; day++) this.weekdays.push(weekday.format(this.date(2023, 1, 1 + day)));
      this.monthNames = [];
      this.numberFormat = new Intl.NumberFormat(locale, { useGrouping: false });
      if (this.dateOrder.length !== 3 || this.monthOrder.length !== 2) { this.numberFormat = null; return false; }
      this.formatLocale = locale;
      return true;
    } catch (_) { this.numberFormat = null; return false; }
  }

  private normalizeLocale(locale: string): string {
    // Empty ICU script/region components must not produce invalid double or
    // trailing hyphens (en__US -> en-US, zh_Hans_ -> zh-Hans).
    return locale.trim().split(/[-_]+/).filter((part): boolean => part.length > 0).join('-') || 'en-US';
  }

  private readDate(text: string, order: string): CalendarDate | undefined {
    const values = this.digits(text).match(/\d+/g) ?? [];
    if (values.length !== 3 || order.length !== 3) return undefined;
    const year = Number(values[order.toLowerCase().indexOf('y')]);
    const month = Number(values[order.toLowerCase().indexOf('m')]);
    const day = Number(values[order.toLowerCase().indexOf('d')]);
    const date = this.date(year, month, day);
    return year >= 1 && year <= 9999 && date.getUTCFullYear() === year && date.getUTCMonth() + 1 === month &&
      date.getUTCDate() === day ? { year, month, day } : undefined;
  }

  private enabled(date: CalendarDate, grid: CalendarGrid): boolean {
    const key = this.key(date);
    if ((grid.start !== undefined && key < this.key(grid.start)) || (grid.end !== undefined && key > this.key(grid.end))) return false;
    for (let index = 0; index + 1 < grid.disabled.length; index += 2) {
      if (key >= this.key(grid.disabled[index]) && key <= this.key(grid.disabled[index + 1])) return false;
    }
    return true;
  }

  private attrs(node: ArkUIReplayLightNode): Record<string, Object> {
    const object = (node.inspectorInfo ?? {}) as Record<string, Object>;
    return (object['$attrs'] ?? object) as Record<string, Object>;
  }
  private string(node: ArkUIReplayLightNode, name: string): string {
    const value = this.attrs(node)[name]; return typeof value === 'string' ? value : '';
  }
  private visible(node: ArkUIReplayLightNode): boolean {
    return (node.opacity ?? 1) > 0 && (node.clip?.left ?? 0) + (node.clip?.right ?? 0) < node.width &&
      (node.clip?.top ?? 0) + (node.clip?.bottom ?? 0) < node.height;
  }
  private date(year: number, month: number, day: number): Date {
    const date = new Date(0); date.setUTCFullYear(year, month - 1, day); return date;
  }
  private digits(value: string): string {
    return value.replace(/[\u0660-\u0669\u06F0-\u06F9\uFF10-\uFF19]/g, (digit: string): string =>
      String(digit.charCodeAt(0) - (digit.charCodeAt(0) >= 0xFF10 ? 0xFF10 : digit.charCodeAt(0) >= 0x06F0 ? 0x06F0 : 0x0660)));
  }
  private equal(a: CalendarDate, b: CalendarDate | undefined): boolean { return b !== undefined && this.key(a) === this.key(b); }
  private key(date: CalendarDate): number { return date.year * 10000 + date.month * 100 + date.day; }
  private round(value: number): number { return Math.round(value * 100) / 100; }
  private length(value: Object | undefined, scale: number, fallback: number): number {
    if (value === undefined) return fallback;
    const parsed = parseFloat(String(value));
    return Number.isFinite(parsed) ? parsed / (String(value).endsWith('px') ? scale : 1) : fallback;
  }
  private alpha(color: string, opacity: number): string {
    return `${color.substring(0, 7)}${Math.round(parseInt(color.substring(7, 9), 16) * Math.max(0, Math.min(1, opacity))).toString(16).padStart(2, '0').toUpperCase()}`;
  }
  private color(value: string, fallback: string): string {
    const match = /^#([0-9A-F]{8})$/i.exec(value);
    return match === null ? fallback : `#${match[1].substring(2).toUpperCase()}${match[1].substring(0, 2).toUpperCase()}`;
  }
  private clip(node: ArkUIReplayLightNode, part: ReplayWireframe): ReplayWireframeClip {
    return {
      left: this.round(Math.min(part.width, Math.max(0, node.x + (node.clip?.left ?? 0) - part.x))),
      right: this.round(Math.min(part.width, Math.max(0, part.x + part.width - node.x - node.width + (node.clip?.right ?? 0)))),
      top: this.round(Math.min(part.height, Math.max(0, node.y + (node.clip?.top ?? 0) - part.y))),
      bottom: this.round(Math.min(part.height, Math.max(0, part.y + part.height - node.y - node.height + (node.clip?.bottom ?? 0))))
    };
  }
  private arrow(left: boolean, double: boolean, color: string): string {
    const path = left ? 'M14 6L8 12L14 18' : 'M10 6L16 12L10 18';
    const second = double ? `<path d="${path}" transform="translate(${left ? 5 : -5} 0)"/>` : '';
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><g fill="none" stroke="${color}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="${path}"/>${second}</g></svg>`;
  }
}
