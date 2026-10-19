import { describe, expect, it } from '@ohos/hypium';
import {
  ArkUIReplayLightNode, ArkUIReplayPageTransition, ArkUIReplaySceneBounds,
  ArkUIReplaySceneFrame, ArkUIReplayScenePage, SessionReplayScene
} from '../../main/ets/components/SessionReplayScene';

function page(key: string, retained: boolean = false, parentKey?: string): ArkUIReplayScenePage {
  return { key, rootId: key, root: null, retained, parentKey };
}

function frame(key: string, id: number, nativeX: number = 0, width: number = 100): ArkUIReplaySceneFrame {
  const node: ArkUIReplayLightNode = {
    id, x: 0, y: 0, width, height: 100, componentId: key, nodeType: 'Column',
    inspectorInfo: null, shouldCaptureAsText: false, isRoot: true, usedTransformedPosition: true,
    opacity: 1, clip: { top: 0, right: 0, bottom: 0, left: 0 }
  };
  return { key, bounds: { x: 0, y: 0, width, height: 100 }, nativeX, nativeY: 0, nodes: [node] };
}

export default function sessionReplaySceneUnitTest(): void {
  describe('SessionReplaySceneUnit', () => {
    it('reconstructs default Router entry from target-only geometry and settles at zero', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
      const incoming = page('incoming');
      incoming.defaultTransition = { entering: true, startedAt: 1000, durationMs: 450, translateXRatio: 0.5 };
      const positions: Array<number> = [];
      for (const timestamp of [1000, 1100, 1200, 1300, 1450, 1600]) {
        const nodes = scene.compose([incoming], [frame('incoming', 1)], viewport, new Map(), 10, timestamp);
        positions.push(nodes[0].x);
        expect(nodes[0].width).assertEqual(100);
        expect(nodes[0].clip?.right).assertEqual(nodes[0].x);
      }
      expect(positions[0]).assertEqual(50);
      expect(positions[1] < positions[0] && positions[1] > positions[2]).assertTrue();
      expect(positions[2] > positions[3] && positions[3] > 0).assertTrue();
      expect(positions[4]).assertEqual(0);
      expect(positions[5]).assertEqual(0);
    });

    it('keeps the default Push page clipping boundary aligned across surfaces and Navigation children', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
      const outgoing = page('old', true);
      const incoming = page('new');
      outgoing.defaultTransition = { entering: false, startedAt: 1000, durationMs: 450, translateXRatio: -0.2 };
      incoming.defaultTransition = { entering: true, startedAt: 1000, durationMs: 450, translateXRatio: 0.5 };
      const pages = [outgoing, incoming, page('destination', false, 'new')];
      for (const timestamp of [1000, 1100, 1200, 1450]) {
        const nodes = scene.compose(pages, [frame('old', 1), frame('new', 2), frame('destination', 3)],
          viewport, new Map(), 10, timestamp);
        const outgoingRight = nodes[0].x + nodes[0].width - (nodes[0].clip?.right ?? 0);
        const incomingLeft = nodes[1].x + (nodes[1].clip?.left ?? 0);
        expect(Math.abs(outgoingRight - incomingLeft) < 0.03).assertTrue();
        expect(nodes[2].clip?.left).assertEqual(nodes[1].clip?.left);
      }
    });

    it('prefers native default motion through completion and resets for a new animation', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
      const incoming = page('incoming');
      incoming.defaultTransition = { entering: true, startedAt: 1000, durationMs: 450, translateXRatio: 0.5 };
      expect(scene.compose([incoming], [frame('incoming', 1, 23)], viewport, new Map(), 10, 1050)[0].x).assertEqual(23);
      expect(scene.compose([incoming], [frame('incoming', 1)], viewport, new Map(), 10, 1100)[0].x).assertEqual(0);
      incoming.defaultTransition.startedAt = 2000;
      expect(scene.compose([incoming], [frame('incoming', 1)], viewport, new Map(), 10, 2000)[0].x).assertEqual(50);
      const actual = new Map<string, ArkUIReplayPageTransition>();
      actual.set('incoming', { entering: true, progress: 0.25, slide: SlideEffect.Right });
      expect(scene.compose([incoming], [frame('incoming', 1)], viewport, actual, 10, 2050)[0].x).assertEqual(75);
    });

    it('bounds detached default exit reconstruction and preserves Pop layering', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
      const returning = page('home');
      const outgoing = page('demo', true);
      returning.defaultTransition = { entering: true, startedAt: 1000, durationMs: 450, translateXRatio: -0.2 };
      outgoing.defaultTransition = { entering: false, startedAt: 1000, durationMs: 450, translateXRatio: 0.5 };
      const pages = [returning, outgoing];
      const first = scene.compose(pages, [frame('home', 1), frame('demo', 2, 50)], viewport, new Map(), 10, 1000);
      expect(first[0].x).assertEqual(-20);
      expect(first[1].x).assertEqual(0);
      const moving = scene.compose(pages, [frame('home', 1)], viewport, new Map(), 10, 1200);
      expect(moving.length).assertEqual(2);
      expect(moving[1].x > 0 && moving[1].x < 50).assertTrue();
      expect((moving[0].sceneLayer ?? 0) < (moving[1].sceneLayer ?? 0)).assertTrue();
      const ended = scene.compose(pages, [frame('home', 1)], viewport, new Map(), 10, 1450);
      expect(ended.length).assertEqual(1);
      expect(ended[0].x).assertEqual(0);
      expect(scene.compose(pages, [], viewport, new Map(), 10, 1600).length).assertEqual(0);
    });

    it('uses the original page width independently of the window or moving layout', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 300, height: 100 };
      const transitions = new Map<string, ArkUIReplayPageTransition>();
      transitions.set('incoming', { entering: true, progress: 0.25, slide: SlideEffect.Right });
      const first = scene.compose([page('incoming')], [frame('incoming', 1, 100)], viewport, transitions, 10);
      expect(first[0].x).assertEqual(75);
      transitions.set('incoming', { entering: true, progress: 0.5, slide: SlideEffect.Right });
      const second = scene.compose([page('incoming')], [frame('incoming', 1, 0, 200)], viewport, transitions, 10);
      expect(second[0].x).assertEqual(50);
      expect(second[0].width).assertEqual(200);
      expect(viewport.width).assertEqual(300);
    });

    it('continues an outgoing detached page from real progress and then releases it', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
      const transitions = new Map<string, ArkUIReplayPageTransition>();
      transitions.set('old', { entering: false, progress: 0.25, slide: SlideEffect.Left });
      const pages = [page('old', true), page('new')];
      const start = scene.compose(pages, [frame('old', 1), frame('new', 2)], viewport, transitions, 10);
      expect(start[0].x).assertEqual(-25);
      transitions.set('old', { entering: false, progress: 0.75, slide: SlideEffect.Left });
      const detached = scene.compose(pages, [frame('new', 2)], viewport, transitions, 10);
      expect(detached[0].id).assertEqual(1);
      expect(detached[0].x).assertEqual(-75);
      expect(detached[0].width).assertEqual(100);
      expect(detached[0].clip?.left).assertEqual(75);
      const ended = scene.compose([page('new')], [frame('new', 2)], viewport, new Map(), 10);
      expect(ended.length).assertEqual(1);
      expect(ended[0].id).assertEqual(2);
      // Once released, a stale retained descriptor cannot resurrect the page.
      expect(scene.compose([page('old', true)], [], viewport, transitions, 10).length).assertEqual(0);
    });

    it('does not revive an unretained hidden page and bounds detached memory', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
      scene.compose([page('old')], [frame('old', 1)], viewport, new Map(), 10);
      expect(scene.compose([page('old')], [], viewport, new Map(), 10).length).assertEqual(0);
      const limited = scene.compose([page('old', true), page('new')], [frame('new', 2)], viewport, new Map(), 1);
      expect(limited.length).assertEqual(1);
      expect(limited[0].id).assertEqual(2);
      scene.clear();
      expect(scene.compose([page('new', true)], [], viewport, new Map(), 10).length).assertEqual(0);
    });

    it('drops a half-exited default Router page when its native frame disappears', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
      const pages = [page('home'), page('demo', true)];
      const moving = scene.compose(pages, [frame('home', 1), frame('demo', 2, 50)], viewport, new Map(), 10);
      expect(moving[1].x).assertEqual(50);
      const hidden = scene.compose(pages, [frame('home', 1)], viewport, new Map(), 10);
      expect(hidden.length).assertEqual(1);
      expect(hidden[0].id).assertEqual(1);
      const successor = scene.compose([page('home'), page('demo', true), page('next')],
        [frame('home', 1), frame('next', 3)], viewport, new Map(), 10);
      expect(successor.length).assertEqual(2);
      expect(successor[1].id).assertEqual(3);
    });

    it('drops a detached page when exit progress completes before its descriptor is refreshed', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
      const transitions = new Map<string, ArkUIReplayPageTransition>();
      const pages = [page('home'), page('demo', true)];
      transitions.set('demo', { entering: false, progress: 0.5, slide: SlideEffect.Right });
      scene.compose(pages, [frame('home', 1), frame('demo', 2)], viewport, transitions, 10);
      transitions.set('demo', { entering: false, progress: 1, slide: SlideEffect.Right });
      const completed = scene.compose(pages, [frame('home', 1)], viewport, transitions, 10);
      expect(completed.length).assertEqual(1);
      expect(completed[0].id).assertEqual(1);
      expect(scene.compose([], [], viewport, transitions, 10).length).assertEqual(0);
    });

    it('inherits parent movement and fade once for separately captured Navigation pages', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
      const host = frame('host', 1, 100);
      const destination = frame('destination', 2, 100);
      host.nodes[0].opacity = 0.8;
      destination.nodes[0].x = 10;
      destination.nodes[0].opacity = 0.4;
      const transitions = new Map<string, ArkUIReplayPageTransition>();
      transitions.set('host', { entering: true, progress: 0.5, slide: SlideEffect.Right, opacity: 0 });
      const nodes = scene.compose([page('host'), page('destination', false, 'host')],
        [host, destination], viewport, transitions, 10);
      expect(nodes[0].x).assertEqual(50);
      expect(nodes[1].x).assertEqual(60);
      expect(nodes[1].opacity).assertEqual(0.2);
      expect(nodes[1].clip?.right).assertEqual(60);
    });

    it('normalizes window origin and leaves cached nodes unchanged', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 10, y: 20, width: 100, height: 100 };
      const source = frame('page', 1);
      source.nodes[0].x = 10;
      source.nodes[0].y = 20;
      source.nodes[0].clip = { top: 0, right: 0, bottom: 0, left: 5 };
      const first = scene.compose([page('page')], [source], viewport, new Map(), 10);
      expect(first[0].x).assertEqual(0);
      expect(first[0].y).assertEqual(0);
      expect(first[0].clip?.left).assertEqual(5);
      first[0].x = 999;
      first[0].clip!.left = 999;
      const transitions = new Map<string, ArkUIReplayPageTransition>();
      transitions.set('page', { entering: false, progress: 0 });
      const retained = scene.compose([page('page', true)], [], viewport, transitions, 10);
      expect(retained[0].x).assertEqual(0);
      expect(retained[0].clip?.left).assertEqual(5);
      expect(source.nodes[0].x).assertEqual(10);
    });

    it('keeps page layers stable on release and orders a returning page below the outgoing page', 0, () => {
      const scene = new SessionReplayScene();
      const viewport: ArkUIReplaySceneBounds = { x: 0, y: 0, width: 100, height: 100 };
      const first = scene.compose([page('old', true), page('new')],
        [frame('old', 1), frame('new', 2)], viewport, new Map(), 10);
      const outgoingLayer = first[1].sceneLayer ?? 0;
      expect((first[0].sceneLayer ?? 0) < outgoingLayer).assertTrue();
      const released = scene.compose([page('new')], [frame('new', 2)], viewport, new Map(), 10);
      expect(released[0].sceneLayer).assertEqual(outgoingLayer);
      const returning = scene.compose([page('old'), page('new', true)],
        [frame('old', 1), frame('new', 2)], viewport, new Map(), 10);
      expect((returning[0].sceneLayer ?? 0) < outgoingLayer).assertTrue();
      expect(returning[1].sceneLayer).assertEqual(outgoingLayer);
    });
  });
}
