import { ReplayControlVectors, ReplayVectorPoint, ReplayVectorStop } from './ReplayControlVectors';
import { ArkUIReplayLightNode } from './SessionReplayScene';
import { ReplayShapeWireframe, ReplayTextWireframe, ReplayWireframe } from './SessionReplayProtocol';

interface LoadingMotion { startedAt: number; enabled: boolean; }
interface SwitchMotion { from: number; to: number; startedAt: number; }
type ControlColorStop = ReplayVectorStop;
type ControlPoint = ReplayVectorPoint;
export type ReplayControlVectorResolver = (svg: string, frame: ReplayShapeWireframe) => ReplayWireframe;
export type ReplayControlImageResolver = (source: string, frame: ReplayShapeWireframe) => ReplayWireframe;
export interface ReplayControlMotion { value?: number; active: boolean; }

/** State uses mobile wireframes; analytic vectors cover paths the rectangle protocol cannot express. */
export class ReplayControlWireframes {
  private readonly switches: Map<number, SwitchMotion> = new Map();
  private readonly loading: Map<number, LoadingMotion> = new Map();

  public clear(): void { this.switches.clear(); this.loading.clear(); }

  public supports(type: string, info: Object | null): boolean {
    if (['Button', 'Checkbox', 'CheckboxGroup', 'Radio', 'Switch', 'SwitchCompat', 'Gauge', 'Rating', 'LoadingProgress'].includes(type)) return true;
    const attrs = this.attrs(info);
    if (type === 'Toggle' || type === 'Slider' || type === 'Progress') return true;
    if (type === 'DataPanel') return true;
    return false;
  }

  public sample(id: number, type: string, info: Object | null, timestamp: number, visible: boolean): ReplayControlMotion {
    const attrs = this.attrs(info);
    const loading = type === 'LoadingProgress' || (type === 'Progress' &&
      String(attrs['status'] ?? '').toUpperCase().includes('LOADING'));
    if (loading) {
      if (!visible) return { value: 0, active: false };
      const enabled = String(attrs['enableLoading'] ?? 'true') !== 'false' && String(attrs['enabled'] ?? 'true') !== 'false';
      let motion = this.loading.get(id);
      if (motion === undefined || motion.enabled !== enabled) {
        motion = { startedAt: timestamp, enabled };
        this.loading.set(id, motion);
        while (this.loading.size > 64) this.loading.delete(this.loading.keys().next().value as number);
      }
      return { value: enabled ? Math.max(0, timestamp - motion.startedAt) : 0, active: visible && enabled };
    }
    if (type !== 'Switch' && type !== 'SwitchCompat' && !(type === 'Toggle' && String(attrs['type']).includes('Switch'))) return { active: false };
    const target = this.on(attrs) ? 1 : 0;
    let motion = this.switches.get(id);
    if (motion === undefined) {
      motion = { from: target, to: target, startedAt: timestamp };
      this.switches.set(id, motion);
      while (this.switches.size > 64) this.switches.delete(this.switches.keys().next().value as number);
    } else if (target !== motion.to) {
      motion.from = this.interpolate(motion, timestamp);
      motion.to = target;
      motion.startedAt = timestamp;
    }
    const value = visible ? this.interpolate(motion, timestamp) : target;
    return { value, active: visible && Math.abs(value - target) > 0.001 };
  }

  /** State belongs to a named group, rather than to a global checkbox revision. */
  public groupStates(nodes: Array<ArkUIReplayLightNode>): Map<number, number> {
    const result = new Map<number, number>();
    for (const group of nodes) {
      if (group.nodeType !== 'CheckboxGroup') continue;
      const attrs = this.attrs(group.inspectorInfo);
      const name = this.groupName(attrs);
      const members = nodes.filter((node): boolean => node.nodeType === 'Checkbox' && node.sceneLayer === group.sceneLayer &&
        (name.length > 0 ? this.groupName(this.attrs(node.inspectorInfo)) === name :
          group.controlParentId !== undefined && node.controlParentId === group.controlParentId));
      const selected = members.filter((node): boolean => this.on(this.attrs(node.inspectorInfo))).length;
      result.set(group.id, members.length > 0 ? selected === 0 ? 0 : selected === members.length ? 1 : 0.5 :
        String(attrs['selectAll']) === 'true' ? 1 : 0);
    }
    return result;
  }

  public create(node: ArkUIReplayLightNode, scale: number, limit: number, groupState?: number, allowInputs: boolean = true, imageResolver?: ReplayControlImageResolver, vectorResolver?: ReplayControlVectorResolver): Array<ReplayWireframe> {
    if (limit <= 0 || (!node.isSelectArrow && !this.supports(node.nodeType, node.inspectorInfo))) return [];
    const attrs = this.attrs(node.inspectorInfo);
    const parts: Array<ReplayWireframe> = [];
    const shape = (name: string, x: number, y: number, width: number, height: number,
      color: string, radius: number = 0, opacity: number = 1, rotate?: number): ReplayShapeWireframe => {
      const frame: ReplayShapeWireframe = { id: -(node.id * 1024 + 513 + parts.length), type: 'shape',
        x: this.round(node.x + x), y: this.round(node.y + y), width: this.round(Math.max(0.01, width)),
        height: this.round(Math.max(0.01, height)),
        permanentId: node.componentId.length > 0 ? `${node.componentId}:control:${name}` : undefined,
        // The collector maps these local paint planes to integer protocol zIndex.
        zIndex: name === 'track' || name === 'box' || name === 'circle' ||
          name.startsWith('shadow:') || name.includes(':track') ? 0 : 1,
        shapeStyle: { backgroundColor: color, cornerRadius: this.round(Math.max(0, radius)),
          opacity: (node.opacity ?? 1) * opacity,
          transform: rotate === undefined ? undefined : { rotate } } };
      const left = node.x + (node.clip?.left ?? 0);
      const top = node.y + (node.clip?.top ?? 0);
      const right = node.x + node.width - (node.clip?.right ?? 0);
      const bottom = node.y + node.height - (node.clip?.bottom ?? 0);
      frame.clip = { left: this.round(Math.min(frame.width, Math.max(0, left - frame.x))),
        right: this.round(Math.min(frame.width, Math.max(0, frame.x + frame.width - right))),
        top: this.round(Math.min(frame.height, Math.max(0, top - frame.y))),
        bottom: this.round(Math.min(frame.height, Math.max(0, frame.y + frame.height - bottom))) };
      if (parts.length < Math.min(64, limit)) parts.push(frame);
      return frame;
    };
    const vector = (name: string, svg: string, opacity: number = 1): void => {
      const frame = shape(name, 0, 0, node.width, node.height, '#00000000', 0, opacity);
      const slot = parts.indexOf(frame);
      if (slot >= 0 && vectorResolver !== undefined) parts[slot] = vectorResolver(svg, frame);
    };
    const staticImage = (source: Object, frame: ReplayShapeWireframe): void => {
      if (imageResolver === undefined || typeof source !== 'string' || source.trim().length === 0) return;
      const slot = parts.indexOf(frame);
      if (slot >= 0) parts[slot] = imageResolver(source.trim(), frame);
    };
    const line = (name: string, x1: number, y1: number, x2: number, y2: number, stroke: number,
      color: string, opacity: number = 1): void => {
      if (Math.abs(y2 - y1) < 0.001) {
        shape(`${name}:0`, Math.min(x1, x2) - stroke / 2, y1 - stroke / 2,
          Math.abs(x2 - x1) + stroke, stroke, color, stroke / 2, opacity);
        return;
      }
      if (Math.abs(x2 - x1) < 0.001) {
        shape(`${name}:0`, x1 - stroke / 2, Math.min(y1, y2) - stroke / 2,
          stroke, Math.abs(y2 - y1) + stroke, color, stroke / 2, opacity);
        return;
      }
      // Disjoint strips avoid alpha accumulation and keep diagonal marks bounded.
      const length = Math.hypot(x2 - x1, y2 - y1);
      const nx = -(y2 - y1) / length * stroke / 2;
      const ny = (x2 - x1) / length * stroke / 2;
      const polygon: Array<ControlPoint> = [{ x: x1 + nx, y: y1 + ny }, { x: x2 + nx, y: y2 + ny },
        { x: x2 - nx, y: y2 - ny }, { x: x1 - nx, y: y1 - ny }];
      const top = Math.min(...polygon.map((point): number => point.y));
      const height = Math.max(...polygon.map((point): number => point.y)) - top;
      for (let index = 0; index < 10; index++) {
        const y = top + height * index / 10;
        const span = this.polygonSpan(polygon, y + height / 20);
        shape(`${name}:${index}`, span[0], y, span[1] - span[0], height / 10, color, 0, opacity);
      }
    };
    const arc = (name: string, start: number, sweep: number, stroke: number,
      stops: Array<ControlColorStop>, filled: number = 1, background?: string): void => {
      const outer = Math.min(node.width, node.height) / 2;
      const extent = Math.max(0, Math.min(360, sweep * filled));
      if (background !== undefined) {
        const track = shape(`${name}:track`, node.width / 2 - outer, node.height / 2 - outer,
          outer * 2, outer * 2, '#00000000', outer);
        track.border = { color: background, width: stroke };
      }
      vector(`${name}:fill`, ReplayControlVectors.arc(node.width, node.height, start, extent, stroke, stops), extent > 0 ? 1 : 0);
    };
    const selected = this.color(attrs['selectedColor'], '#0A59F7FF');
    const type = node.nodeType;
    const toggleType = String(attrs['type'] ?? '');
    if (node.isSelectArrow) {
      const symbolColors = this.array(attrs['symbolColor'] ?? attrs['symbolColorList'] ?? attrs['fontColor']);
      const color = this.color(symbolColors[0] ?? attrs['symbolColor'] ?? attrs['fontColor'] ?? attrs['color'], '#1F2937FF');
      for (let index = 0; index < 8; index++) {
        const width = node.width * 0.92 * (1 - index / 8);
        shape(`arrow:${index}`, (node.width - width) / 2, node.height * (0.32 + index * 0.42 / 8),
          width, node.height * 0.42 / 8, color);
      }
      return parts;
    }
    if (type === 'Button' || (type === 'Toggle' && toggleType.includes('Button'))) return [];
    if (type === 'Switch' || type === 'SwitchCompat' || (type === 'Toggle' && toggleType.includes('Switch'))) {
      const state = allowInputs ? node.controlState ?? (this.on(attrs) ? 1 : 0) : 0;
      // Inspector serializes an unset optional switch colour as opaque black.
      // ArkUI's painted default is TMP_INACTIVE_COLOR, not that sentinel.
      const inactive = this.color(attrs['unselectedColor'], '#7F7F7F33');
      const unselected = inactive === '#000000FF' ? '#7F7F7F33' : inactive;
      const track = this.blend(unselected, selected, state);
      shape('track', 0, 0, node.width, node.height, track,
        this.length(attrs['trackBorderRadius'], scale, node.height / 2));
      const diameter = this.length(attrs['pointRadius'], scale, Math.max(0.5, node.height / 2 - 2)) * 2;
      const inset = (node.height - diameter) / 2;
      shape('thumb', inset + state * Math.max(0, node.width - node.height), inset, diameter, diameter,
        this.color(attrs['switchPointColor'], '#FFFFFFFF'), diameter / 2);
    } else if (type === 'Checkbox' || type === 'CheckboxGroup' || (type === 'Toggle' && toggleType.includes('Checkbox'))) {
      const state = allowInputs ? type === 'CheckboxGroup' ? groupState ?? 0 : this.on(attrs) ? 1 : 0 : 0;
      const radius = String(attrs['checkboxShape'] ?? '0') === '1' ? Math.min(4, node.height / 4) : node.height / 2;
      const box = shape('box', 0, 0, node.width, node.height, state > 0 ? selected : '#FFFFFF33', radius);
      // Keep the border present in every state: removing it forces a remove/add
      // mutation, which can append the opaque background above retained marks.
      box.border = { color: state > 0 ? selected : this.color(attrs['unselectedColor'], '#00000066'), width: 1 };
      const mark = this.object(attrs['mark']);
      const color = this.color(mark['strokeColor'], '#FFFFFFFF');
      const stroke = this.length(mark['strokeWidth'], scale, 2);
      const configuredSize = this.length(mark['size'], scale, 0);
      const size = configuredSize > 0 ? Math.min(configuredSize, node.width, node.height) : Math.min(node.width, node.height);
      const mx = (node.width - size) / 2;
      const my = (node.height - size) / 2;
      line('check:0', mx + size * 0.25, my + size * 0.49, mx + size * 0.44, my + size * 0.68, stroke, color, state === 1 ? 1 : 0);
      line('check:1', mx + size * 0.44, my + size * 0.68, mx + size * 0.76, my + size * 0.33, stroke, color, state === 1 ? 1 : 0);
      line('partial', node.width * 0.25, node.height / 2, node.width * 0.75, node.height / 2, stroke, color, state === 0.5 ? 1 : 0);
    } else if (type === 'Radio') {
      const checked = allowInputs && String(attrs['checked']) === 'true';
      const style = this.object(attrs['radioStyle']);
      const circle = shape('circle', 0, 0, node.width, node.height,
        checked ? this.color(style['checkedBackgroundColor'], selected) : '#FFFFFF33', node.height / 2);
      circle.border = { color: checked ? this.color(style['checkedBackgroundColor'], selected) :
        this.color(style['uncheckedBorderColor'], '#00000066'), width: 1 };
      const indicatorType = String(attrs['indicatorType'] ?? 'TICK').toUpperCase();
      const tick = indicatorType.includes('TICK');
      const circular = indicatorType.includes('DOT') || indicatorType.includes('CIRCLE');
      const indicator = this.color(style['indicatorColor'], '#FFFFFFFF');
      const diameter = node.height * 0.4;
      shape('indicator', (node.width - diameter) / 2, (node.height - diameter) / 2, diameter, diameter,
        indicator, diameter / 2, checked && circular ? 1 : 0);
      line('check:0', node.width * 0.25, node.height * 0.52, node.width * 0.44, node.height * 0.70, 2, indicator, checked && tick ? 1 : 0);
      line('check:1', node.width * 0.44, node.height * 0.70, node.width * 0.76, node.height * 0.35, 2, indicator, checked && tick ? 1 : 0);
    } else if (type === 'Slider') {
      const options = this.object(attrs['constructor']);
      const min = this.number(options['min'] ?? attrs['min'], 0);
      const max = this.number(options['max'] ?? attrs['max'], 100);
      const value = this.number(options['value'] ?? attrs['value'], min);
      const reverse = String(options['reverse'] ?? attrs['reverse']) === 'true';
      const ratio = allowInputs ? this.ratio(value - min, max - min) : 0;
      const position = reverse ? 1 - ratio : ratio;
      const vertical = String(options['direction'] ?? attrs['direction']).toUpperCase().includes('VERTICAL');
      const block = this.object(attrs['blockSize']);
      const blockStyle = this.object(attrs['blockStyle']);
      const blockSource = attrs['blockImage'] ?? attrs['blockImageSource'] ?? blockStyle['image'] ?? blockStyle['src'];
      const diameter = this.length(block['width'], scale, 16);
      const stroke = this.length(attrs['trackThickness'], scale, 4);
      const extent = (vertical ? node.height : node.width) - diameter;
      const point = diameter / 2 + position * Math.max(0, extent);
      const track = this.color(attrs['trackColor'], '#0A59F733');
      const fill = this.color(attrs['selectedColor'], selected);
      if (vertical) {
        shape('track', (node.width - stroke) / 2, diameter / 2, stroke, extent, track, stroke / 2);
        shape('fill', (node.width - stroke) / 2, reverse ? point : diameter / 2, stroke, ratio * extent, fill, stroke / 2);
        const thumb = shape('thumb', (node.width - diameter) / 2, point - diameter / 2, diameter, diameter,
          this.color(attrs['blockColor'], '#FFFFFFFF'), diameter / 2);
        staticImage(blockSource, thumb);
      } else {
        shape('track', diameter / 2, (node.height - stroke) / 2, extent, stroke, track, stroke / 2);
        shape('fill', reverse ? point : diameter / 2, (node.height - stroke) / 2, ratio * extent, stroke, fill, stroke / 2);
        const thumb = shape('thumb', point - diameter / 2, (node.height - diameter) / 2, diameter, diameter,
          this.color(attrs['blockColor'], '#FFFFFFFF'), diameter / 2);
        const border = this.length(attrs['blockBorderWidth'], scale, 0);
        if (border > 0) thumb.border = { width: border, color: this.color(attrs['blockBorderColor'], '#00000000') };
        staticImage(blockSource, thumb);
      }
    } else if (type === 'Rating') {
      const options = this.object(attrs['constructor']);
      const stars = Math.max(1, Math.min(10, Math.floor(this.number(attrs['stars'], 5))));
      const rating = allowInputs ? Math.max(0, Math.min(stars, this.number(attrs['rating'] ?? options['rating'], 0))) : 0;
      const starStyle = this.object(attrs['starStyle']);
      const foregroundSource = starStyle['foregroundUri'] ?? attrs['foregroundImageSourceInfo'];
      const backgroundSource = starStyle['backgroundUri'] ?? attrs['backgroundImageSourceInfo'];
      const secondarySource = starStyle['secondaryUri'] ?? attrs['secondaryImageSourceInfo'] ?? backgroundSource;
      if (imageResolver !== undefined && typeof foregroundSource === 'string' && foregroundSource.trim().length > 0 &&
        typeof backgroundSource === 'string' && backgroundSource.trim().length > 0) {
        const width = node.width / stars;
        for (let star = 0; star < stars; star++) {
          const amount = Math.max(0, Math.min(1, rating - star));
          const background = shape(`star:${star}:track`, star * width, 0, width, node.height, '#00000000');
          staticImage(amount > 0 && amount < 1 ? secondarySource : backgroundSource, background);
          const foreground = shape(`star:${star}:fill`, star * width, 0, width, node.height, '#00000000', 0, amount > 0 ? 1 : 0);
          foreground.clip!.right = Math.max(foreground.clip!.right ?? 0, this.round(width * (1 - amount)));
          staticImage(foregroundSource, foreground);
        }
        return parts;
      }
      const width = node.width / stars;
      const glyph = (name: string, star: number, color: string, opacity: number): ReplayTextWireframe => {
        const geometry = shape(name, star * width, 0, width, node.height, '#00000000', 0, opacity);
        const frame: ReplayTextWireframe = { id: geometry.id, type: 'text', x: geometry.x, y: geometry.y,
          width: geometry.width, height: geometry.height, permanentId: geometry.permanentId,
          zIndex: geometry.zIndex, clip: geometry.clip, shapeStyle: geometry.shapeStyle,
          text: '★', textStyle: { family: 'sans-serif', size: Math.min(width, node.height) * 1.15, color },
          textPosition: { alignment: { horizontal: 'center', vertical: 'center' } } };
        const slot = parts.indexOf(geometry);
        if (slot >= 0) parts[slot] = frame;
        return frame;
      };
      for (let star = 0; star < stars; star++) {
        const amount = Math.max(0, Math.min(1, rating - star));
        glyph(`star:${star}:track`, star, '#00000033', 1);
        const foreground = glyph(`star:${star}:fill`, star, this.color(attrs['color'], '#F7CE00FF'), amount > 0 ? 1 : 0);
        foreground.clip!.right = Math.max(foreground.clip!.right ?? 0, this.round(width * (1 - amount)));
      }
    } else if (type === 'LoadingProgress') {
      const diameter = Math.min(node.width, node.height);
      const radius = diameter * 10.5 / 40;
      const orbitRadius = diameter * 17 / 40;
      const stroke = this.loadingMetric(diameter, [1.12, 1.5, 1.76, 1.9, 2.16, 2.28]);
      const comet = this.loadingMetric(diameter, [1.2, 1.8, 2.4, 3, 3.36, 4.18]);
      const color = this.color(attrs['color'], '#00000099');
      const phase = (node.controlState ?? 0) / 1200 * Math.PI * 2;
      const enabled = String(attrs['enableLoading'] ?? 'true') !== 'false';
      const track = shape('loading:track', node.width / 2 - radius, node.height / 2 - radius,
        radius * 2, radius * 2, '#00000000', radius, enabled ? 0.78 : 0);
      track.border = { color, width: stroke };
      // ArkUI uses a twenty-point comet and a 1200 ms cycle, not periodic screenshots.
      for (let point = 0; point < 20; point++) {
        const angle = phase - point * Math.PI / 60;
        const dot = comet * 0.825 * 2;
        const x = Math.cos(angle) * orbitRadius;
        const y = Math.sin(angle) * orbitRadius * 0.55;
        const rotation = 22 * Math.PI / 180;
        shape(`loading:comet:${point}`, node.width / 2 + x * Math.cos(rotation) - y * Math.sin(rotation) - dot / 2,
          node.height / 2 + x * Math.sin(rotation) + y * Math.cos(rotation) - dot / 2,
          dot, dot, color, dot / 2, enabled ? 0.7 * Math.pow(0.82, point) : 0);
      }
    } else if (type === 'Progress') {
      const loading = String(attrs['status'] ?? '').toUpperCase().includes('LOADING');
      const elapsed = node.controlState ?? 0;
      const ratio = loading ? 0.25 + 0.15 * Math.sin(elapsed / 1200 * Math.PI * 2) :
        this.ratio(this.number(attrs['value'], 0), this.number(attrs['total'], 100));
      const stroke = String(attrs['type']).includes('Capsule') ? node.height : this.length(attrs['strokeWidth'], scale, 4);
      const color = this.color(attrs['color'], '#007DFFFF');
      const background = this.color(attrs['backgroundColor'], '#00000019');
      if (String(attrs['type']).includes('Ring')) {
        const stops = this.colorStops(attrs['progressGradientColor']);
        arc('ring', loading ? elapsed / 1200 * 360 : 0, 360, stroke, stops.length > 0 ? stops : [{ color, offset: 0 }], ratio, background);
      }
      else {
        const capsule = String(attrs['type']).includes('Capsule');
        const radius = capsule ? stroke / 2 : this.length(this.object(attrs['linearStyle'])['strokeRadius'], scale, stroke / 2);
        const vertical = !capsule && node.height > node.width;
        const length = vertical ? node.height : node.width;
        const filled = capsule ? length * ratio : Math.min(length, Math.max(0, length - radius * 2) * ratio + radius * 2);
        if (vertical) {
          shape('track', (node.width - stroke) / 2, 0, stroke, node.height, background, radius);
          shape('fill', (node.width - stroke) / 2, 0, stroke, filled, color, radius, ratio > 0 ? 1 : 0);
        } else {
          const rtl = String(attrs['direction'] ?? '').toUpperCase().includes('RTL');
          shape('track', 0, (node.height - stroke) / 2, node.width, stroke, background, radius);
          shape('fill', rtl ? node.width - filled : 0, (node.height - stroke) / 2, filled, stroke, color, radius, ratio > 0 ? 1 : 0);
        }
        // Progress's Inspector exposes ring gradient defaults for Linear too.
        // The linear paint method uses the resolved solid colour instead.
      }
    } else if (type === 'Gauge') {
      const start = this.number(attrs['startAngle'], 0);
      const rawSweep = this.number(attrs['endAngle'], 360) - start;
      const sweep = this.normalAngle(rawSweep) || 360;
      const stroke = this.length(attrs['strokeWidth'], scale, 4);
      const stops = this.gaugeStops(attrs['colors']);
      const outer = Math.min(node.width, node.height) / 2;
      const radius = Math.max(1, outer - stroke / 2);
      const shadow = this.object(attrs['trackShadow']);
      const blur = this.number(shadow['radius'], 20) / scale;
      if (blur > 0) {
        const ox = this.number(shadow['offsetX'], 5) / scale;
        const oy = this.number(shadow['offsetY'], 5) / scale;
        vector('shadow:track', ReplayControlVectors.shadow(
          ReplayControlVectors.arc(node.width, node.height, start, sweep, stroke, stops), node.width, node.height, blur, ox, oy));

      }
      const offset = Math.asin(Math.min(1, stroke / (2 * radius))) * 180 / Math.PI;
      arc('scale', start + offset, Math.max(0, sweep - offset * 2), stroke, stops);
      const min = this.number(attrs['min'], 0);
      const ratio = this.ratio(this.number(attrs['value'], min) - min, this.number(attrs['max'], 100) - min);
      const angle = (start + ratio * sweep - 90) * Math.PI / 180;
      const indicator = this.object(attrs['indicator']);
      if (attrs['indicator'] !== 'null') {
        const space = this.length(indicator['space'], scale, 8);
        const top = -outer + Math.min(space, outer) - outer * 0.015;
        const points: Array<ControlPoint> = [{ x: 0, y: top },
          { x: -outer * 0.135, y: top + outer * 0.174 }, { x: outer * 0.135, y: top + outer * 0.174 }];
        const rotate = (point: ControlPoint): ControlPoint => ({
          x: node.width / 2 + point.x * Math.cos(angle + Math.PI / 2) - point.y * Math.sin(angle + Math.PI / 2),
          y: node.height / 2 + point.x * Math.sin(angle + Math.PI / 2) + point.y * Math.cos(angle + Math.PI / 2) });
        vector('indicator:1:vector', ReplayControlVectors.document(node.width, node.height,
          ReplayControlVectors.polygon(this.expandTriangle(points, outer * 0.03).map(rotate), '#FFFFFFFF') +
          ReplayControlVectors.polygon(points.map(rotate), '#000000FF')));

      }
    } else if (type === 'DataPanel') {
      const values = this.values(attrs);
      const total = this.number(attrs['max'], values.reduce((sum, value): number => sum + value, 0));
      const palettes = this.array(attrs['valueColors']);
      const radius = this.length(attrs['borderRadius'], scale, 4);
      if (!String(attrs['type'] ?? 'Line').includes('Line')) {
        const stops: Array<ControlColorStop> = [];
        let offset = 0;
        values.forEach((value, index): void => {
          const amount = Math.min(1 - offset, this.ratio(value, total));
          const palette = this.colorStops(palettes[index]);
          const colors: Array<ControlColorStop> = palette.length > 0 ? palette : [{ color: ['#F7CE00FF', '#F76223FF', '#F772ACFF'][index % 3], offset: 0 }];
          for (const stop of colors) stops.push({ color: stop.color, offset: offset + stop.offset * amount });
          stops.push({ color: colors[colors.length - 1].color, offset: offset + amount });
          offset += amount;
        });
        const filled = Math.min(1, values.reduce((sum, value): number => sum + value, 0) / Math.max(1, total));
        const normalized = stops.map((stop): ControlColorStop => ({ color: stop.color, offset: filled > 0 ? stop.offset / filled : 0 }));
        arc('panel', 0, 360, this.length(attrs['strokeWidth'], scale, 12),
          normalized.length > 0 ? normalized : [{ color: selected, offset: 0 } as ControlColorStop], filled,
          this.color(attrs['trackBackgroundColor'], '#00000008'));
        return parts;
      }
      shape('track', 0, 0, node.width, node.height, this.color(attrs['trackBackgroundColor'], '#00000008'), radius);
      let sum = 0; let gaps = 0;
      for (const value of values) {
        if (value <= 0) continue;
        sum += value;
        if (sum >= total) break;
        gaps++;
      }
      const available = Math.max(0, node.width - gaps);
      let offset = 0; let definitions = ''; let segments = '';
      values.forEach((value, index): void => {
        const width = Math.max(0, Math.min(node.width - offset, available * this.ratio(value, total)));
        const stops = this.colorStops(palettes[index]);
        const id = `value${index}`;
        definitions += ReplayControlVectors.gradient(id, stops.length > 0 ? stops :
          [{ color: ['#F7CE00FF', '#F76223FF', '#F772ACFF'][index % 3], offset: 0 }]);
        segments += `<rect x="${this.round(offset)}" width="${this.round(width)}" height="${node.height}" fill="url(#${id})"/>`;
        offset += width > 0 ? width + 1 : 0;
      });
      vector('values', ReplayControlVectors.document(node.width, node.height,
        `<defs>${definitions}<clipPath id="panel"><rect width="${node.width}" height="${node.height}" rx="${radius}"/></clipPath></defs><g clip-path="url(#panel)">${segments}</g>`));

    }
    return parts;
  }

  public attrs(info: Object | null): Record<string, Object> {
    const object = (info ?? {}) as Record<string, Object>;
    return (object['$attrs'] ?? object) as Record<string, Object>;
  }
  private object(value: Object): Record<string, Object> {
    if (typeof value === 'string' && value.length <= 8192) {
      try { return this.object(JSON.parse(value) as Object); } catch (_) { return {}; }
    }
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, Object> : {};
  }
  private array(value: Object): Array<Object> {
    if (typeof value === 'string' && value.length <= 8192) {
      try { return this.array(JSON.parse(value) as Object); } catch (_) { return []; }
    }
    return Array.isArray(value) ? value as Array<Object> : [];
  }
  private values(attrs: Record<string, Object>): Array<number> {
    return this.array(attrs['values'] ?? attrs['dataPanelValues']).slice(0, 9)
      .map((value): number => this.number(typeof value === 'object' ? this.object(value)['value'] : value, 0));
  }
  private groupName(attrs: Record<string, Object>): string {
    const value = attrs['group'] ?? this.object(attrs['constructor'])['group'];
    return typeof value === 'string' ? value : '';
  }
  private on(attrs: Record<string, Object>): boolean {
    return String(attrs['select'] ?? attrs['isOn'] ?? attrs['checked'] ?? 'false') === 'true';
  }
  private number(value: Object, fallback: number): number {
    const number = Number(value);
    return Number.isFinite(number) ? number : fallback;
  }
  private length(value: Object, scale: number, fallback: number): number {
    const match = /^(-?[\d.]+)(px|vp|fp)?$/i.exec(String(value ?? ''));
    return match === null ? fallback : Math.max(0, Number(match[1]) / (match[2] === 'px' ? scale : 1));
  }
  private color(value: Object, fallback: string): string {
    const text = String(value ?? '').toUpperCase();
    if (/^#[0-9A-F]{8}$/.test(text)) return `#${text.substring(3)}${text.substring(1, 3)}`;
    if (/^#[0-9A-F]{6}$/.test(text)) return `${text}FF`;
    return fallback;
  }
  private blend(from: string, to: string, progress: number): string {
    let result = '#';
    for (let index = 1; index < 9; index += 2) {
      result += Math.round(parseInt(from.substring(index, index + 2), 16) * (1 - progress) +
        parseInt(to.substring(index, index + 2), 16) * progress).toString(16).padStart(2, '0');
    }
    return result.toUpperCase();
  }
  private colorStops(value: Object): Array<ControlColorStop> {
    return this.array(value).slice(0, 9).map((entry, index): ControlColorStop => {
      const object = this.object(entry);
      const pair = this.array(entry);
      return { color: this.color(object['color'] ?? pair[0] ?? entry, '#0A59F7FF'),
        offset: this.number(object['offset'] ?? pair[1], index) };
    }).sort((a, b): number => a.offset - b.offset);
  }
  private gaugeStops(value: Object): Array<ControlColorStop> {
    const entries = this.array(value);
    if (entries.length === 0) return [{ color: '#64BB5CFF', offset: 0 },
      { color: '#F7CE00FF', offset: 0.5 }, { color: '#E84026FF', offset: 1 }];
    if (typeof entries[0] === 'string') return entries.map((entry, index): ControlColorStop => ({
      color: this.color(entry, '#64BB5CFF'), offset: index / Math.max(1, entries.length - 1) }));
    const first = this.array(entries[0]);
    if (!Array.isArray(first[0])) return this.colorStops(entries);
    let total = 0;
    for (const entry of entries) total += this.number(this.array(entry)[1], 1);
    let position = 0;
    const stops: Array<ControlColorStop> = [];
    for (const entry of entries.slice(0, 9)) {
      const segment = this.array(entry);
      const weight = this.ratio(this.number(segment[1], 1), total);
      for (const stop of this.colorStops(segment[0])) stops.push({ color: stop.color, offset: position + stop.offset * weight });
      position += weight;
    }
    return stops;
  }
  private stopColor(stops: Array<ControlColorStop>, progress: number): string {
    if (stops.length === 0) return '#0A59F7FF';
    if (progress <= stops[0].offset) return stops[0].color;
    for (let index = 1; index < stops.length; index++) {
      const before = stops[index - 1];
      const after = stops[index];
      if (progress <= after.offset) return this.blend(before.color, after.color,
        this.ratio(progress - before.offset, after.offset - before.offset));
    }
    return stops[stops.length - 1].color;
  }
  private normalAngle(value: number): number { return ((value % 360) + 360) % 360; }
  private loadingMetric(diameter: number, values: Array<number>): number {
    const sizes = [16, 24, 32, 40, 48, 76];
    if (diameter <= sizes[0]) return values[0] * diameter / sizes[0];
    for (let index = 1; index < sizes.length; index++) {
      if (diameter <= sizes[index]) return values[index - 1] + (values[index] - values[index - 1]) *
        (diameter - sizes[index - 1]) / (sizes[index] - sizes[index - 1]);
    }
    return values[values.length - 1] * diameter / sizes[sizes.length - 1];
  }

  private polygonSpan(points: Array<ControlPoint>, y: number): Array<number> {
    const crossings: Array<number> = [];
    for (let index = 0; index < points.length; index++) {
      const a = points[index];
      const b = points[(index + 1) % points.length];
      if ((a.y <= y && b.y > y) || (b.y <= y && a.y > y)) crossings.push(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y));
    }
    return crossings.length > 0 ? [Math.min(...crossings), Math.max(...crossings)] : [0, 0];
  }
  private expandTriangle(points: Array<ControlPoint>, border: number): Array<ControlPoint> {
    return points.map((point, index): ControlPoint => {
      const before = points[(index + 2) % 3];
      const after = points[(index + 1) % 3];
      const ax = point.x - before.x;
      const ay = point.y - before.y;
      const bx = after.x - point.x;
      const by = after.y - point.y;
      const a = Math.hypot(ax, ay);
      const b = Math.hypot(bx, by);
      const px = point.x - ay / a * border;
      const py = point.y + ax / a * border;
      const qx = point.x - by / b * border;
      const qy = point.y + bx / b * border;
      const t = ((qx - px) * by - (qy - py) * bx) / (ax * by - ay * bx);
      return { x: px + ax * t, y: py + ay * t };
    });
  }
  private interpolate(motion: SwitchMotion, time: number): number {
    const progress = Math.max(0, Math.min(1, (time - motion.startedAt) / 200));
    return motion.from + (motion.to - motion.from) * (1 - Math.pow(1 - progress, 3));
  }
  private ratio(value: number, total: number): number { return total > 0 ? Math.max(0, Math.min(1, value / total)) : 0; }
  private round(value: number): number { return Math.round(value * 100) / 100; }
}
