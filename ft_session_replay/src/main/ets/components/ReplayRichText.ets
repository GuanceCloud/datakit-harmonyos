import { text } from '@kit.ArkGraphics2D';
import { readReplayFontWeight } from './ReplayFontWeight';
import { ArkUIReplayLightNode, ReplayInlineRun } from './SessionReplayScene';
import { ReplayShapeWireframe, ReplayTextStyle, ReplayTextWireframe, ReplayWireframe } from './SessionReplayProtocol';

interface HtmlRun { text: string; style: ReplayTextStyle; input: boolean; image?: ReplayInlineRun; }
interface HtmlBlock { runs: Array<HtmlRun>; margin: number; alignment: 'left' | 'center' | 'right'; }
interface HtmlContext { tag: string; style: ReplayTextStyle; hidden: boolean; input: boolean; alignment: 'left' | 'center' | 'right'; }
interface RichFragment { text: string; style: ReplayTextStyle; input: boolean; x: number; y: number; width: number; height: number; image?: ReplayInlineRun; }
interface RichLayoutCache { html: string; width: number; scale: number; fragments: Array<RichFragment>; }

function copyStyle(style: ReplayTextStyle): ReplayTextStyle {
  return { family: style.family, size: style.size, color: style.color, weight: style.weight,
    style: style.style, decoration: style.decoration, lineHeight: style.lineHeight, letterSpacing: style.letterSpacing };
}

/** Converts a bounded HTML typography subset into native-measured text, never executable HTML. */
export class ReplayRichText {
  private readonly cache: Map<number, RichLayoutCache> = new Map();
  private cacheChars: number = 0;

  public clear(): void { this.cache.clear(); this.cacheChars = 0; }
  public retain(ids: Set<number>): void {
    this.cache.forEach((entry: RichLayoutCache, id: number): void => {
      if (!ids.has(id)) { this.cacheChars -= entry.html.length; this.cache.delete(id); }
    });
  }

  public create(node: ArkUIReplayLightNode, html: string, scale: number,
    limit: number, filter: (value: string, input: boolean) => string): Array<ReplayTextWireframe> {
    if (limit <= 0 || html.length === 0 || html.length > 32768) return [];
    let cached = this.cache.get(node.id);
    if (cached === undefined || cached.html !== html || cached.width !== node.width || cached.scale !== scale) {
      const fragments = this.layout(this.parse(html), Math.max(1, node.width - 16), scale);
      this.cacheChars -= cached?.html.length ?? 0;
      cached = { html, width: node.width, scale, fragments };
      this.cache.set(node.id, cached);
      this.cacheChars += html.length;
      while (this.cache.size > 64 || this.cacheChars > 256 * 1024) {
        const first = this.cache.keys().next().value as number;
        this.cacheChars -= this.cache.get(first)?.html.length ?? 0;
        this.cache.delete(first);
      }
    }
    const result: Array<ReplayTextWireframe> = [];
    const left = node.x + (node.clip?.left ?? 0);
    const right = node.x + node.width - (node.clip?.right ?? 0);
    const top = node.y + (node.clip?.top ?? 0);
    const bottom = node.y + node.height - (node.clip?.bottom ?? 0);
    for (let index = 0; index < Math.min(limit, cached.fragments.length); index++) {
      const part = cached.fragments[index];
      const x = this.round(node.x + 8 + part.x);
      const y = this.round(node.y + 8 + part.y);
      const width = this.round(part.width);
      const height = this.round(part.height);
      result.push({ id: -(node.id * 1024 + index + 1), type: 'text', x, y, width, height,
        text: filter(part.text, part.input), textStyle: copyStyle(part.style),
        permanentId: node.componentId.length > 0 ? `${node.componentId}:html:${index}` : undefined,
        textPosition: { alignment: { horizontal: 'left', vertical: 'center' } },
        shapeStyle: { opacity: node.opacity ?? 1 },
        clip: { left: this.round(Math.min(width, Math.max(0, left - x))),
          right: this.round(Math.min(width, Math.max(0, x + width - right))),
          top: this.round(Math.min(height, Math.max(0, top - y))),
          bottom: this.round(Math.min(height, Math.max(0, y + height - bottom))) } });
    }
    return result;
  }

  /** Native spans use the same typography engine with media placeholders, rather than a Text screenshot. */
  public createNative(node: ArkUIReplayLightNode, scale: number, limit: number,
    filter: (value: string, input: boolean) => string,
    imageResolver: (source: string, frame: ReplayShapeWireframe) => ReplayWireframe,
    inheritedFontWeight?: number): Array<ReplayWireframe> {
    if (node.inlineRuns === undefined || limit <= 0) return [];
    const attrs = this.nativeAttrs(node.inspectorInfo);
    const base = this.nativeStyle(attrs, { family: 'sans-serif', size: 16, color: '#1F2937FF', weight: inheritedFontWeight ?? 400 }, scale);
    const alignment = String(attrs['textAlign'] ?? '').toUpperCase();
    const spanStyles = new Map<number, ReplayTextStyle>();
    const runs = node.inlineRuns.map((run): HtmlRun => {
      const parent = spanStyles.get(run.fontWeightParentId ?? 0) ?? base;
      const style = this.nativeStyle(this.nativeAttrs(run.inspectorInfo), parent, scale);
      spanStyles.set(run.id, style);
      return { text: run.text, style, input: node.nodeType === 'RichEditor', image: run.nodeType === 'Span' ? undefined : run };
    });
    const signature = `${base.weight}|${JSON.stringify(node.inspectorInfo)}|${JSON.stringify(node.inlineRuns)}`;
    if (signature.length > 65536) return [];
    let cached = this.cache.get(node.id);
    if (cached === undefined || cached.html !== signature || cached.width !== node.width || cached.scale !== scale) {
      const fragments = this.layout([{ runs, margin: 0,
        alignment: alignment.includes('CENTER') ? 'center' : alignment.includes('END') || alignment.includes('RIGHT') ? 'right' : 'left' }], node.width, scale);
      this.cacheChars -= cached?.html.length ?? 0;
      cached = { html: signature, width: node.width, scale, fragments };
      this.cache.set(node.id, cached);
      this.cacheChars += signature.length;
      while (this.cache.size > 64 || this.cacheChars > 256 * 1024) {
        const first = this.cache.keys().next().value as number;
        this.cacheChars -= this.cache.get(first)?.html.length ?? 0;
        this.cache.delete(first);
      }
    }
    const fragments = cached.fragments;
    const contentHeight = fragments.reduce((height, part): number => Math.max(height, part.y + part.height), 0);
    const offsetY = node.nodeType === 'Text' ? Math.max(0, (node.height - contentHeight) / 2) : 0;
    const result: Array<ReplayWireframe> = [];
    for (let index = 0; index < Math.min(256, limit, fragments.length); index++) {
      const part = fragments[index];
      const geometry: ReplayShapeWireframe = { id: -(node.id * 1024 + index + 1), type: 'shape',
        x: this.round(node.x + part.x), y: this.round(node.y + part.y + offsetY),
        width: this.round(part.width), height: this.round(part.height),
        permanentId: node.componentId.length > 0 ? `${node.componentId}:inline:${index}` : undefined,
        shapeStyle: { opacity: node.opacity ?? 1 } };
      geometry.clip = { left: this.round(Math.min(geometry.width, Math.max(0, node.x + (node.clip?.left ?? 0) - geometry.x))),
        right: this.round(Math.min(geometry.width, Math.max(0, geometry.x + geometry.width - node.x - node.width + (node.clip?.right ?? 0)))),
        top: this.round(Math.min(geometry.height, Math.max(0, node.y + (node.clip?.top ?? 0) - geometry.y))),
        bottom: this.round(Math.min(geometry.height, Math.max(0, geometry.y + geometry.height - node.y - node.height + (node.clip?.bottom ?? 0)))) };
      if (part.image !== undefined) {
        const imageAttrs = this.nativeAttrs(part.image.inspectorInfo);
        result.push(imageResolver(part.image.componentRasterKey ?? String(imageAttrs['src'] ?? ''), geometry));
      } else {
        const frame: ReplayTextWireframe = { id: geometry.id, type: 'text', x: geometry.x, y: geometry.y,
          width: geometry.width, height: geometry.height, permanentId: geometry.permanentId,
          clip: geometry.clip, shapeStyle: geometry.shapeStyle, text: filter(part.text, part.input),
          textStyle: part.style, textPosition: { alignment: { horizontal: 'left', vertical: 'center' } } };
        result.push(frame);
      }
    }
    return result;
  }

  private nativeAttrs(info: Object | null): Record<string, Object> {
    const object = (info ?? {}) as Record<string, Object>;
    return (object['$attrs'] ?? object) as Record<string, Object>;
  }

  private nativeStyle(attrs: Record<string, Object>, parent: ReplayTextStyle, scale: number): ReplayTextStyle {
    const style = copyStyle(parent);
    const length = (value: Object): number => parseFloat(String(value ?? '')) / (String(value).endsWith('px') ? scale : 1);
    const size = length(attrs['fontSize']);
    if (Number.isFinite(size) && size > 0) style.size = size;
    const height = length(attrs['lineHeight']);
    if (Number.isFinite(height) && height > 0) style.lineHeight = height;
    const spacing = length(attrs['letterSpacing']);
    if (Number.isFinite(spacing)) style.letterSpacing = spacing;
    const color = String(attrs['fontColor'] ?? '');
    if (/^#[0-9a-f]{8}$/i.test(color)) style.color = `#${color.substring(3)}${color.substring(1, 3)}`.toUpperCase();
    else if (/^#[0-9a-f]{6}$/i.test(color)) style.color = color.toUpperCase() + 'FF';
    const weight = readReplayFontWeight(attrs);
    if (weight !== null) style.weight = weight;
    if (String(attrs['fontStyle'] ?? '').toLowerCase().includes('italic')) style.style = 'italic';
    if (typeof attrs['fontFamily'] === 'string' && (attrs['fontFamily'] as string).length > 0) style.family = String(attrs['fontFamily']);
    return style;
  }

  private parse(html: string): Array<HtmlBlock> {
    const blocks: Array<HtmlBlock> = [];
    const base: HtmlContext = { tag: 'body', style: { family: 'serif', size: 16, color: '#000000FF', weight: 400 },
      hidden: false, input: false, alignment: 'left' };
    const stack: Array<HtmlContext> = [base];
    let current: HtmlBlock = { runs: [], margin: 0, alignment: 'left' };
    let pendingMargin = 0;
    let characters = 0;
    const flush = (): void => {
      if (current.runs.some((run: HtmlRun): boolean => run.text.trim().length > 0)) {
        blocks.push(current);
        current = { runs: [], margin: pendingMargin, alignment: stack[stack.length - 1].alignment };
      }
    };
    const tokens = /<!--[\s\S]*?-->|<![^>]*>|<[^>]*>|[^<]+/g;
    let token: RegExpExecArray | null = null;
    let count = 0;
    while ((token = tokens.exec(html)) !== null && count++ < 2048 && blocks.length < 64 && characters < 4096) {
      const value = token[0];
      let context = stack[stack.length - 1];
      if (value.startsWith('<!--') || value.startsWith('<!')) continue;
      if (!value.startsWith('<')) {
        if (context.hidden) continue;
        let content = this.entities(value).replace(/[ \t\r\n\f]+/g, ' ');
        if (current.runs.length === 0 || current.runs[current.runs.length - 1].text.endsWith(' ')) {
          content = content.replace(/^ +/, '');
        }
        content = content.substring(0, 4096 - characters);
        characters += content.length;
        if (content.length > 0) current.runs.push({ text: content, style: copyStyle(context.style), input: context.input });
        continue;
      }
      const tagMatch = /^<\s*(\/?)\s*([a-z0-9]+)/i.exec(value);
      if (tagMatch === null) continue;
      const closing = tagMatch[1] === '/';
      const tag = tagMatch[2].toLowerCase();
      const block = /^(p|div|section|article|li|ul|ol|h[1-6]|blockquote|pre)$/.test(tag);
      if (closing) {
        if (block && !context.hidden) {
          flush();
          if (tag === 'p') pendingMargin = Math.max(pendingMargin, context.style.size);
        }
        for (let index = stack.length - 1; index > 0; index--) {
          if (stack[index].tag === tag) { stack.splice(index); break; }
        }
        continue;
      }
      if (tag === 'br' && !context.hidden) {
        current.runs.push({ text: '\n', style: copyStyle(context.style), input: context.input });
        continue;
      }
      if (/^(img|input|meta|link|hr|source|wbr)$/.test(tag)) continue;
      if (stack.length >= 32) continue;
      const editable = /\scontenteditable(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/i.exec(value);
      const child: HtmlContext = { tag, style: copyStyle(context.style), alignment: context.alignment,
        input: context.input || tag === 'textarea' || (editable !== null &&
          (editable[1] ?? editable[2] ?? editable[3] ?? '').trim().toLowerCase() !== 'false'),
        hidden: context.hidden || /^(script|style|head|iframe|object|svg|noscript|template)$/.test(tag) };
      if (/^(b|strong|h[1-6])$/.test(tag)) child.style.weight = 700;
      if (/^(i|em)$/.test(tag)) child.style.style = 'italic';
      if (tag === 'u' || tag === 'a') child.style.decoration = 'underline';
      if (tag === 's' || tag === 'del') child.style.decoration = 'line-through';
      if (tag === 'a') child.style.color = '#0000EEFF';
      if (/^h[1-6]$/.test(tag)) child.style.size *= [2, 1.5, 1.17, 1, 0.83, 0.67][Number(tag[1]) - 1];
      const css = /\bstyle\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(value);
      if (css !== null) this.css(child, css[1] ?? css[2] ?? css[3] ?? '');
      if (block && !child.hidden) {
        flush();
        current.margin = Math.max(pendingMargin, tag === 'p' ? child.style.size : 0);
        current.alignment = child.alignment;
        pendingMargin = 0;
      }
      stack.push(child);
    }
    flush();
    return blocks;
  }

  private css(context: HtmlContext, css: string): void {
    const declarations = css.split(';').slice(0, 32);
    const parentSize = context.style.size;
    // Relative lengths use the inherited size, independent of declaration order.
    for (const declaration of declarations) {
      const colon = declaration.indexOf(':');
      if (colon < 0 || declaration.substring(0, colon).trim().toLowerCase() !== 'font-size') continue;
      context.style.size = this.length(declaration.substring(colon + 1).trim(), parentSize) ?? context.style.size;
    }
    context.style.size = Math.max(8, Math.min(128, context.style.size));
    for (const declaration of declarations) {
      const colon = declaration.indexOf(':');
      if (colon < 0) continue;
      const name = declaration.substring(0, colon).trim().toLowerCase();
      const value = declaration.substring(colon + 1).trim();
      if (name === 'color') context.style.color = this.color(value) ?? context.style.color;
      if (name === 'font-weight') {
        const weight = value === 'bold' || value === 'bolder' ? 700 : value === 'normal' ? 400 : Number(value);
        if (Number.isFinite(weight)) context.style.weight = Math.max(100, Math.min(900, Math.round(weight / 100) * 100));
      }
      if (name === 'font-style') context.style.style = value === 'italic' || value === 'oblique' ? 'italic' : 'normal';
      if (name === 'font-family') context.style.family = value.split(',')[0].replace(/["']/g, '').trim().substring(0, 128);
      if (name === 'line-height') {
        const number = Number(value);
        context.style.lineHeight = Number.isFinite(number) ? number * context.style.size : this.length(value, context.style.size) ?? undefined;
      }
      if (name === 'text-decoration') context.style.decoration = value.includes('line-through') ? 'line-through' :
        value.includes('underline') ? 'underline' : 'none';
      if (name === 'text-align' && /^(left|center|right)$/.test(value)) context.alignment = value as 'left' | 'center' | 'right';
      if ((name === 'display' && value === 'none') || (name === 'visibility' && value === 'hidden')) context.hidden = true;
    }
  }

  private layout(blocks: Array<HtmlBlock>, width: number, scale: number): Array<RichFragment> {
    const result: Array<RichFragment> = [];
    let y = 0;
    for (const block of blocks) {
      y += block.margin;
      const blockY = y;
      const blockStart = result.length;
      try {
        const builder = new text.ParagraphBuilder({ align: block.alignment === 'center' ? text.TextAlign.CENTER :
          block.alignment === 'right' ? text.TextAlign.RIGHT : text.TextAlign.LEFT }, text.FontCollection.getGlobalInstance());
        for (const run of block.runs) {
          builder.pushStyle({ fontSize: run.style.size * scale, fontFamilies: [run.style.family],
            letterSpacing: (run.style.letterSpacing ?? 0) * scale,
            fontWeight: (Math.round((run.style.weight ?? 400) / 100) - 1) as text.FontWeight,
            heightOnly: run.style.lineHeight !== undefined,
            heightScale: run.style.lineHeight === undefined ? undefined : run.style.lineHeight / run.style.size,
            fontStyle: run.style.style === 'italic' ? text.FontStyle.ITALIC : text.FontStyle.NORMAL });
          if (run.image !== undefined) builder.addPlaceholder({ width: (run.image.width ?? run.style.size) * scale,
            height: (run.image.height ?? run.style.size) * scale, align: text.PlaceholderAlignment.BOTTOM_OF_ROW_BOX,
            baseline: text.TextBaseline.ALPHABETIC, baselineOffset: 0 });
          else builder.addText(run.text);
          builder.popStyle();
        }
        const paragraph = builder.build();
        paragraph.layoutSync(width * scale);
        let position = 0;
        let imageIndex = 0;
        for (const run of block.runs) {
          if (run.image !== undefined) {
            const box = paragraph.getRectsForPlaceholders()[imageIndex++]?.rect;
            position++;
            if (box !== undefined) result.push({ text: '', style: run.style, input: run.input,
              x: box.left / scale, y: y + box.top / scale, width: (box.right - box.left) / scale,
              height: (box.bottom - box.top) / scale, image: run.image });
            continue;
          }
          let fragment: RichFragment | null = null;
          for (const char of run.text) {
            const boxes = paragraph.getRectsForRange({ start: position, end: position + char.length },
              text.RectWidthStyle.TIGHT, text.RectHeightStyle.TIGHT);
            position += char.length;
            if (char === '\n') { fragment = null; continue; }
            if (boxes.length === 0) continue;
            const rect = boxes[0].rect;
            const x = rect.left / scale;
            const top = rect.top / scale;
            const right = rect.right / scale;
            const bottom = rect.bottom / scale;
            if (fragment === null || Math.abs(fragment.y - y - top) > 0.5) {
              if (result.length >= 512) return result;
              fragment = { text: char, style: copyStyle(run.style), input: run.input, x, y: y + top,
                width: Math.max(0.1, right - x), height: Math.max(1, bottom - top) };
              result.push(fragment);
            } else {
              fragment.text += char;
              const previousRight = fragment.x + fragment.width;
              fragment.x = Math.min(fragment.x, x);
              fragment.width = Math.max(previousRight, right) - fragment.x;
            }
          }
        }
        y += paragraph.getHeight() / scale;
        // Local-test and older typography stubs may return no glyph boxes
        // without throwing. Preserve visible, privacy-filtered text just as we
        // do when the native typography module is unavailable altogether.
        if (result.length === blockStart && block.runs.length > 0) {
          if (block.runs.some((run): boolean => run.image !== undefined)) return [];
          y = this.appendFallbackBlock(block, width, blockY, result);
        }
      } catch (_) {
        if (block.runs.some((run): boolean => run.image !== undefined)) return [];
        y = this.appendFallbackBlock(block, width, blockY, result);
      }
    }
    return result;
  }

  /** Keeps text available when native paragraph geometry is unsupported. */
  private appendFallbackBlock(block: HtmlBlock, width: number, y: number, result: Array<RichFragment>): number {
    for (const run of block.runs) {
      const height = run.style.lineHeight ?? run.style.size * 1.2;
      result.push({ text: run.text, style: copyStyle(run.style), input: run.input, x: 0, y, width, height });
      y += height;
    }
    return y;
  }

  private length(value: string, parent: number): number | null {
    const match = /^([\d.]+)(px|vp|fp|em|rem|%|pt)?$/i.exec(value);
    if (match === null) return null;
    const number = Number(match[1]);
    return match[2] === 'em' ? number * parent : match[2] === 'rem' ? number * 16 :
      match[2] === '%' ? number * parent / 100 : match[2] === 'pt' ? number * 4 / 3 : number;
  }

  private color(value: string): string | null {
    const color = value.trim().toLowerCase();
    if (/^#[0-9a-f]{6}$/.test(color)) return color.toUpperCase() + 'FF';
    if (/^#[0-9a-f]{8}$/.test(color)) return color.toUpperCase();
    if (/^#[0-9a-f]{3,4}$/.test(color)) return '#' + color.substring(1).split('').map((part: string): string => part + part).join('').toUpperCase() +
      (color.length === 4 ? 'FF' : '');
    const names: Record<string, string> = { 'black': '#000000FF', 'white': '#FFFFFFFF', 'red': '#FF0000FF',
      'blue': '#0000FFFF', 'green': '#008000FF', 'gray': '#808080FF', 'grey': '#808080FF', 'transparent': '#00000000' };
    if (names[color] !== undefined) return names[color];
    const rgb = /^rgba?\(([^)]+)\)$/.exec(color);
    if (rgb === null) return null;
    const parts = rgb[1].split(',');
    if (parts.length < 3 || parts.length > 4) return null;
    let result = '#';
    for (let index = 0; index < 4; index++) {
      const raw = parts[index] ?? '1';
      const numeric = parseFloat(raw);
      if (!Number.isFinite(numeric)) return null;
      const value = index === 3 ? numeric * 255 : raw.includes('%') ? numeric * 2.55 : numeric;
      result += Math.round(Math.max(0, Math.min(255, value))).toString(16).padStart(2, '0');
    }
    return result.toUpperCase();
  }

  private entities(value: string): string {
    const names: Record<string, string> = { 'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': '\u00a0' };
    return value.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (whole: string, key: string): string => {
      if (!key.startsWith('#')) return names[key.toLowerCase()] ?? whole;
      const code = key[1].toLowerCase() === 'x' ? parseInt(key.substring(2), 16) : parseInt(key.substring(1), 10);
      return code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff) ? String.fromCodePoint(code) : '\ufffd';
    });
  }

  private round(value: number): number { return Math.round(value * 100) / 100; }
}
