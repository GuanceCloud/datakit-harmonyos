import { FrameNode } from '@kit.ArkUI';
import { describe, expect, it } from '@ohos/hypium';
import { ArkUIReplayCollector } from '../../main/ets/components/ArkUIReplayCollector';
import { FullSnapshotData, ReplayWireframe } from '../../main/ets/components/SessionReplayProtocol';

/** Minimal FrameNode-shaped fixture for geometry-only collector coverage. */
class ReplayFrameNodeFixture {
  private readonly id: number;
  private readonly layoutX: number;
  private readonly layoutY: number;
  private readonly renderedX: number;
  private readonly renderedY: number;
  private readonly width: number;
  private readonly height: number;
  private readonly clipsChildren: boolean;
  private firstChild: ReplayFrameNodeFixture | null = null;
  private nextSibling: ReplayFrameNodeFixture | null = null;

  constructor(
    id: number,
    layoutX: number,
    layoutY: number,
    renderedX: number,
    renderedY: number,
    width: number,
    height: number,
    clipsChildren: boolean = false
  ) {
    this.id = id;
    this.layoutX = layoutX;
    this.layoutY = layoutY;
    this.renderedX = renderedX;
    this.renderedY = renderedY;
    this.width = width;
    this.height = height;
    this.clipsChildren = clipsChildren;
  }

  public append(child: ReplayFrameNodeFixture): ReplayFrameNodeFixture {
    if (this.firstChild === null) {
      this.firstChild = child;
      return child;
    }
    let last: ReplayFrameNodeFixture = this.firstChild;
    while (last.nextSibling !== null) {
      last = last.nextSibling;
    }
    last.nextSibling = child;
    return child;
  }

  public getUniqueId(): number {
    return this.id;
  }

  public isAttached(): boolean {
    return true;
  }

  public getPositionToWindow(): { x: number, y: number } {
    return { x: this.layoutX, y: this.layoutY };
  }

  public getPositionToWindowWithTransform(): { x: number, y: number } {
    return { x: this.renderedX, y: this.renderedY };
  }

  public getMeasuredSize(): { width: number, height: number } {
    return { width: this.width, height: this.height };
  }

  public getId(): string {
    return `fixture-${this.id}`;
  }

  public getNodeType(): string {
    return 'Column';
  }

  public getInspectorInfo(): Object {
    return {};
  }

  public isClipToFrame(): boolean {
    return this.clipsChildren;
  }

  public getFirstChild(): FrameNode | null {
    return this.firstChild === null ? null : this.firstChild as unknown as FrameNode;
  }

  public getNextSibling(): FrameNode | null {
    return this.nextSibling === null ? null : this.nextSibling as unknown as FrameNode;
  }
}

function findWireframe(wireframes: Array<ReplayWireframe>, id: number): ReplayWireframe | null {
  for (let index = 0; index < wireframes.length; index++) {
    if (wireframes[index].id === id) {
      return wireframes[index];
    }
  }
  return null;
}

export default function arkUIReplayCollectorUnitTest(): void {
  describe('ArkUIReplayCollectorUnit', () => {
    it('hands FrameNode reads to a detached light snapshot before materialization', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100);
      root.append(new ReplayFrameNodeFixture(2, 0, 20, 0, 20, 80, 30));
      const collector = new ArkUIReplayCollector();

      const light = collector.captureFrameNodeLight(root as unknown as FrameNode, 1, 1234);
      expect(light.timestamp).assertEqual(1234);
      expect(light.nodes.length).assertEqual(2);
      expect(light.nodes[1].nodeType).assertEqual('Column');

      const record = collector.materializeLightSnapshot(light);
      const data = record.data as FullSnapshotData;
      expect(record.timestamp).assertEqual(1234);
      expect(data.wireframes.length).assertEqual(2);
    });

    it('uses scroll-transformed positions and clips partially visible children', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100);
      const scroll = root.append(new ReplayFrameNodeFixture(2, 0, 20, 0, 20, 100, 60, true));
      // Layout y=160 is its pre-scroll location; transformed y=60 is where
      // the native child is currently painted inside the Scroll viewport.
      scroll.append(new ReplayFrameNodeFixture(3, 0, 160, 0, 60, 80, 40));
      scroll.append(new ReplayFrameNodeFixture(4, 0, 190, 0, 90, 80, 30));

      const record = new ArkUIReplayCollector().captureFrameNode(root as unknown as FrameNode);
      const data = record.data as FullSnapshotData;
      const partial = findWireframe(data.wireframes, 3);

      expect(data.wireframes.length).assertEqual(3);
      expect(partial !== null).assertTrue();
      expect(partial?.x).assertEqual(0);
      expect(partial?.y).assertEqual(60);
      expect(partial?.width).assertEqual(80);
      expect(partial?.height).assertEqual(20);
      expect(findWireframe(data.wireframes, 4) === null).assertTrue();
    });

    it('intersects every clipping ancestor before serializing child geometry', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100);
      const outer = root.append(new ReplayFrameNodeFixture(2, 0, 0, 0, 0, 100, 100, true));
      const inner = outer.append(new ReplayFrameNodeFixture(3, 20, 20, 20, 20, 50, 50, true));
      inner.append(new ReplayFrameNodeFixture(4, 0, 0, 0, 0, 100, 100));

      const record = new ArkUIReplayCollector().captureFrameNode(root as unknown as FrameNode);
      const data = record.data as FullSnapshotData;
      const child = findWireframe(data.wireframes, 4);

      expect(child !== null).assertTrue();
      expect(child?.x).assertEqual(20);
      expect(child?.y).assertEqual(20);
      expect(child?.width).assertEqual(50);
      expect(child?.height).assertEqual(50);
    });
  });
}
