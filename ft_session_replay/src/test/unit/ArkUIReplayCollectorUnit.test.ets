import { FrameNode, UIContext } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { describe, expect, it } from '@ohos/hypium';
import { ArkUIReplayCollector } from '../../main/ets/components/ArkUIReplayCollector';
import { FTSessionReplayConfig, ImagePrivacy, TextAndInputPrivacy } from '../../main/ets/components/FTSessionReplayConfig';
import { ReplaySnapshotProcessor } from '../../main/ets/components/ReplaySnapshotProcessor';
import { FullSnapshotData, ReplayImageWireframe, ReplayMutationData, ReplayShapeWireframe, ReplayTextWireframe, ReplayWireframe, SessionReplayRecord } from '../../main/ets/components/SessionReplayProtocol';
import { ArkUIReplayPageTransition, ArkUIReplaySceneBounds, ArkUIReplayScenePage } from '../../main/ets/components/SessionReplayScene';

interface ReplayPosition {
  x: number;
  y: number;
}

interface ReplayMeasuredSize {
  width: number;
  height: number;
}

class EmptyInspectorInfo {}

class TextColorInspectorInfo {
  public content: string = 'Inherited label';
  public fontColor: string;
  public foregroundColor: string;
  constructor(fontColor: string, foregroundColor: string) {
    this.fontColor = fontColor;
    this.foregroundColor = foregroundColor;
  }
}

interface TextColorCase {
  fontColor: string;
  foregroundColor: string;
  expected: string;
}

interface TextAlignmentCase {
  align: string;
  horizontal: string;
  vertical: string;
}

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
  private parent: ReplayFrameNodeFixture | null = null;
  private visible: boolean = true;
  private nodeType: string = 'Column';
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
    child.parent = this;
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

  public getPositionToParent(): ReplayPosition {
    return { x: this.layoutX - (this.parent?.layoutX ?? 0), y: this.layoutY - (this.parent?.layoutY ?? 0) };
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
    return this.nodeType;
  }

  public getInspectorInfo(): Object {
    return this.inspectorInfo;
  }

  public withInspector(info: Object): ReplayFrameNodeFixture { this.inspectorInfo = info; return this; }
  public withNodeType(nodeType: string): ReplayFrameNodeFixture { this.nodeType = nodeType; return this; }
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

  public getParent(): FrameNode | null {
    return this.parent === null || this.parent.nodeType === 'page' || this.parent.nodeType === 'stage' ?
      null : asFrameNode(this.parent);
  }

  public removeChildren(): void {
    let child = this.firstChild;
    while (child !== null) {
      const next = child.nextSibling;
      child.parent = null;
      child.nextSibling = null;
      child = next;
    }
    this.firstChild = null;
  }
}

class ReplayOverlayContextFixture {
  public treeReads: number = 0;
  public tree: string;
  private readonly overlay: FrameNode;

  constructor(overlay: ReplayFrameNodeFixture) {
    this.overlay = asFrameNode(overlay);
    this.tree = `{"$children":[{"$type":"MenuWrapper","$ID":${overlay.getUniqueId()}}]}`;
  }

  public getFilteredInspectorTree(filters: Array<string>): string {
    expect(filters.length).assertEqual(1);
    expect(filters[0]).assertEqual('id');
    this.treeReads++;
    return this.tree;
  }

  public getFrameNodeByUniqueId(id: number): FrameNode | null {
    return id === this.overlay.getUniqueId() ? this.overlay : null;
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
    it('uses native input type before unspecified content type and keeps placeholder styling separate', 0, () => {
      const attrs: Record<string, Object> = { 'text': 'Demo-Password', 'placeholder': '密码提示',
        'type': 'InputType.Password', 'contentType': 'TextContentType.UNSPECIFIED',
        'fontColor': '#E5000000', 'placeholderColor': '#99000000', 'fontSize': '16fp',
        'placeholderFont': '{"size":"14fp","weight":"500","fontFamily":"sans-serif"}',
        'align': 'Alignment.Center', 'borderWidth': '0vp' };
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 240, 40).withNodeType('TextInput')
        .withInspector({ '$type': 'TextInput', 'type': 'build-in', '$attrs': attrs } as Record<string, Object>);
      const config = new FTSessionReplayConfig().setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS);
      const collector = new ArkUIReplayCollector(1500, config);
      const password = (collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData).wireframes[0] as ReplayTextWireframe;
      expect(password.text).assertEqual('•'.repeat('Demo-Password'.length));
      expect(password.border === undefined).assertTrue();
      attrs['type'] = '2';
      expect(((collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData).wireframes[0] as ReplayTextWireframe)
        .text).assertEqual('•'.repeat('Demo-Password'.length));
      attrs['type'] = 'InputType.Password';
      attrs['text'] = '';
      const placeholder = (collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData).wireframes[0] as ReplayTextWireframe;
      expect(placeholder.text).assertEqual('密码提示');
      expect(placeholder.textStyle.color).assertEqual('#00000099');
      expect(placeholder.textStyle.size).assertEqual(14);
      expect(placeholder.textStyle.weight).assertEqual(500);
      attrs['type'] = 'InputType.Normal';
      attrs['text'] = 'Public copy';
      expect(((collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData).wireframes[0] as ReplayTextWireframe)
        .text).assertEqual('Public copy');
      config.setTextAndInputPrivacy(TextAndInputPrivacy.MASK_ALL);
      attrs['text'] = '';
      expect(((collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData).wireframes[0] as ReplayTextWireframe)
        .text.includes('密码')).assertFalse();
    });

    it('lets SearchField own its text and applies input privacy to SearchField and RichEditor descendants', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 240, 40).withNodeType('Search');
      const field = root.append(new ReplayFrameNodeFixture(2, 30, 0, 30, 0, 140, 40).withNodeType('SearchField')
        .withInspector({ 'text': 'Search value', 'type': 'TextAreaType.NORMAL' } as Record<string, Object>));
      const config = new FTSessionReplayConfig().setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS);
      const collector = new ArkUIReplayCollector(1500, config);
      const search = (collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData).wireframes;
      expect(search[0].type).assertEqual('shape');
      expect((search[1] as ReplayTextWireframe).text).assertEqual('Search value');
      config.setTextAndInputPrivacy(TextAndInputPrivacy.MASK_ALL_INPUTS);
      expect(((collector.captureFrameNode(asFrameNode(field)).data as FullSnapshotData).wireframes[0] as ReplayTextWireframe)
        .text.includes('Search')).assertFalse();
      const editor = new ReplayFrameNodeFixture(3, 0, 0, 0, 0, 240, 160).withNodeType('RichEditor')
        .withInspector({ 'align': 'Alignment.Center' } as Record<string, Object>);
      editor.append(new ReplayFrameNodeFixture(4, 10, 10, 10, 10, 100, 30).withNodeType('Text')
        .withInspector({ 'content': 'Private editor descendant' } as Record<string, Object>));
      const data = (collector.captureFrameNode(asFrameNode(editor)).data as FullSnapshotData).wireframes;
      expect(data.length).assertEqual(1);
      expect((data[0] as ReplayTextWireframe).text.includes('•')).assertTrue();
      expect((data[0] as ReplayTextWireframe).textPosition?.alignment?.vertical).assertEqual('top');
    });

    it('honors text and image privacy for native raster keys and keeps their geometry', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 10, 20, 10, 20, 200, 60).withNodeType('Text')
        .withInspector({ 'content': 'Public inline copy' } as Record<string, Object>);
      const config = new FTSessionReplayConfig().setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS)
        .setImagePrivacy(ImagePrivacy.MASK_NONE);
      const collector = new ArkUIReplayCollector(1500, config);
      const png = new util.Base64Helper().decodeSync('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL9sAAAAASUVORK5CYII=');
      collector.registerImageAsset('inline-raster', png, 'image/png');
      const light = collector.captureFrameNodeLight(asFrameNode(root), 2);
      light.nodes[0].componentRasterKey = 'inline-raster';
      light.nodes[0].clip = { left: 3, top: 4, right: 5, bottom: 6 };
      const bitmap = (collector.materializeLightSnapshot(light).data as FullSnapshotData).wireframes[0] as ReplayImageWireframe;
      expect(bitmap.type).assertEqual('image');
      expect(bitmap.isEmpty).assertFalse();
      expect(bitmap.x).assertEqual(10);
      expect(bitmap.width).assertEqual(100);
      expect(bitmap.clip?.left).assertEqual(3);
      expect(bitmap.clip?.bottom).assertEqual(6);
      expect(collector.takeCapturedImageResources().length).assertEqual(1);
      expect(((collector.materializeLightSnapshot(light).data as FullSnapshotData).wireframes[0] as ReplayImageWireframe)
        .isEmpty).assertFalse();
      expect(collector.takeCapturedImageResources().length).assertEqual(1);
      config.setTextAndInputPrivacy(TextAndInputPrivacy.MASK_ALL);
      const masked = (collector.materializeLightSnapshot(light).data as FullSnapshotData).wireframes[0] as ReplayTextWireframe;
      expect(masked.type).assertEqual('text');
      expect(masked.text.includes('Public')).assertFalse();
      expect(collector.takeCapturedImageResources().length).assertEqual(0);
      root.withNodeType('RichEditor');
      const editorLight = collector.captureFrameNodeLight(asFrameNode(root), 2);
      editorLight.nodes[0].componentRasterKey = 'inline-raster';
      config.setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setImagePrivacy(ImagePrivacy.MASK_NONE);
      expect((collector.materializeLightSnapshot(editorLight).data as FullSnapshotData).wireframes[0].type).assertEqual('image');
      config.setTextAndInputPrivacy(TextAndInputPrivacy.MASK_ALL_INPUTS);
      expect((collector.materializeLightSnapshot(editorLight).data as FullSnapshotData).wireframes[0].type).assertEqual('text');
      expect(collector.takeCapturedImageResources().length).assertEqual(0);
      config.setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setImagePrivacy(ImagePrivacy.MASK_ALL);
      expect((collector.materializeLightSnapshot(light).data as FullSnapshotData).wireframes[0].type).assertEqual('text');
      expect(collector.takeCapturedImageResources().length).assertEqual(0);
    });

    it('captures Hyperlink content and typography as text with normal privacy filtering', 0, () => {
      const attrs: Record<string, Object> = { 'content': '观测云链接', 'fontSize': '16fp', 'foregroundColor': '#FF2563EB' };
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 80, 20).withNodeType('Hyperlink').withInspector(attrs);
      const collector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS));
      const first = collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
      const link = first.wireframes[0] as ReplayTextWireframe;
      expect(link.type).assertEqual('text');
      expect(link.text).assertEqual('观测云链接');
      expect(link.textStyle.color).assertEqual('#2563EBFF');
      expect(link.textStyle.size).assertEqual(16);
      expect(link.textPosition?.alignment?.vertical).assertEqual('center');
      const masked = new ArkUIReplayCollector().captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
      expect((masked.wireframes[0] as ReplayTextWireframe).text.includes('观测云')).assertFalse();
    });

    it('reconstructs target-only Marquee motion at native pixel step and clears sampling on pause or finish', 0, () => {
      const attrs: Record<string, Object> = { 'src': 'Moving text', 'start': 'true', 'step': '10', 'loop': '-1', 'fromStart': 'true' };
      const root = new ReplayFrameNodeFixture(1, 20, 30, 20, 30, 200, 80).withNodeType('Marquee').withInspector(attrs);
      const marqueeText = new ReplayFrameNodeFixture(2, 20, 30, -180, 30, 400, 80).withNodeType('Text')
        .withInspector({ 'content': 'Moving text' } as Record<string, Object>);
      root.append(marqueeText);
      const collector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS));
      const firstLight = collector.captureFrameNodeLight(asFrameNode(root), 2, 1000);
      expect(firstLight.hasActiveAnimations).assertTrue();
      const first = collector.materializeLightSnapshot(firstLight);
      const label = findWireframe((first.data as FullSnapshotData).wireframes, 2) as ReplayTextWireframe;
      expect(label.text).assertEqual('Moving text');
      expect(label.x).assertEqual(20);
      expect(label.clip?.left).assertEqual(0);
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      const moving = collector.captureFrameNode(asFrameNode(root), 2, 1850);
      const changed = findWireframe((moving.data as FullSnapshotData).wireframes, 2)!;
      expect(changed.x).assertEqual(-30);
      expect(changed.clip?.left).assertEqual(50);
      expect(changed.clip?.right).assertEqual(50);
      expect((processor.createMutationRecord(moving)!.data as ReplayMutationData).updates.length).assertEqual(1);
      attrs['start'] = 'false';
      expect(collector.captureFrameNodeLight(asFrameNode(root), 2, 1850).hasActiveAnimations).assertFalse();
      expect(collector.captureFrameNodeLight(asFrameNode(root), 2, 2850).nodes[1].x).assertEqual(-30);
      attrs['start'] = 'true';
      attrs['loop'] = '1';
      expect(collector.captureFrameNodeLight(asFrameNode(root), 2, 3000).hasActiveAnimations).assertTrue();
      const finished = collector.captureFrameNodeLight(asFrameNode(root), 2, 6401);
      expect(finished.hasActiveAnimations).assertFalse();
      expect(finished.nodes[1].x).assertEqual(20);
      attrs['fromStart'] = 'false';
      attrs['loop'] = '-1';
      marqueeText.moveTo(120, 30);
      collector.captureFrameNodeLight(asFrameNode(root), 2, 7000);
      expect(collector.captureFrameNodeLight(asFrameNode(root), 2, 7850).nodes[1].x).assertEqual(70);
      const fitted = new ReplayFrameNodeFixture(3, 20, 30, 20, 30, 200, 80).withNodeType('Marquee').withInspector(attrs);
      fitted.append(new ReplayFrameNodeFixture(4, 20, 30, 20, 30, 200, 80).withNodeType('Text'));
      const staticLight = collector.captureFrameNodeLight(asFrameNode(fitted), 2, 9000);
      expect(staticLight.hasActiveAnimations).assertFalse();
      expect(collector.captureFrameNodeLight(asFrameNode(fitted), 2, 10000).nodes[1].x).assertEqual(20);
    });

    it('renders HTML Web content as styled paragraphs with stable ids, privacy and viewport clipping', 0, () => {
      const attrs: Record<string, Object> = { 'content': '<div style="color:#2563eb;font-size:18px"><b>HTML 富文本</b><p>段落与颜色采集测试</p></div>' };
      const root = new ReplayFrameNodeFixture(1, 10, 20, 10, 20, 300, 110).withNodeType('Web').withInspector(attrs);
      const collector = new ArkUIReplayCollector(32, new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS));
      const first = collector.captureFrameNode(asFrameNode(root));
      const frames = (first.data as FullSnapshotData).wireframes;
      const runs = frames.filter((node): boolean => node.type === 'text') as Array<ReplayTextWireframe>;
      expect(runs.map((node): string => node.text).join('')).assertEqual('HTML 富文本段落与颜色采集测试');
      expect(runs.every((node): boolean => node.textStyle.color === '#2563EBFF' && node.textStyle.size === 18)).assertTrue();
      expect(runs[0].textStyle.weight).assertEqual(700);
      expect(runs[runs.length - 1].textStyle.weight).assertEqual(400);
      expect(runs[runs.length - 1].y > runs[0].y + 18).assertTrue();
      expect(runs.every((node): boolean => node.width > 0 && node.height > 0)).assertTrue();
      expect(new Set(frames.map((node): number => node.id)).size).assertEqual(frames.length);
      expect(JSON.stringify(frames).includes('<div')).assertFalse();
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      expect(processor.createMutationRecord(collector.captureFrameNode(asFrameNode(root))) === null).assertTrue();
      attrs['content'] = '<div style="color:#22c55e;font-size:18px"><b>HTML 富文本</b><p>段落与颜色采集测试</p></div>';
      const changed = processor.createMutationRecord(collector.captureFrameNode(asFrameNode(root)))!.data as ReplayMutationData;
      expect(changed.adds.length).assertEqual(0);
      expect(changed.removes.length).assertEqual(0);
      expect(changed.updates.every((node): boolean => node.textStyle?.color === '#22C55EFF')).assertTrue();
      const masked = new ArkUIReplayCollector().captureFrameNode(asFrameNode(root));
      expect(JSON.stringify(masked).includes('富文本')).assertFalse();
      attrs['content'] = '<script>secret</script><span style="display:none">hidden</span><p>A &amp; B &#x4e2d;</p>';
      const visible = collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
      expect(visible.wireframes.filter((node): boolean => node.type === 'text')
        .map((node): string => node.type === 'text' ? node.text : '').join('')).assertEqual('A & B 中');
    });

    it('masks editable HTML and textarea content while preserving public rich copy', 0, () => {
      const attrs: Record<string, Object> = { 'content': '<div>Public</div><div contenteditable="true"><b>private-edit</b></div>' +
        '<textarea>private-input</textarea><span contenteditable="false">Readable</span>' };
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 300, 200).withNodeType('Web').withInspector(attrs);
      for (const privacy of [TextAndInputPrivacy.MASK_SENSITIVE_INPUTS, TextAndInputPrivacy.MASK_ALL_INPUTS]) {
        const collector = new ArkUIReplayCollector(32, new FTSessionReplayConfig().setTextAndInputPrivacy(privacy));
        const data = collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
        const content = data.wireframes.filter((node): boolean => node.type === 'text')
          .map((node): string => node.type === 'text' ? node.text : '').join('');
        expect(content.includes('Public')).assertTrue();
        expect(content.includes('Readable')).assertTrue();
        expect(content.includes('private')).assertFalse();
        expect(content.includes('•')).assertTrue();
      }
    });

    it('bounds rich text expansion and respects line height, nonbreaking spaces and clipped wraps', 0, () => {
      const attrs: Record<string, Object> = { 'content': '<p style="line-height:2;font-size:20px">A&nbsp;B 长文本多行换行采集验证</p>' };
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 70, 25).withNodeType('Web').withInspector(attrs);
      const collector = new ArkUIReplayCollector(4, new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS));
      const frames = (collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData).wireframes;
      const runs = frames.filter((node): boolean => node.type === 'text') as Array<ReplayTextWireframe>;
      expect(frames.length <= 4).assertTrue();
      expect(runs.length > 0).assertTrue();
      expect(runs.every((node): boolean => node.textStyle.size === 20 && node.textStyle.lineHeight === 40)).assertTrue();
      expect(runs.map((node): string => node.text).join('').includes('A\u00a0B')).assertTrue();
      expect(runs.some((node): boolean => (node.clip?.bottom ?? 0) > 0)).assertTrue();
    });

    it('captures all native block alignments and compound left/right alignments', 0, () => {
      const cases: Array<TextAlignmentCase> = [
        { align: 'Alignment.TopStart', horizontal: 'left', vertical: 'top' },
        { align: 'Alignment.Top', horizontal: 'center', vertical: 'top' },
        { align: 'Alignment.TopEnd', horizontal: 'right', vertical: 'top' },
        { align: 'Alignment.Start', horizontal: 'left', vertical: 'center' },
        { align: 'Alignment.Center', horizontal: 'center', vertical: 'center' },
        { align: 'Alignment.End', horizontal: 'right', vertical: 'center' },
        { align: 'Alignment.BottomStart', horizontal: 'left', vertical: 'bottom' },
        { align: 'Alignment.Bottom', horizontal: 'center', vertical: 'bottom' },
        { align: 'Alignment.BottomEnd', horizontal: 'right', vertical: 'bottom' },
        { align: 'Alignment.CenterLeft', horizontal: 'left', vertical: 'center' },
        { align: 'Alignment.CenterRight', horizontal: 'right', vertical: 'center' }
      ];
      const collector = new ArkUIReplayCollector();
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 200, 120).withNodeType('Text');
      for (const value of cases) {
        const attrs: Record<string, Object> = {};
        attrs['align'] = value.align;
        root.withInspector(attrs);
        const data = collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
        const position = (data.wireframes[0] as ReplayTextWireframe).textPosition;
        expect(position?.alignment?.horizontal).assertEqual(value.horizontal);
        expect(position?.alignment?.vertical).assertEqual(value.vertical);
      }
    });

    it('uses textAlign ahead of block alignment and keeps Text vertically centered by default', 0, () => {
      const collector = new ArkUIReplayCollector();
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 200, 120).withNodeType('Text');
      const attrs: Record<string, Object> = {};
      attrs['textAlign'] = 'TextAlign.Center';
      root.withInspector(attrs);
      let data = collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
      expect((data.wireframes[0] as ReplayTextWireframe).textPosition?.alignment?.horizontal).assertEqual('center');
      expect((data.wireframes[0] as ReplayTextWireframe).textPosition?.alignment?.vertical).assertEqual('center');
      attrs['align'] = 'Alignment.BottomEnd';
      attrs['verticalAlign'] = 'VerticalAlign.Top';
      data = collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
      expect((data.wireframes[0] as ReplayTextWireframe).textPosition?.alignment?.horizontal).assertEqual('center');
      expect((data.wireframes[0] as ReplayTextWireframe).textPosition?.alignment?.vertical).assertEqual('top');
      attrs['textDirection'] = 'TextDirection.Rtl';
      attrs['textAlign'] = 'TextAlign.Start';
      data = collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
      expect((data.wireframes[0] as ReplayTextWireframe).textPosition?.alignment?.horizontal).assertEqual('right');
      attrs['textAlign'] = 'TextAlign.End';
      data = collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
      expect((data.wireframes[0] as ReplayTextWireframe).textPosition?.alignment?.horizontal).assertEqual('left');
    });

    it('decodes native JSON typography padding and rounded Select styles in vp units', 0, () => {
      const attrs: Record<string, Object> = {};
      attrs['content'] = '增量更新与动画';
      attrs['font'] = '{"size":"16fp","weight":"FontWeight.Medium","family":"HarmonyOS Sans","style":"FontStyle.Normal"}';
      attrs['padding'] = '{"top":"14px","right":"8vp","bottom":"0vp","left":"28px"}';
      attrs['borderRadius'] = '{"topLeft":"20vp","topRight":"20vp","bottomRight":"20vp","bottomLeft":"20vp"}';
      attrs['backgroundColor'] = '#0C000000';
      attrs['align'] = 'Alignment.Start';
      const envelope: Record<string, Object> = {};
      envelope['$attrs'] = attrs;
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 1148, 140).withNodeType('Text').withInspector(envelope);
      const data = new ArkUIReplayCollector().captureFrameNode(asFrameNode(root), 3.5).data as FullSnapshotData;
      const label = data.wireframes[0] as ReplayTextWireframe;
      expect(label.textStyle.size).assertEqual(16);
      expect(label.textStyle.family).assertEqual('HarmonyOS Sans');
      expect(label.textStyle.weight).assertEqual(500);
      expect(label.textStyle.style).assertEqual('normal');
      expect(label.shapeStyle?.backgroundColor).assertEqual('#0000000C');
      expect(label.shapeStyle?.cornerRadius).assertEqual(20);
      expect(label.textPosition?.padding?.top).assertEqual(4);
      expect(label.textPosition?.padding?.right).assertEqual(8);
      expect(label.textPosition?.padding?.bottom).assertEqual(0);
      expect(label.textPosition?.padding?.left).assertEqual(8);
      expect(label.textPosition?.alignment?.horizontal).assertEqual('left');
      expect(label.textPosition?.alignment?.vertical).assertEqual('center');
    });

    it('updates cached alignment and serialized styles through mutations without changing geometry', 0, () => {
      const attrs: Record<string, Object> = {};
      attrs['textAlign'] = 'TextAlign.Center';
      attrs['align'] = 'Alignment.Start';
      attrs['padding'] = '{"left":"8vp","right":"8vp"}';
      attrs['borderRadius'] = '{"topLeft":"20vp"}';
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 200, 120).withNodeType('Text').withInspector(attrs);
      const collector = new ArkUIReplayCollector();
      const processor = new ReplaySnapshotProcessor();
      const first = collector.captureFrameNode(asFrameNode(root));
      processor.setFullSnapshotBaseline(first);
      attrs['textAlign'] = 'TextAlign.End';
      attrs['align'] = 'Alignment.TopEnd';
      attrs['padding'] = '{"left":"0vp","right":"12vp"}';
      attrs['borderRadius'] = '{"topLeft":"0vp"}';
      const latest = collector.captureFrameNode(asFrameNode(root));
      const mutation = processor.createMutationRecord(latest);
      expect(mutation !== null).assertTrue();
      const data = mutation!.data as ReplayMutationData;
      expect(data.updates.length).assertEqual(1);
      expect(data.adds.length).assertEqual(0);
      expect(data.removes.length).assertEqual(0);
      expect(data.updates[0].textPosition?.alignment?.horizontal).assertEqual('right');
      expect(data.updates[0].textPosition?.alignment?.vertical).assertEqual('top');
      expect(data.updates[0].textPosition?.padding?.left).assertEqual(0);
      expect(data.updates[0].textPosition?.padding?.right).assertEqual(12);
      expect(data.updates[0].shapeStyle?.cornerRadius).assertEqual(0);
      expect(data.updates[0].width === undefined).assertTrue();
      expect(processor.createMutationRecord(latest) === null).assertTrue();
      const original = (first.data as FullSnapshotData).wireframes[0] as ReplayTextWireframe;
      expect(original.textPosition?.alignment?.vertical).assertEqual('center');
      expect(original.shapeStyle?.cornerRadius).assertEqual(20);
    });

    it('prefers native border corners over unrelated zero effect and shadow radii', 0, () => {
      const attrs: Record<string, Object> = {};
      const corners: Record<string, Object> = {};
      corners['topLeft'] = '20vp';
      corners['topRight'] = '20vp';
      corners['bottomLeft'] = '20vp';
      corners['bottomRight'] = '20vp';
      attrs['borderRadius'] = corners;
      const effect: Record<string, Object> = {};
      effect['radius'] = '0.000000';
      attrs['foregroundEffect'] = effect;
      attrs['shadow'] = effect;
      const envelope: Record<string, Object> = {};
      envelope['$attrs'] = attrs;
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 300, 40).withNodeType('Select').withInspector(envelope);
      const data = new ArkUIReplayCollector().captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
      expect((data.wireframes[0] as ReplayShapeWireframe).shapeStyle?.cornerRadius).assertEqual(20);
    });

    it('fills an empty internal Select label from its owner and invalidates cached text on selection changes', 0, () => {
      const attrs: Record<string, Object> = {};
      attrs['value'] = '增量更新与动画';
      const select = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 300, 40).withNodeType('Select').withInspector(attrs);
      const row = select.append(new ReplayFrameNodeFixture(2, 8, 0, 8, 0, 284, 40).withNodeType('Row'));
      const textAttrs: Record<string, Object> = {};
      textAttrs['content'] = '';
      textAttrs['fontSize'] = '16fp';
      textAttrs['textAlign'] = 'TextAlign.Start';
      textAttrs['align'] = 'Alignment.Start';
      const text = row.append(new ReplayFrameNodeFixture(3, 16, 10, 16, 10, 260, 20)
        .withNodeType('Text').withInspector(textAttrs));
      const collector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS));
      const context = new EmptyInspectorInfo() as Object as UIContext;
      const pages: Array<ArkUIReplayScenePage> = [{ key: 'select', rootId: 'select', root: asFrameNode(select), retained: false }];
      const first = collector.materializeLightSnapshot(collector.captureSceneLight(context, [], 1, 1234,
        new Map(), { x: 0, y: 0, width: 300, height: 40 }, pages));
      const label = findWireframe((first.data as FullSnapshotData).wireframes, 3) as ReplayTextWireframe;
      expect(label.text).assertEqual('增量更新与动画');
      expect(label.x).assertEqual(16);
      expect(label.textStyle.size).assertEqual(16);
      expect(label.textPosition?.alignment?.horizontal).assertEqual('left');
      expect(label.textPosition?.alignment?.vertical).assertEqual('center');
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      attrs['value'] = '文字与富文本';
      const latest = collector.materializeLightSnapshot(collector.captureSceneLight(context, [], 1, 1266,
        new Map(), { x: 0, y: 0, width: 300, height: 40 }, pages));
      const mutation = processor.createMutationRecord(latest)!.data as ReplayMutationData;
      expect(mutation.updates.length).assertEqual(1);
      expect(mutation.updates[0].text).assertEqual('文字与富文本');
      expect(mutation.updates[0].x === undefined).assertTrue();
      expect(mutation.adds.length).assertEqual(0);
      expect(mutation.removes.length).assertEqual(0);
      expect(processor.createMutationRecord(latest) === null).assertTrue();
      expect(label.text).assertEqual('增量更新与动画');
      // An exposed child value remains authoritative if the native engine supplies one.
      textAttrs['content'] = 'Native child label';
      text.withInspector(textAttrs);
      const exposed = collector.captureFrameNode(asFrameNode(select)).data as FullSnapshotData;
      expect((findWireframe(exposed.wireframes, 3) as ReplayTextWireframe).text).assertEqual('Native child label');
      const masked = new ArkUIReplayCollector().captureFrameNode(asFrameNode(select)).data as FullSnapshotData;
      expect(JSON.stringify(masked).includes('Native child label')).assertFalse();
      textAttrs['content'] = '';
      const maskedFallback = new ArkUIReplayCollector().captureFrameNode(asFrameNode(select)).data as FullSnapshotData;
      expect(JSON.stringify(maskedFallback).includes('文字与富文本')).assertFalse();
      expect((findWireframe(maskedFallback.wireframes, 3) as ReplayTextWireframe).text.length).assertEqual('文字与富文本'.length);
    });

    it('preserves only the Select spinner as a tinted vector through scene composition and cache updates', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100);
      const select = root.append(new ReplayFrameNodeFixture(2, 0, 0, 0, 0, 100, 40).withNodeType('Select'));
      const row = select.append(new ReplayFrameNodeFixture(3, 8, 0, 8, 0, 84, 40).withNodeType('Row'));
      const attrs: Record<string, Object> = {};
      attrs['fontColor'] = '["#E5000000"]';
      const spinner = row.append(new ReplayFrameNodeFixture(4, 80, 12, 80, 12, 11, 16)
        .withNodeType('SymbolGlyph').withInspector(attrs));
      root.append(new ReplayFrameNodeFixture(5, 0, 50, 0, 50, 20, 20).withNodeType('SymbolGlyph'));
      const collector = new ArkUIReplayCollector();
      const context = new EmptyInspectorInfo() as Object as UIContext;
      const pages: Array<ArkUIReplayScenePage> = [{ key: 'page', rootId: 'page', root: asFrameNode(root), retained: false }];
      const first = collector.materializeLightSnapshot(collector.captureSceneLight(context, [], 1, 1234,
        new Map(), { x: 0, y: 0, width: 100, height: 100 }, pages));
      const data = first.data as FullSnapshotData;
      const arrow = findWireframe(data.wireframes, 4) as ReplayImageWireframe;
      expect(arrow.type).assertEqual('image');
      expect(arrow.isEmpty).assertFalse();
      expect(arrow.mimeType).assertEqual('svg+xml');
      expect(`data:image/${arrow.mimeType};base64,${arrow.base64}`.startsWith('data:image/svg+xml;base64,')).assertTrue();
      expect(arrow.resourceId === undefined).assertTrue();
      const svg = util.TextDecoder.create('utf-8').decodeWithStream(new util.Base64Helper().decodeSync(arrow.base64!));
      expect(svg.includes('fill="#000000"')).assertTrue();
      expect(svg.includes('fill-opacity="0.898')).assertTrue();
      expect(findWireframe(data.wireframes, 5)?.type).assertEqual('shape');
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      attrs['fontColor'] = '["#FF2563EB"]';
      spinner.withInspector(attrs);
      const latest = collector.materializeLightSnapshot(collector.captureSceneLight(context, [], 1, 1266,
        new Map(), { x: 0, y: 0, width: 100, height: 100 }, pages));
      const mutation = processor.createMutationRecord(latest)!.data as ReplayMutationData;
      expect(mutation.updates.length).assertEqual(1);
      expect(mutation.updates[0].type).assertEqual('image');
      const updated = util.TextDecoder.create('utf-8').decodeWithStream(
        new util.Base64Helper().decodeSync(mutation.updates[0].base64!));
      expect(updated.includes('fill="#2563EB"')).assertTrue();
      expect(processor.createMutationRecord(latest) === null).assertTrue();
      expect(collector.takeCapturedImageResources().length).assertEqual(0);
    });

    it('captures the resolved foreground of a custom Button label instead of its theme font color', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100).withNodeType('Button');
      root.append(new ReplayFrameNodeFixture(2, 10, 10, 10, 10, 80, 20).withNodeType('Text')
        .withInspector(new TextColorInspectorInfo('#CE000000', '#FFFFFFFF')));
      const data = new ArkUIReplayCollector().captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
      expect(findWireframe(data.wireframes, 1)?.type).assertEqual('shape');
      const label = findWireframe(data.wireframes, 2) as ReplayTextWireframe;
      expect(label.type).assertEqual('text');
      expect(label.textStyle.color).assertEqual('#FFFFFFFF');
      // Masking changes the content but must keep the rendered color.
      expect(label.text.includes('Inherited label')).assertFalse();
    });

    it('resolves foreground references while preserving explicit overrides and transparent colors', 0, () => {
      const cases: Array<TextColorCase> = [
        { fontColor: '#00000001', foregroundColor: '#FFFFFFFF', expected: '#FFFFFFFF' },
        { fontColor: '0x00000001', foregroundColor: '0x80112233', expected: '#11223380' },
        { fontColor: '#FF2563EB', foregroundColor: '#FF2563EB', expected: '#2563EBFF' },
        { fontColor: '#FF2563EB', foregroundColor: '#00000001', expected: '#2563EBFF' },
        { fontColor: '#00000000', foregroundColor: '#00000001', expected: '#00000000' },
        { fontColor: '#CE000000', foregroundColor: '#00000000', expected: '#00000000' },
        { fontColor: '#00000001', foregroundColor: '#00000001', expected: '#1F2937FF' },
        { fontColor: 'inherit', foregroundColor: 'unavailable', expected: '#1F2937FF' }
      ];
      const collector = new ArkUIReplayCollector();
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 20).withNodeType('Text');
      for (const value of cases) {
        root.withInspector(new TextColorInspectorInfo(value.fontColor, value.foregroundColor));
        const data = collector.captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
        expect((data.wireframes[0] as ReplayTextWireframe).textStyle.color).assertEqual(value.expected);
      }
    });

    it('reads inherited foreground colors inside Inspector attribute envelopes', 0, () => {
      const attrs: Record<string, Object> = {};
      attrs['content'] = 'Session Replay Demo';
      attrs['fontColor'] = '#CE000000';
      attrs['foregroundColor'] = '#FFFFFFFF';
      const inspector: Record<string, Object> = {};
      inspector['$attrs'] = attrs;
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 20).withNodeType('Text').withInspector(inspector);
      const data = new ArkUIReplayCollector().captureFrameNode(asFrameNode(root)).data as FullSnapshotData;
      expect((data.wireframes[0] as ReplayTextWireframe).textStyle.color).assertEqual('#FFFFFFFF');
    });

    it('updates cached label colors when inherited foreground changes and clears', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100).withNodeType('Button');
      const child = root.append(new ReplayFrameNodeFixture(2, 10, 10, 10, 10, 80, 20).withNodeType('Text')
        .withInspector(new TextColorInspectorInfo('#CE000000', '#FFFFFFFF')));
      const collector = new ArkUIReplayCollector();
      const processor = new ReplaySnapshotProcessor();
      const first = collector.captureFrameNode(asFrameNode(root));
      processor.setFullSnapshotBaseline(first);
      const colors: Array<string> = ['#FF2563EB', '#00000001', '#FFFFFFFF'];
      const expected: Array<string> = ['#2563EBFF', '#000000CE', '#FFFFFFFF'];
      for (let index = 0; index < colors.length; index++) {
        child.withInspector(new TextColorInspectorInfo('#CE000000', colors[index]));
        const latest = collector.captureFrameNode(asFrameNode(root));
        const mutation = processor.createMutationRecord(latest);
        expect(mutation !== null).assertTrue();
        const data = mutation?.data as ReplayMutationData;
        expect(data.adds.length).assertEqual(0);
        expect(data.removes.length).assertEqual(0);
        expect(data.updates.length).assertEqual(1);
        expect(data.updates[0].textStyle?.color).assertEqual(expected[index]);
        expect(processor.createMutationRecord(latest) === null).assertTrue();
      }
      expect((findWireframe((first.data as FullSnapshotData).wireframes, 2) as ReplayTextWireframe)
        .textStyle.color).assertEqual('#FFFFFFFF');
    });

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
      // A runtime without overlay discovery must still capture supplied pages.
      const context = new EmptyInspectorInfo() as Object as UIContext;
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
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

    it('keeps window popup geometry above moving pages and removes closed cached overlays', 0, () => {
      const page = new ReplayFrameNodeFixture(1, 10, 20, 50, 20, 100, 100);
      const windowRoot = new ReplayFrameNodeFixture(10, 0, 0, 0, 0, 200, 200).withNodeType('root');
      const stage = windowRoot.append(new ReplayFrameNodeFixture(11, 0, 0, 0, 0, 200, 200).withNodeType('stage'));
      const popup = windowRoot.append(new ReplayFrameNodeFixture(12, 30, 50, 30, 50, 100, 100)
        .withNodeType('MenuWrapper'));
      const attrs: Record<string, Object> = { 'content': 'Popup option', 'fontColor': '#FF000000' };
      popup.append(new ReplayFrameNodeFixture(13, 90, 80, 90, 80, 40, 20).withNodeType('Text').withInspector(attrs));
      const context = new ReplayOverlayContextFixture(popup);
      const pages: Array<ArkUIReplayScenePage> = [
        { key: 'page', rootId: 'fixture-1', root: asFrameNode(page), retained: false }
      ];
      const viewport: ArkUIReplaySceneBounds = { x: 10, y: 20, width: 100, height: 100 };
      const collector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS));
      const capture = (): SessionReplayRecord => collector.materializeLightSnapshot(collector.captureSceneLight(
        context as Object as UIContext, [], 1, 1234, new Map(), viewport, pages));
      const first = capture();
      const frames = (first.data as FullSnapshotData).wireframes;
      const label = findWireframe(frames, 13) as ReplayTextWireframe;
      expect(label.text).assertEqual('Popup option');
      expect(label.x).assertEqual(80);
      expect(label.y).assertEqual(60);
      expect(label.clip?.right).assertEqual(20);
      expect((label.zIndex ?? 0) > (findWireframe(frames, 1)?.zIndex ?? 0)).assertTrue();
      expect((findWireframe(frames, 12) as ReplayShapeWireframe).shapeStyle?.backgroundColor === undefined).assertTrue();
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      page.moveTo(70, 20);
      const moving = capture();
      expect(findWireframe((moving.data as FullSnapshotData).wireframes, 13)?.x).assertEqual(80);
      expect(context.treeReads).assertEqual(1);
      processor.createMutationRecord(moving);
      windowRoot.removeChildren();
      windowRoot.append(stage);
      // A removed menu must not linger because it appeared in an old Inspector tree.
      const closed = capture();
      expect(findWireframe((closed.data as FullSnapshotData).wireframes, 13) === null).assertTrue();
      expect(context.treeReads).assertEqual(1);
      const changes = processor.createMutationRecord(closed)!.data as ReplayMutationData;
      expect(changes.removes.length).assertEqual(2);
      windowRoot.append(popup);
      const reopened = capture();
      expect(findWireframe((reopened.data as FullSnapshotData).wireframes, 13) !== null).assertTrue();
      expect(context.treeReads).assertEqual(1);
    });

    it('paints native menu material without changing the transparent wrapper or configured colors', 0, () => {
      const attrs: Record<string, Object> = {};
      attrs['backgroundColor'] = '#00000000';
      attrs['borderRadius'] = '{"topLeft":"20vp"}';
      const options: Record<string, Object> = { 'colorMode': 'ThemeColorMode.System', 'policy': 'BlurStyleActivePolicy.ALWAYS_ACTIVE' };
      const blur: Record<string, Object> = { 'value': 'BlurStyle.COMPONENT_ULTRA_THICK', 'options': options };
      attrs['backgroundBlurStyle'] = blur;
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 200, 400).withNodeType('MenuWrapper');
      const menu = root.append(new ReplayFrameNodeFixture(2, 10, 10, 10, 10, 160, 200).withNodeType('Menu').withInspector(attrs));
      const collector = new ArkUIReplayCollector();
      const capture = (dark: boolean = false): SessionReplayRecord => {
        const light = collector.captureFrameNodeLight(asFrameNode(root));
        for (const node of light.nodes) node.isDarkMode = dark;
        return collector.materializeLightSnapshot(light);
      };
      const first = capture();
      const panel = findWireframe((first.data as FullSnapshotData).wireframes, 2) as ReplayShapeWireframe;
      expect(panel.shapeStyle?.backgroundColor).assertEqual('#FFFFFFFF');
      expect(panel.shapeStyle?.cornerRadius).assertEqual(20);
      // Window-wide MenuWrapper keeps its own transparent chrome.
      const wrapperAttrs: Record<string, Object> = { 'backgroundColor': '#00000000' };
      root.withInspector(wrapperAttrs);
      expect((findWireframe((capture().data as FullSnapshotData).wireframes, 1) as ReplayShapeWireframe)
        .shapeStyle?.backgroundColor).assertEqual('#00000000');
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(capture());
      const dark = capture(true);
      expect((findWireframe((dark.data as FullSnapshotData).wireframes, 2) as ReplayShapeWireframe)
        .shapeStyle?.backgroundColor).assertEqual('#333333FF');
      const update = processor.createMutationRecord(dark)!.data as ReplayMutationData;
      expect(update.updates.length).assertEqual(1);
      expect(update.updates[0].shapeStyle?.backgroundColor).assertEqual('#333333FF');
      options['colorMode'] = 'ThemeColorMode.Light';
      expect((findWireframe((capture(true).data as FullSnapshotData).wireframes, 2) as ReplayShapeWireframe)
        .shapeStyle?.backgroundColor).assertEqual('#FFFFFFFF');
      attrs['backgroundColor'] = '#FF2563EB';
      expect((findWireframe((capture().data as FullSnapshotData).wireframes, 2) as ReplayShapeWireframe)
        .shapeStyle?.backgroundColor).assertEqual('#2563EBFF');
      attrs['backgroundColor'] = '#00000000';
      blur['value'] = 'BlurStyle.NONE';
      menu.withInspector(attrs);
      expect((findWireframe((capture().data as FullSnapshotData).wireframes, 2) as ReplayShapeWireframe)
        .shapeStyle?.backgroundColor).assertEqual('#00000000');
      blur['value'] = 'BlurStyle.COMPONENT_ULTRA_THICK';
      options['policy'] = 'BlurStyleActivePolicy.ALWAYS_INACTIVE';
      options['inactiveColor'] = '#FF22C55E';
      expect((findWireframe((capture().data as FullSnapshotData).wireframes, 2) as ReplayShapeWireframe)
        .shapeStyle?.backgroundColor).assertEqual('#22C55EFF');
    });

    it('uses Replay MIME subtypes while keeping the uploaded image resource MIME complete', 0, () => {
      const root = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 20, 20).withNodeType('Image');
      const collector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig().setImagePrivacy(ImagePrivacy.MASK_NONE));
      const png = new util.Base64Helper().decodeSync('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL9sAAAAASUVORK5CYII=');
      expect(collector.registerImageAsset('fixture-1', png, 'image/png')).assertTrue();
      const first = collector.captureFrameNode(asFrameNode(root));
      const image = (first.data as FullSnapshotData).wireframes[0] as ReplayImageWireframe;
      expect(image.mimeType).assertEqual('png');
      expect(image.isEmpty).assertFalse();
      const resources = collector.takeCapturedImageResources();
      expect(resources.length).assertEqual(1);
      expect(resources[0].mimeType).assertEqual('image/png');
      expect(resources[0].bytes.length).assertEqual(png.length);
    });

    it('prioritizes private-filtered popup nodes within the shared scene budget', 0, () => {
      const page = new ReplayFrameNodeFixture(1, 0, 0, 0, 0, 100, 100);
      for (let id = 2; id < 10; id++) page.append(new ReplayFrameNodeFixture(id, 0, 0, 0, 0, 20, 20));
      const popup = new ReplayFrameNodeFixture(12, 0, 0, 0, 0, 100, 100).withNodeType('MenuWrapper');
      const attrs: Record<string, Object> = { 'content': 'Private option' };
      popup.append(new ReplayFrameNodeFixture(13, 0, 0, 0, 0, 40, 20).withNodeType('Text').withInspector(attrs));
      const context = new ReplayOverlayContextFixture(popup);
      const pages: Array<ArkUIReplayScenePage> = [
        { key: 'page', rootId: 'fixture-1', root: asFrameNode(page), retained: false }
      ];
      const collector = new ArkUIReplayCollector(6, new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_ALL));
      const light = collector.captureSceneLight(context as Object as UIContext, [], 1, 1234, new Map(),
        { x: 0, y: 0, width: 100, height: 100 }, pages);
      expect(light.nodes.length).assertEqual(6);
      const data = collector.materializeLightSnapshot(light).data as FullSnapshotData;
      const label = findWireframe(data.wireframes, 13) as ReplayTextWireframe;
      expect(label !== null).assertTrue();
      expect(label.text.includes('Private')).assertFalse();
      context.tree = '{invalid';
      const fallback = collector.captureSceneLight(context as Object as UIContext, [], 1, 1234, new Map(),
        { x: 0, y: 0, width: 100, height: 100 }, pages);
      expect(fallback.nodes.length).assertEqual(6);
      expect(fallback.nodes.some((node): boolean => node.id === label.id)).assertFalse();
    });
  });
}
