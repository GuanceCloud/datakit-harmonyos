import { ArkUIReplayLightNode } from './SessionReplayScene';
import { ReplayShapeWireframe, ReplayWireframe } from './SessionReplayProtocol';
import { ReplayControlVectors } from './ReplayControlVectors';

export interface ReplayWebViewClipMask {
  owner: ArkUIReplayLightNode;
  afterIndex: number;
  frame: ReplayShapeWireframe;
  svg: string;
}

interface ReplayClipSubtree {
  afterIndex: number;
  zIndex: number;
}

/** Flat mobile wireframes cannot inherit a native parent's rounded clip.
 * Restore its cut-out corners over a known opaque native backdrop using the
 * existing SVG asset protocol. No Web pixels or DOM content are captured.
 */
export class ReplayWebViewClipMasks {
  public static create(nodes: Array<ArkUIReplayLightNode>, frames: Array<ReplayWireframe>,
    sources: Map<number, ArkUIReplayLightNode>, limit: number): Array<ReplayWebViewClipMask> {
    if (limit <= 0 || !nodes.some((node): boolean => node.webViewSlotId !== undefined)) return [];
    const byId = new Map<number, ArkUIReplayLightNode>();
    const byFrameId = new Map<number, ReplayWireframe>();
    for (const node of nodes) byId.set(node.id, node);
    for (const frame of frames) byFrameId.set(frame.id, frame);
    const owners = new Set<number>();
    for (const node of nodes) {
      if (node.webViewSlotId === undefined || (node.opacity ?? 1) <= 0) continue;
      let parent = node.parentId;
      for (let depth = 0; parent !== undefined && depth < 64; depth++) {
        const ancestor = byId.get(parent);
        if (ancestor === undefined) break;
        if (ancestor.clipsChildren === true) owners.add(ancestor.id);
        parent = ancestor.parentId;
      }
    }
    if (owners.size === 0) return [];
    const subtrees = new Map<number, ReplayClipSubtree>();
    // Walk ancestry once per frame, rather than rescanning every subtree for
    // each rounded ancestor. All references remain detached scalar metadata.
    for (let index = 0; index < frames.length; index++) {
      let current = sources.get(frames[index].id);
      for (let depth = 0; current !== undefined && depth < 64; depth++) {
        if (owners.has(current.id)) {
          const previous = subtrees.get(current.id);
          subtrees.set(current.id, { afterIndex: index,
            zIndex: Math.max(previous?.zIndex ?? 0, frames[index].zIndex ?? 0) });
        }
        current = current.parentId === undefined ? undefined : byId.get(current.parentId);
      }
    }
    const result: Array<ReplayWebViewClipMask> = [];
    for (const id of owners) {
      if (result.length >= Math.min(32, limit)) break;
      const owner = byId.get(id)!;
      const frame = byFrameId.get(id);
      if (frame === undefined || frame.type === 'placeholder') continue;
      if (!ReplayWebViewClipMasks.hasUniformCorners(owner)) continue;
      const radius = Math.min(frame.shapeStyle?.cornerRadius ?? 0, frame.width / 2, frame.height / 2);
      if (!Number.isFinite(radius) || radius <= 0 || (owner.opacity ?? 1) <= 0 ||
        (owner.clip?.left ?? 0) + (owner.clip?.right ?? 0) >= owner.width ||
        (owner.clip?.top ?? 0) + (owner.clip?.bottom ?? 0) >= owner.height) continue;
      const color = ReplayWebViewClipMasks.backdrop(owner, byId, byFrameId);
      if (color === null) continue;
      const subtree = subtrees.get(id);
      if (subtree === undefined) continue;
      const template: ReplayShapeWireframe = {
        id: -(id * 1024 + 999), type: 'shape', x: frame.x, y: frame.y, width: frame.width, height: frame.height,
        permanentId: `ft-session-replay-web-clip:${id}`, clip: frame.clip,
        shapeStyle: { opacity: 1 }, zIndex: subtree.zIndex + 0.25
      };
      result.push({ owner, afterIndex: subtree.afterIndex, frame: template,
        svg: ReplayWebViewClipMasks.vector(frame.width, frame.height, radius, color) });
    }
    // Inner clips are discovered first. Stable sorting and reverse insertion
    // leave an outer clip above its nested clips at the same subtree boundary.
    result.sort((left, right): number => left.afterIndex - right.afterIndex);
    return result;
  }

  private static hasUniformCorners(node: ArkUIReplayLightNode): boolean {
    try {
      const info = node.inspectorInfo as Record<string, Object> | null;
      const attrs = (info?.['$attrs'] ?? info) as Record<string, Object> | null;
      const raw = attrs?.['borderRadius'];
      const radius = typeof raw === 'string' && raw.trim().startsWith('{') ? JSON.parse(raw) as Object : raw;
      if (radius === null || typeof radius !== 'object') return true;
      const corners = radius as Record<string, Object>;
      const values = ['topLeft', 'topRight', 'bottomRight', 'bottomLeft'].map((key): Object => corners[key]);
      return values.every((value): boolean => value !== undefined && String(value) === String(values[0]));
    } catch (_) { return false; }
  }

  private static backdrop(owner: ArkUIReplayLightNode, nodes: Map<number, ArkUIReplayLightNode>,
    frames: Map<number, ReplayWireframe>): string | null {
    let current = owner;
    for (let depth = 0; depth < 64; depth++) {
      const parent = current.parentId === undefined ? undefined : nodes.get(current.parentId);
      if (parent === undefined) {
        // The recorder models the native opaque Router Page separately.
        const backing = frames.get(-current.id);
        return backing?.type === 'shape' ? backing.shapeStyle?.backgroundColor ?? null : null;
      }
      const frame = frames.get(parent.id);
      if (frame !== undefined && frame.type !== 'placeholder') {
        if (frame.type === 'image' || frame.type === 'webview' || frame.shapeStyle?.backgroundGradient !== undefined ||
          (frame.shapeStyle?.opacity ?? 1) !== 1) return null;
        const color = frame.shapeStyle?.backgroundColor;
        if (color !== undefined && !(color.length === 9 && color.endsWith('00'))) {
          // Do not guess the backdrop behind translucent paint.
          return /^#[0-9a-f]{6}(ff)?$/i.test(color) ? color : null;
        }
      }
      current = parent;
    }
    return null;
  }

  public static vector(width: number, height: number, radius: number, color: string): string {
    const w = Math.round(width * 100) / 100;
    const h = Math.round(height * 100) / 100;
    const r = Math.round(Math.min(radius, w / 2, h / 2) * 100) / 100;
    // Even-odd fill paints only the four corners outside the rounded native
    // clip. The entire interior, including Browser Replay, stays transparent.
    const path = `M0 0H${w}V${h}H0Z` +
      `M${r} 0H${w-r}A${r} ${r} 0 0 1 ${w} ${r}V${h-r}` +
      `A${r} ${r} 0 0 1 ${w-r} ${h}H${r}A${r} ${r} 0 0 1 0 ${h-r}V${r}` +
      `A${r} ${r} 0 0 1 ${r} 0Z`;
    return ReplayControlVectors.document(w, h, `<path d="${path}" fill-rule="evenodd" fill="${color}"/>`);
  }
}
