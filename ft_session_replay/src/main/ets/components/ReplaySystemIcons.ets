import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { ReplayControlVectors } from './ReplayControlVectors';

// These are immutable native control chrome, not arbitrary application media.
// Keep exact names: a user image whose filename merely contains "eye" or
// "drawer" must never enter the control-geometry / image-privacy exemption.
const SYSTEM_ICON_NAMES: Array<string> = [
  'ohos_show_password', 'ohos_hide_password', 'ohos_ic_public_drawer',
  'ohos_search', 'ohos_close', 'ohos_ic_public_input_search', 'ohos_ic_public_cancel',
  'ohos_ic_public_arrow_left', 'ohos_ic_public_arrow_right',
  'ohos_ic_public_arrow_up', 'ohos_ic_public_arrow_down',
  'ohos_ic_public_double_arrow_left', 'ohos_ic_public_double_arrow_right'
];
const MAX_SYSTEM_ICON_BYTES = 32 * 1024;

/** Resolves only known system SVG leaves. No component snapshots or app pixels. */
export class ReplaySystemIcons {
  private readonly icons: Map<string, string | null> = new Map();
  private readonly symbols: Map<string, number> = new Map();

  public clear(): void { this.icons.clear(); this.symbols.clear(); }

  /** Public resource APIs run on UI; only bounded, static SVG data crosses queues. */
  public capture(info: Object | null): string | undefined {
    const object = (info ?? {}) as Record<string, Object>;
    const attrs = (object['$attrs'] ?? object) as Record<string, Object>;
    const source = attrs['src'];
    if (typeof source !== 'string') return undefined;
    const match = /^resource:\/\/\/(ohos_[a-z0-9_]+)\.svg$/.exec(source);
    if (match === null || !SYSTEM_ICON_NAMES.includes(match[1])) return undefined;
    return this.load(match[1]);
  }

  /** API 13+ uses a native SymbolGlyph for the default password eye. */
  public capturePasswordSymbol(ownerInfo: Object | null): string | undefined {
    const object = (ownerInfo ?? {}) as Record<string, Object>;
    const attrs = (object['$attrs'] ?? object) as Record<string, Object>;
    if (!String(attrs['type'] ?? '').toUpperCase().includes('PASSWORD')) return undefined;
    const shown = String(attrs['showPassword']);
    if (shown !== 'true' && shown !== 'false') return undefined;
    let icons = attrs['passwordIcon'];
    if (typeof icons === 'string') {
      if (icons.length > 1024) return undefined;
      try { icons = JSON.parse(icons) as Object; } catch (_) { return undefined; }
    }
    if (icons === null || typeof icons !== 'object' || Array.isArray(icons)) return undefined;
    const sources = icons as Record<string, Object>;
    const eye = this.symbol('eye');
    const slash = this.symbol('eye_slash');
    // Do not replace custom icons based on input type alone. Match both actual
    // native resource IDs, then use only the owner's scalar visibility state.
    if (eye <= 0 || slash <= 0 || String(sources['onIconSrc']) !== String(eye) ||
      String(sources['offIconSrc']) !== String(slash)) return undefined;
    return this.load(shown === 'true' ? 'ohos_show_password' : 'ohos_hide_password');
  }

  private symbol(name: string): number {
    const cached = this.symbols.get(name);
    if (cached !== undefined) return cached;
    let code = 0;
    try { code = resourceManager.getSystemResourceManager().getSymbolByName(name); } catch (_) { }
    this.symbols.set(name, code);
    return code;
  }

  private load(name: string): string | undefined {
    if (this.icons.has(name)) return this.icons.get(name) ?? undefined;
    let svg: string | null = null;
    try {
      const bytes = resourceManager.getSystemResourceManager().getMediaByNameSync(name);
      if (bytes.byteLength > 0 && bytes.byteLength <= MAX_SYSTEM_ICON_BYTES) {
        // Some built-in assets (notably arrow_down) contain generator XML
        // comments. They are inert and must not trip the declaration check
        // below; DOCTYPE / ENTITY declarations remain rejected.
        const text = util.TextDecoder.create('utf-8').decodeWithStream(bytes).replace(/<!--[\s\S]*?-->/g, '');
        const start = text.indexOf('<svg');
        const end = text.lastIndexOf('</svg>');
        const candidate = start >= 0 && end > start ? text.substring(start, end + 6) : '';
        // The allowlist is the trust boundary; also reject active content and
        // external references if a vendor resource differs from the standard.
        if (candidate.length > 0 && !/<(?:script|image|foreignObject)\b|\bon[a-z]+\s*=|<!|url\(\s*[^#]|(?:xlink:)?href\s*=\s*["'][^#]/i.test(candidate)) {
          svg = candidate;
        }
      }
    } catch (_) { }
    // Cache failures too: unsupported vendor resources must not trigger disk
    // reads on every frame. A new scene/root clears the small fixed cache.
    this.icons.set(name, svg);
    return svg ?? undefined;
  }

  /** Native Image.fillColor tints alpha, without changing masks or path geometry. */
  public static tint(svg: string, color: string | null): string {
    if (color === null || !/^#[0-9a-f]{8}$/i.test(color)) return svg;
    const start = svg.indexOf('>');
    const end = svg.lastIndexOf('</svg>');
    if (start < 0 || end <= start) return svg;
    const root = svg.substring(0, start + 1);
    const content = svg.substring(start + 1, end);
    return `${root}<defs><filter id="ft-replay-icon-tint" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB"><feFlood ${ReplayControlVectors.paint(color, 'flood-color').replace('flood-color-opacity', 'flood-opacity')}/><feComposite in2="SourceGraphic" operator="in"/></filter></defs><g filter="url(#ft-replay-icon-tint)">${content}</g></svg>`;
  }
}
