import { FrameNode, UIContext } from '@kit.ArkUI';
import { describe, expect, it } from '@ohos/hypium';
import { ArkUIReplayCollector } from '../../main/ets/components/ArkUIReplayCollector';
import { ReplaySnapshotProcessor } from '../../main/ets/components/ReplaySnapshotProcessor';
import { FullSnapshotData, ReplayMutationData, ReplayShapeWireframe, ReplayWireframe } from '../../main/ets/components/SessionReplayProtocol';
import { ArkUIReplayPageTransition, ArkUIReplayScenePage } from '../../main/ets/components/SessionReplayScene';

interface ReplayPosition {
  x: number;
  y: number;
}

interface ReplayMeasuredSize {
  width: number;
  height: number;
}

class EmptyInspectorInfo {}

class PageInspectorInfo {
  public backgroundColor: string = '#00000000';
  public zIndex: number;
  constructor(zIndex: number = 0) { this.zIndex = zIndex; }
}

/** Minimal FrameNode-shaped fixture for geometry-only collector coverage. */
class ReplayFrameNodeFixture {
  private readonly id: number;
  private readonly layoutX: number;
  private readonly layoutY: number;
  private renderedX: number;
  private renderedY: number;
  private readonly width: number;
  private readonly height: number;
  private readonly clipsChildren: boolean;
  private firstChild: ReplayFrameNodeFixture | null = null;
  private nextSibling: ReplayFrameNodeFixture | null = null;
  private visible: boolean = true;
  private inspectorInfo: Object = new EmptyInspectorInfo();

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

  public getPositionToWindow(): ReplayPosition {
    return { x: this.layoutX, y: this.layoutY };
  }

  public getPositionToWindowWithTransform(): ReplayPosition {
    return { x: this.renderedX, y: this.renderedY };
  }

  public moveTo(x: number, y: number): void {
    this.renderedX = x;
    this.renderedY = y;
  }

  public getMeasuredSize(): ReplayMeasuredSize {
    return { width: this.width, height: this.height };
  }

  public getId(): string {
    return `fixture-${this.id}`;
  }

  public getNodeType(): string {
    return 'Column';
  }

  public getInspectorInfo(): Object {
    return this.inspectorInfo;
  }

  public withInspector(info: Object): ReplayFrameNodeFixture { this.inspectorInfo = info; return this; }
  public isVisible(): boolean { return this.visible; }
  public getOpacity(): number { return 1; }
  public hide(): void { this.visible = false; }

  public isClipToFrame(): boolean {
    return this.clipsChildren;
  }

  public getFirstChild(): FrameNode | null {
    return this.firstChild === null ? null : asFrameNode(this.firstChild);
  }

  public getNextSibling(): FrameNode | null {
    return this.nextSibling === null ? null : asFrameNode(this.nextSibling);
  }
}

/** The fixture supplies only the FrameNode reads exercised by this collector. */
function asFrameNode(node: ReplayFrameNodeFixture): FrameNode {
  return node as Object as FrameNode;
}

function findWireframe(wireframes: Array<ReplayWireframe>, id: number): ReplayWireframe | null {
  for (let index = 0; index < wireframes.length; index++) {
    if (wireframes[index].permanentId === `fixture-${id}`) {
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

      const light = collector.captureFrameNodeLight(asFrameNode(root), 1, 1234);
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

      const record = new ArkUIReplayCollector().captureFrameNode(asFrameNode(root));
      const data = record.data as FullSnapshotData;
      const partial = findWireframe(data.wireframes, 3);

      expect(data.wireframes.length).assertEqual(4);
      expect(partial !== null).assertTrue();
      expect(partial?.x).assertEqual(0);
      expect(partial?.y).assertEqual(60);
      expect(partial?.width).assertEqual(80);
      expect(partial?.height).assertEqual(40);
      expect(partial?.clip?.bottom).assertEqual(20);
      const offscreen = findWireframe(data.wireframes, 4);
      expect(offscreen !== null).assertTrue();
      expect(offscreen?.y).assertEqual(90);
      expect(offscreen?.height).assertEqual(30);
      expect(offscreen?.clip?.bottom).assertEqual(30);
    });

    it('intersects clipping ancestors without changing child geometry', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100);
      const outer = root.append(new ReplayFrameNodeFixture(2, 0, 0, 0, 0, 100, 100, true));
      const inner = outer.append(new ReplayFrameNodeFixture(3, 20, 20, 20, 20, 50, 50, true));
      inner.append(new ReplayFrameNodeFixture(4, 0, 0, 0, 0, 100, 100));

      const record = new ArkUIReplayCollector().captureFrameNode(asFrameNode(root));
      const data = record.data as FullSnapshotData;
      const child = findWireframe(data.wireframes, 4);

      expect(child !== null).assertTrue();
      expect(child?.x).assertEqual(0);
      expect(child?.y).assertEqual(0);
      expect(child?.width).assertEqual(100);
      expect(child?.height).assertEqual(100);
      expect(child?.clip?.top).assertEqual(20);
      expect(child?.clip?.left).assertEqual(20);
      expect(child?.clip?.right).assertEqual(30);
      expect(child?.clip?.bottom).assertEqual(30);
    });

    it('moves out of and back into a viewport with updates and an explicit zero clip', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100);
      const child = root.append(new ReplayFrameNodeFixture(2, 10, 10, -20, 10, 80, 40));
      const collector = new ArkUIReplayCollector();
      const processor = new ReplaySnapshotProcessor();
      const first = collector.captureFrameNode(asFrameNode(root));
      processor.setFullSnapshotBaseline(first);
      const firstChild = findWireframe((first.data as FullSnapshotData).wireframes, 2);
      expect(firstChild?.clip?.left).assertEqual(20);

      const positions: Array<number> = [100, 10];
      for (const x of positions) {
        child.moveTo(x, 10);
        const latest = collector.captureFrameNode(asFrameNode(root));
        const latestChild = findWireframe((latest.data as FullSnapshotData).wireframes, 2);
        const mutation = processor.createMutationRecord(latest);
        expect(mutation !== null).assertTrue();
        const data = mutation?.data as ReplayMutationData;
        expect(data.adds.length).assertEqual(0);
        expect(data.removes.length).assertEqual(0);
        expect(data.updates.length).assertEqual(1);
        expect(data.updates[0].id).assertEqual(firstChild?.id);
        expect(data.updates[0].x).assertEqual(x);
        expect(data.updates[0].width === undefined).assertTrue();
        expect(data.updates[0].height === undefined).assertTrue();
        expect(latestChild?.width).assertEqual(80);
        expect(latestChild?.height).assertEqual(40);
        expect(data.updates[0].clip?.top).assertEqual(0);
        expect(data.updates[0].clip?.right).assertEqual(x === 100 ? 80 : 0);
        expect(data.updates[0].clip?.bottom).assertEqual(0);
        expect(data.updates[0].clip?.left).assertEqual(0);
        expect(JSON.stringify(data.updates[0].clip)).assertEqual(JSON.stringify(latestChild?.clip));
        expect(processor.createMutationRecord(latest) === null).assertTrue();
      }
      expect(firstChild?.clip?.left).assertEqual(20);
    });

    it('keeps descendants fully clipped even when they transform back into the window', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100);
      const clipped = root.append(new ReplayFrameNodeFixture(2, 120, 0, 120, 0, 80, 40, true));
      clipped.append(new ReplayFrameNodeFixture(3, 120, 0, 10, 0, 20, 20));
      const snapshot = new ArkUIReplayCollector().captureFrameNode(asFrameNode(root));
      const child = findWireframe((snapshot.data as FullSnapshotData).wireframes, 3);
      expect(child !== null).assertTrue();
      expect(child?.x).assertEqual(10);
      expect(child?.width).assertEqual(20);
      expect(child?.clip?.right).assertEqual(20);
    });

    it('uses Replay coordinates for clipping at a non-unit density', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 200, 200);
      root.append(new ReplayFrameNodeFixture(2, 0, 0, -10, 70, 160, 80));
      const snapshot = new ArkUIReplayCollector().captureFrameNode(asFrameNode(root), 2);
      const child = findWireframe((snapshot.data as FullSnapshotData).wireframes, 2);
      expect(child?.x).assertEqual(-10);
      expect(child?.y).assertEqual(70);
      expect(child?.width).assertEqual(80);
      expect(child?.height).assertEqual(40);
      expect(child?.clip?.left).assertEqual(10);
      expect(child?.clip?.bottom).assertEqual(10);
    });

    it('records page backing and isolates zIndex without relayering the successor on release', 0, () => {
      const outgoing = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100)
        .withInspector(new PageInspectorInfo());
      outgoing.append(new ReplayFrameNodeFixture(2, 0, 20, 0, 20, 80, 30)
        .withInspector(new PageInspectorInfo(999999999)));
      const incoming = new ReplayFrameNodeFixture(3, 0, 0, 40, 0, 100, 100)
        .withInspector(new PageInspectorInfo());
      const pages: Array<ArkUIReplayScenePage> = [
        { key: 'old', rootId: 'fixture-1', root: asFrameNode(outgoing), retained: true },
        { key: 'new', rootId: 'fixture-3', root: asFrameNode(incoming), retained: false }
      ];
      const collector = new ArkUIReplayCollector();
      // Supplied FrameNodes and viewport do not require any UIContext reads.
      const context = new EmptyInspectorInfo() as Object as UIContext;
      const viewport = { x: 0, y: 0, width: 100, height: 100 };
      const light = collector.captureSceneLight(context, [], 1, 1234, new Map(), viewport, pages);
      const first = collector.materializeLightSnapshot(light);
      const wireframes = (first.data as FullSnapshotData).wireframes;
      const newRoot = findWireframe(wireframes, 3) as ReplayShapeWireframe;
      const newSurface = wireframes.find((node: ReplayWireframe): boolean => node.id === -newRoot.id) as ReplayShapeWireframe;
      const oldChild = findWireframe(wireframes, 2);
      expect(newRoot.shapeStyle?.backgroundColor).assertEqual('#00000000');
      expect(newSurface.shapeStyle?.backgroundColor).assertEqual('#FFFFFFFF');
      expect(newSurface.x).assertEqual(40);
      expect(newSurface.width).assertEqual(100);
      expect(newSurface.clip?.right).assertEqual(40);
      expect((newSurface.zIndex ?? 0) > (oldChild?.zIndex ?? 0)).assertTrue();
      // Detached frames remain usable only while real exit progress owns them.
      const transitions = new Map<string, ArkUIReplayPageTransition>();
      transitions.set('old', { entering: false, progress: 0.5 });
      outgoing.hide();
      const retained = collector.captureSceneLight(context, [], 1, 1266, transitions, viewport, pages);
      expect(retained.nodes.length).assertEqual(light.nodes.length);
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      const settled = collector.materializeLightSnapshot(collector.captureSceneLight(context, [], 1, 1298,
        new Map(), viewport, [pages[1]]));
      const mutation = processor.createMutationRecord(settled)?.data as ReplayMutationData;
      expect(mutation.adds.length).assertEqual(0);
      expect(mutation.removes.length).assertEqual(3);
      expect(mutation.updates.length).assertEqual(0);
    });
  });
}
