import { ArkUIReplayLightNode } from './SessionReplayScene';
import { ReplayTextWireframe, ReplayWireframe } from './SessionReplayProtocol';

/** Player-neutral presentation: the existing mobile player needs no video protocol. */
export class ReplayVideoWireframes {
  public static create(node: ArkUIReplayLightNode, limit: number): Array<ReplayWireframe> {
    const state = node.videoState;
    if (state === undefined || limit <= 0) return [];
    const clock = (seconds: number): string => {
      const value = Math.floor(Math.max(0, seconds));
      return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, '0')}`;
    };
    const status = state.buffering === true ? 'Buffering' : state.playing === true ? 'Playing' : 'Paused';
    const label: ReplayTextWireframe = {
      id: -(node.id * 1024 + 1000), type: 'text', x: node.x, y: node.y + Math.max(0, node.height - 28),
      width: node.width, height: Math.min(28, node.height),
      permanentId: node.componentId.length > 0 ? `${node.componentId}:video:state` : undefined,
      text: `${status}  ${clock(state.currentTime ?? 0)} / ${clock(state.duration ?? 0)}${state.muted === true ? '  Muted' : ''}`,
      textStyle: { family: 'sans-serif', size: 12, color: '#FFFFFFFF' },
      shapeStyle: { backgroundColor: '#000000B3', opacity: node.opacity ?? 1 },
      clip: { left: node.clip?.left ?? 0, right: node.clip?.right ?? 0,
        top: Math.max(0, (node.clip?.top ?? 0) - Math.max(0, node.height - 28)), bottom: node.clip?.bottom ?? 0 }
    };
    return [label];
  }
}
