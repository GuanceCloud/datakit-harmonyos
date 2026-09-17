import { FrameNode, UIContext } from '@kit.ArkUI';
import {
  FullSnapshotData,
  ReplayRecordType,
  ReplayWireframe,
  SessionReplayRecord
} from './SessionReplayProtocol';

/**
 * Captures a privacy-safe structural snapshot from a registered ArkUI root.
 *
 * `FrameNode` reads are available from API 12. We intentionally do not access
 * `getInspectorInfo()`: its contents may carry application text or data and it
 * is not a stable production recording API.
 */
export class ArkUIReplayCollector {
  private readonly maxNodes: number;
  private rootEpoch: number = 1;

  constructor(maxNodes: number = 1500) {
    this.maxNodes = Math.max(1, Math.floor(maxNodes));
  }

  /** Starts a new lifetime for a root that was reconstructed by ArkUI. */
  public renewRootEpoch(): void {
    this.rootEpoch++;
  }

  public captureFullSnapshot(
    uiContext: UIContext,
    rootId: string,
    vpToPxScale: number = 1,
    timestamp: number = Date.now()
  ): SessionReplayRecord {
    const root = uiContext.getFrameNodeById(rootId);
    if (root === null) {
      throw new Error(`Session Replay root was not found: ${rootId}`);
    }
    return this.captureFrameNode(root, vpToPxScale, timestamp);
  }

  public captureFrameNode(
    root: FrameNode,
    vpToPxScale: number = 1,
    timestamp: number = Date.now()
  ): SessionReplayRecord {
    const scale = Number.isFinite(vpToPxScale) && vpToPxScale > 0 ? vpToPxScale : 1;
    const wireframes: Array<ReplayWireframe> = [];
    this.appendPreOrder(root, scale, wireframes);
    const data: FullSnapshotData = { wireframes };
    const record: SessionReplayRecord = {
      timestamp,
      type: ReplayRecordType.FULL_SNAPSHOT,
      data
    };
    return record;
  }

  private appendPreOrder(
    node: FrameNode,
    vpToPxScale: number,
    output: Array<ReplayWireframe>
  ): void {
    if (output.length >= this.maxNodes) {
      return;
    }

    const nodeId = node.getUniqueId();
    if (nodeId <= 0 || !node.isAttached()) {
      return;
    }

    // A FrameNode can be in the middle of ArkUI's teardown while a View is
    // being started. A single unavailable layout property must not discard an
    // otherwise valid Full Snapshot for the whole page. Keep the node with a
    // zero-sized placeholder and continue with the stable fields we can read.
    let x = 0;
    let y = 0;
    let width = 0;
    let height = 0;
    try {
      const position = node.getPositionToWindow();
      x = Math.round(position.x * vpToPxScale);
      y = Math.round(position.y * vpToPxScale);
    } catch (_) { }
    try {
      const size = node.getMeasuredSize();
      width = Math.max(0, Math.round(size.width));
      height = Math.max(0, Math.round(size.height));
    } catch (_) { }
    let componentId = '';
    try {
      componentId = node.getId();
    } catch (_) { }
    let nodeType = 'UnknownComponent';
    try {
      nodeType = node.getNodeType();
    } catch (_) { }
    const wireframe: ReplayWireframe = {
      id: this.toProtocolId(nodeId),
      x,
      y,
      width,
      height,
      type: 'placeholder',
      label: `ArkUI:${nodeType}`
    };
    if (componentId.length > 0) {
      wireframe.permanentId = componentId;
    }
    output.push(wireframe);

    let child: FrameNode | null = null;
    try {
      child = node.getFirstChild();
    } catch (_) {
      return;
    }
    while (child !== null && output.length < this.maxNodes) {
      this.appendPreOrder(child, vpToPxScale, output);
      try {
        child = child.getNextSibling();
      } catch (_) {
        return;
      }
    }
  }

  private toProtocolId(uniqueId: number): number {
    // Keep identifiers positive JS-safe integers and avoid collisions if a page
    // root is replaced. Android wireframes use a signed 64-bit numeric id.
    const candidate = this.rootEpoch * 1000000000 + uniqueId;
    if (!Number.isSafeInteger(candidate)) {
      throw new Error('Session Replay FrameNode id exceeds the protocol-safe range');
    }
    return candidate;
  }
}
