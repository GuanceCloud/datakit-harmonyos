import { beforeAll, afterAll, describe, expect, it } from '@ohos/hypium';
import { Driver, ON } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import window from '@ohos.window';
import { UIContext } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { FTSDK, FTRUMConfig } from '@guancecloud/ft_sdk';
import {
  FTSessionReplay, FTSessionReplayConfig, TextAndInputPrivacy, ImagePrivacy, TouchPrivacy,
  FullSnapshotData, ReplayMutationData, ReplayPointerInteractionData, ReplayRecordType,
  ReplayWireframe, ReplayWireframeUpdate, SessionReplayContext, SessionReplayRecord
} from '@guancecloud/ft_session_replay';

function applyUpdate(node: ReplayWireframe, update: ReplayWireframeUpdate): void {
  expect(node.type).assertEqual(update.type);
  if (update.x !== undefined) node.x = update.x;
  if (update.y !== undefined) node.y = update.y;
  if (update.width !== undefined) node.width = update.width;
  if (update.height !== undefined) node.height = update.height;
  if (update.clip !== undefined) node.clip = update.clip;
  if (update.zIndex !== undefined) node.zIndex = update.zIndex;
  if (node.type === 'placeholder') {
    if (update.label !== undefined) node.label = update.label;
  } else {
    if (update.shapeStyle !== undefined) node.shapeStyle = update.shapeStyle;
    if (update.border !== undefined) node.border = update.border;
    if (node.type === 'text') {
      if (update.text !== undefined) node.text = update.text;
      if (update.textStyle !== undefined) node.textStyle = update.textStyle;
      if (update.textPosition !== undefined) node.textPosition = update.textPosition;
    } else if (node.type === 'image') {
      if (update.base64 !== undefined) node.base64 = update.base64;
      if (update.resourceId !== undefined) node.resourceId = update.resourceId;
      if (update.mimeType !== undefined) node.mimeType = update.mimeType;
      if (update.isEmpty !== undefined) node.isEmpty = update.isEmpty;
      if (update.imageStyle !== undefined) node.imageStyle = update.imageStyle;
    }
  }
}

function replayNodes(records: Array<SessionReplayRecord>): Array<ReplayWireframe> {
  let nodes: Array<ReplayWireframe> = [];
  for (const record of records) {
    if (record.slotId !== undefined) continue;
    if (record.type === ReplayRecordType.FULL_SNAPSHOT) {
      nodes = JSON.parse(JSON.stringify((record.data as FullSnapshotData).wireframes)) as Array<ReplayWireframe>;
    } else if (record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT) {
      const mutation = record.data as ReplayMutationData;
      if (mutation.source !== 0) continue;
      for (const removed of mutation.removes) {
        const index = nodes.findIndex((node: ReplayWireframe): boolean => node.id === removed.id);
        expect(index >= 0).assertTrue();
        nodes.splice(index, 1);
      }
      for (const added of mutation.adds) {
        expect(nodes.some((node: ReplayWireframe): boolean => node.id === added.wireframe.id)).assertFalse();
        const index = added.previousId === undefined ? -1 :
          nodes.findIndex((node: ReplayWireframe): boolean => node.id === added.previousId);
        if (added.previousId !== undefined) expect(index >= 0).assertTrue();
        nodes.splice(index + 1, 0, JSON.parse(JSON.stringify(added.wireframe)) as ReplayWireframe);
      }
      for (const update of mutation.updates) {
        const index = nodes.findIndex((candidate: ReplayWireframe): boolean => candidate.id === update.id);
        expect(index >= 0).assertTrue();
        applyUpdate(nodes[index], update);
      }
    }
  }
  return nodes;
}

export default function sessionReplayMutationUITest(): void {
  describe('SessionReplayMutationUITest', () => {
    const replay = FTSessionReplay.getInstance();
    let driver: Driver;
    let uiContext: UIContext;
    let context: SessionReplayContext;
    let rootId: string = 'session-replay-transition-root';

    const click = async (id: string): Promise<void> => {
      let component = await driver.findComponent(ON.id(id));
      if (component === null) {
        const scroll = await driver.findComponent(ON.type('Scroll'));
        if (scroll === null) throw new Error('Replay test Scroll is missing');
        component = await scroll.scrollSearch(ON.id(id));
      }
      if (component === null) throw new Error(`Replay test component is missing: ${id}`);
      await component.click();
    };

    const waitForCapture = async (after: number): Promise<void> => {
      for (let index = 0; index < 30; index++) {
        if ((replay.getLastCapture()?.record.timestamp ?? 0) > after) return;
        await driver.delayMs(100);
      }
      throw new Error('Replay did not capture the page update');
    };

    const waitForViewCapture = async (previousViewId: string): Promise<void> => {
      for (let index = 0; index < 100; index++) {
        const capture = replay.getLastCapture();
        if (capture !== null && capture.envelope.view_id !== previousViewId) return;
        await driver.delayMs(100);
      }
      throw new Error(`Replay did not save the new View: ${replay.getLastCaptureFailure()}`);
    };

    const assertCurrentSnapshot = (): SessionReplayRecord => {
      const last = replay.getLastCapture()!;
      context = { applicationId: last.envelope.application_id, sessionId: last.envelope.session_id,
        viewId: last.envelope.view_id };
      const records = replay.getRecordedRecords(context);
      const snapshot = replay.captureFullSnapshot(uiContext, rootId, context, vp2px(1)).record;
      const actual = replayNodes(records);
      const expected = (snapshot.data as FullSnapshotData).wireframes;
      if (actual.length !== expected.length) {
        throw new Error(`Snapshot node counts differ for ${context.viewId}: actual=${actual.length}, expected=${expected.length}; actualIds=${JSON.stringify(actual.map((node: ReplayWireframe): string => node.permanentId ?? String(node.id)))}, expectedIds=${JSON.stringify(expected.map((node: ReplayWireframe): string => node.permanentId ?? String(node.id)))}`);
      }
      for (let index = 0; index < expected.length; index++) {
        expect(actual[index].id).assertEqual(expected[index].id);
        if (JSON.stringify(actual[index]) !== JSON.stringify(expected[index])) {
          throw new Error(`Wireframe ${expected[index].id} differs: actual=${JSON.stringify(actual[index])}, expected=${JSON.stringify(expected[index])}`);
        }
      }
      return snapshot;
    };

    const positions = (records: Array<SessionReplayRecord>, id: string, after: number): Array<number> => {
      const result: Array<number> = [];
      for (let index = 0; index < records.length; index++) {
        const record = records[index];
        if (record.timestamp <= after || (record.type !== ReplayRecordType.FULL_SNAPSHOT &&
          (record.type !== ReplayRecordType.INCREMENTAL_SNAPSHOT || (record.data as ReplayMutationData).source !== 0))) continue;
        const node = replayNodes(records.slice(0, index + 1)).find((candidate: ReplayWireframe): boolean => candidate.permanentId === id);
        if (node !== undefined) result.push(node.x);
      }
      return result;
    };

    const waitForSettledScene = async (view: SessionReplayContext, incomingId: string, outgoingId: string): Promise<void> => {
      for (let index = 0; index < 100; index++) {
        const nodes = replayNodes(replay.getRecordedRecords(view));
        const incoming = nodes.find((node: ReplayWireframe): boolean => node.permanentId === incomingId);
        if (incoming !== undefined && Math.abs(incoming.x) < 0.1 &&
          !nodes.some((node: ReplayWireframe): boolean => node.permanentId === outgoingId)) return;
        await driver.delayMs(100);
      }
      throw new Error(`Replay did not save the settled Router scene: ${replay.getLastCaptureFailure()}`);
    };

    const scrollTo = async (id: string): Promise<void> => {
      const scroll = await driver.findComponent(ON.type('Scroll'));
      expect(await scroll!.scrollSearch(ON.id(id)) !== null).assertTrue();
      await driver.delayMs(1000);
    };

    const assertIntermediateValues = (values: Array<number>, label: string): void => {
      if (new Set<number>(values).size < 4) throw new Error(`${label} lacks intermediate values: ${JSON.stringify(values)}`);
    };

    beforeAll(async () => {
      driver = Driver.create();
      const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
      const bundleName = AbilityDelegatorRegistry.getArguments().bundleName;
      await delegator.startAbility({ bundleName, abilityName: 'EntryAbility', moduleName: 'entry' });
      let page = await driver.findComponent(ON.text('Session Replay Demo'));
      for (let index = 0; page === null && index < 30; index++) {
        await driver.delayMs(200);
        page = await driver.findComponent(ON.text('Session Replay Demo'));
      }
      if (page === null) throw new Error('Demo home is unavailable');
      FTSDK.setAutoSync(false);
      if (FTSDK.getRumConfig() === null) {
        FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('replay-mutation-regression')
          .setEnableTraceUserView(true));
      }
      const replayTestDir = `${delegator.getAppContext().filesDir}/replay-mutation-ui-${Date.now()}`;
      fileIo.mkdirSync(replayTestDir);
      replay.init(new FTSessionReplayConfig().setSampleRate(1).setDelayInit(true).setUploadIntervalMs(0)
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setImagePrivacy(ImagePrivacy.MASK_NONE)
        .setTouchPrivacy(TouchPrivacy.SHOW),
        replayTestDir);
      await page.click();
      await driver.delayMs(800);
      const enable = await driver.findComponent(ON.text('Enable Session Replay'));
      if (enable === null) throw new Error('Replay Enable button is unavailable');
      await enable.click();
      await waitForCapture(0);
      // Entry's delayed enable can initially attach to the outgoing Home View.
      // Wait for the animated navigation's native View/root binding to finish.
      await driver.delayMs(1600);
      const functionalViewId = replay.getLastCapture()!.envelope.view_id;
      await click('session-replay-transition-button');
      await waitForViewCapture(functionalViewId);
      await driver.delayMs(1400);
      const capture = replay.getLastCapture()!;
      context = { applicationId: capture.envelope.application_id,
        sessionId: capture.envelope.session_id, viewId: capture.envelope.view_id };
      const ability = await delegator.getCurrentTopAbility();
      uiContext = (await window.getLastWindow(ability.context)).getUIContext();
    });

    afterAll(() => { replay.disable(); });

    it('captures fixed-size text changes without an explicit Replay notification', 0, async () => {
      // Scroll into view before taking the baseline; only text changes after it.
      const scroll = await driver.findComponent(ON.type('Scroll'));
      expect(scroll !== null).assertTrue();
      expect(await scroll!.scrollSearch(ON.id('session-replay-fixed-text-button')) !== null).assertTrue();
      await driver.delayMs(1000);
      const baseline = assertCurrentSnapshot();
      await driver.delayMs(200);
      await click('session-replay-fixed-text-button');
      await waitForCapture(baseline.timestamp);
      await driver.delayMs(600);
      const capture = replay.getLastCapture()!;
      expect(capture.record.type).assertEqual(ReplayRecordType.INCREMENTAL_SNAPSHOT);
      const mutation = capture.record.data as ReplayMutationData;
      expect(mutation.source).assertEqual(0);
      expect(mutation.updates.some((update: ReplayWireframeUpdate): boolean => update.text === 'Replay text B')).assertTrue();
      const latest = assertCurrentSnapshot();
      const previousRoot = (baseline.data as FullSnapshotData).wireframes[0];
      const latestRoot = (latest.data as FullSnapshotData).wireframes[0];
      expect(latestRoot.width).assertEqual(previousRoot.width);
      expect(latestRoot.height).assertEqual(previousRoot.height);
    });

    it('replays reordered native nodes in the same order as a fresh snapshot', 0, async () => {
      const scroll = await driver.findComponent(ON.type('Scroll'));
      expect(await scroll!.scrollSearch(ON.id('session-replay-reorder-button')) !== null).assertTrue();
      await driver.delayMs(1000);
      const baseline = assertCurrentSnapshot();
      await driver.delayMs(200);
      await click('session-replay-reorder-button');
      await waitForCapture(baseline.timestamp);
      await driver.delayMs(600);
      expect(replay.getLastCapture()!.record.type).assertEqual(ReplayRecordType.INCREMENTAL_SNAPSHOT);
      assertCurrentSnapshot();
    });

    it('keeps manual and automatic native captures on the same baseline', 0, async () => {
      const scroll = await driver.findComponent(ON.type('Scroll'));
      expect(await scroll!.scrollSearch(ON.id('session-replay-fixed-text-button')) !== null).assertTrue();
      await driver.delayMs(1000);
      const baseline = assertCurrentSnapshot();
      await driver.delayMs(200);
      await click('session-replay-fixed-text-button');
      await driver.delayMs(50);
      replay.captureIncrementalSnapshot(uiContext, rootId, context, vp2px(1));
      await waitForCapture(baseline.timestamp);
      await driver.delayMs(1000);
      assertCurrentSnapshot();
    });

    it('records real down move up coordinates from a swipe', 0, async () => {
      await scrollTo('session-replay-touch-pad');
      const pad = await driver.findComponent(ON.id('session-replay-touch-pad'));
      const bounds = await pad!.getBounds();
      const x = Math.round((bounds.left + bounds.right) / 2);
      const y = bounds.bottom - 20;
      const baseline = assertCurrentSnapshot();
      await driver.delayMs(200);
      await driver.swipe(x, y, x + 40, bounds.top + 20, 200);
      await driver.delayMs(1000);
      const pointers = replay.getRecordedRecords(context).filter((record: SessionReplayRecord): boolean =>
        record.timestamp > baseline.timestamp && record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT &&
        (record.data as ReplayPointerInteractionData).source === 9);
      expect(pointers.length >= 3).assertTrue();
      const down = pointers[0].data as ReplayPointerInteractionData;
      expect(down.pointerEventType).assertEqual('down');
      expect(Math.abs(down.x * vp2px(1) - x) < 5).assertTrue();
      expect(Math.abs(down.y * vp2px(1) - y) < 5).assertTrue();
      expect(pointers.some((record: SessionReplayRecord): boolean =>
        (record.data as ReplayPointerInteractionData).pointerEventType === 'move')).assertTrue();
      expect((pointers[pointers.length - 1].data as ReplayPointerInteractionData).pointerEventType).assertEqual('up');
      expect(new Set<number>(pointers.map((record: SessionReplayRecord): number =>
        (record.data as ReplayPointerInteractionData).y)).size >= 3).assertTrue();
      assertCurrentSnapshot();
    });

    it('retains Swiper positions during an animated slide change', 0, async () => {
      await scrollTo('session-replay-swiper-next');
      const baseline = assertCurrentSnapshot();
      await driver.delayMs(200);
      await click('session-replay-swiper-next');
      await driver.delayMs(1400);
      const values = positions(replay.getRecordedRecords(context), 'session-replay-slide-a', baseline.timestamp);
      assertIntermediateValues(values, 'Swiper');
      assertCurrentSnapshot();
    });

    it('retains intermediate translation and opacity values', 0, async () => {
      await scrollTo('session-replay-animation-button');
      const baseline = assertCurrentSnapshot();
      await driver.delayMs(200);
      await click('session-replay-animation-button');
      await driver.delayMs(1400);
      const records = replay.getRecordedRecords(context);
      const values = positions(records, 'session-replay-moving-probe', baseline.timestamp);
      assertIntermediateValues(values, 'Translation');
      const opacityValues: Array<number> = [];
      for (let index = 0; index < records.length; index++) {
        if (records[index].timestamp <= baseline.timestamp) continue;
        const probe = replayNodes(records.slice(0, index + 1)).find((node: ReplayWireframe): boolean =>
          node.permanentId === 'session-replay-moving-probe');
        if (probe !== undefined && probe.type !== 'placeholder' && probe.shapeStyle?.opacity !== undefined) {
          opacityValues.push(probe.shapeStyle.opacity);
        }
      }
      assertIntermediateValues(opacityValues, 'Opacity');
      assertCurrentSnapshot();
    });

    it('capturesDefaultRouterPushAndPopWithoutExplicitTransitionEffects', 0, async () => {
      const componentViewId = context.viewId;
      await click('session-replay-transition-back');
      await waitForViewCapture(componentViewId);
      await driver.delayMs(1400);
      const functionalCapture = replay.getLastCapture()!;
      context = { applicationId: functionalCapture.envelope.application_id,
        sessionId: functionalCapture.envelope.session_id, viewId: functionalCapture.envelope.view_id };
      rootId = 'session-replay-poc-root';
      await scrollTo('session-replay-default-transition-button');
      // Establish a fresh outgoing baseline after UiTest's programmatic
      // scrollSearch, which does not forward touch-based motion signals.
      const baseline = replay.captureFullSnapshot(uiContext, rootId, context, vp2px(1)).record;
      await driver.delayMs(200);
      await click('session-replay-default-transition-button');
      await driver.delayMs(1400);
      await waitForViewCapture(context.viewId);
      const capture = replay.getLastCapture()!;
      const nextContext: SessionReplayContext = { applicationId: capture.envelope.application_id,
        sessionId: capture.envelope.session_id, viewId: capture.envelope.view_id };
      expect(nextContext.viewId !== context.viewId).assertTrue();
      await waitForSettledScene(nextContext, 'session-replay-default-root', 'session-replay-poc-root');
      const records = replay.getRecordedRecords(nextContext);
      assertIntermediateValues(positions(records, 'session-replay-default-root', baseline.timestamp), 'Default Router push');
      expect(records.some((_record: SessionReplayRecord, index: number): boolean => {
        const nodes = replayNodes(records.slice(0, index + 1));
        return nodes.some((node: ReplayWireframe): boolean => node.permanentId === 'session-replay-poc-root') &&
          nodes.some((node: ReplayWireframe): boolean => node.permanentId === 'session-replay-default-root');
      })).assertTrue();
      expect(replayNodes(records).some((node: ReplayWireframe): boolean =>
        node.permanentId === 'session-replay-poc-root')).assertFalse();
      await click('session-replay-default-back');
      await driver.delayMs(1400);
      await waitForViewCapture(nextContext.viewId);
      const returned = replay.getLastCapture()!;
      context = { applicationId: returned.envelope.application_id, sessionId: returned.envelope.session_id,
        viewId: returned.envelope.view_id };
      await waitForSettledScene(context, 'session-replay-poc-root', 'session-replay-default-root');
      const returnedRecords = replay.getRecordedRecords(context);
      assertIntermediateValues(positions(returnedRecords, 'session-replay-default-root', baseline.timestamp), 'Default Router pop');
      expect(replayNodes(returnedRecords).some((node: ReplayWireframe): boolean =>
        node.permanentId === 'session-replay-default-root')).assertFalse();
      assertCurrentSnapshot();
    });

    it('captures overlapping pages through Router push and pop animations', 0, async () => {
      await scrollTo('session-replay-transition-button');
      const baseline = assertCurrentSnapshot();
      await driver.delayMs(200);
      await click('session-replay-transition-button');
      await driver.delayMs(1400);
      const capture = replay.getLastCapture()!;
      const nextContext: SessionReplayContext = { applicationId: capture.envelope.application_id,
        sessionId: capture.envelope.session_id, viewId: capture.envelope.view_id };
      expect(nextContext.viewId !== context.viewId).assertTrue();
      const nextRecords = replay.getRecordedRecords(nextContext);
      assertIntermediateValues(positions(nextRecords, 'session-replay-transition-destination', baseline.timestamp), 'Router push');
      let overlap = false;
      for (let index = 0; index < nextRecords.length; index++) {
        const nodes = replayNodes(nextRecords.slice(0, index + 1));
        if (nodes.some((node: ReplayWireframe): boolean => node.permanentId === 'session-replay-poc-root') &&
          nodes.some((node: ReplayWireframe): boolean => node.permanentId === 'session-replay-transition-root')) overlap = true;
      }
      expect(overlap).assertTrue();
      await click('session-replay-transition-back');
      await driver.delayMs(1400);
      const returned = replay.getLastCapture()!;
      context = { applicationId: returned.envelope.application_id,
        sessionId: returned.envelope.session_id, viewId: returned.envelope.view_id };
      assertIntermediateValues(positions(replay.getRecordedRecords(context), 'session-replay-transition-root', baseline.timestamp), 'Router pop');
      assertCurrentSnapshot();
    });

    it('keepsLastPageVisibleAfterReturningFromControlsAndDisablingReplay', 0, async () => {
      const componentPage = await driver.findComponent(ON.id('session-replay-transition-back'));
      if (componentPage !== null) {
        const previousViewId = replay.getLastCapture()!.envelope.view_id;
        await componentPage.click();
        await waitForViewCapture(previousViewId);
      }
      await driver.delayMs(1400);
      const capture = replay.getLastCapture()!;
      const returnedContext: SessionReplayContext = { applicationId: capture.envelope.application_id,
        sessionId: capture.envelope.session_id, viewId: capture.envelope.view_id };
      await waitForSettledScene(returnedContext, 'session-replay-poc-root', 'session-replay-transition-root');
      await click('session-replay-enable-button');
      expect(replay.isEnabled()).assertFalse();

      let records: Array<SessionReplayRecord> = [];
      for (let attempt = 0; attempt < 50; attempt++) {
        records = [];
        for (const segment of replay.getStoredSegments()) {
          if (segment.context.viewId === returnedContext.viewId) records.push(...segment.records);
        }
        records.sort((left: SessionReplayRecord, right: SessionReplayRecord): number => left.timestamp - right.timestamp);
        if (records.some((record: SessionReplayRecord): boolean => record.type === ReplayRecordType.VIEW_END)) break;
        await driver.delayMs(100);
      }
      expect(records[records.length - 1].type).assertEqual(ReplayRecordType.VIEW_END);
      const nodes = replayNodes(records);
      const canvas = nodes.find((node: ReplayWireframe): boolean => node.permanentId === 'ft-session-replay-scene');
      expect(canvas !== undefined && canvas.zIndex !== undefined).assertTrue();
      expect(nodes.some((node: ReplayWireframe): boolean => node.permanentId === 'session-replay-poc-root')).assertTrue();
      expect(nodes.some((node: ReplayWireframe): boolean => node.type === 'text' && node.text === 'Disable Session Replay')).assertTrue();
      expect(nodes.filter((node: ReplayWireframe): boolean => node.id !== canvas!.id)
        .every((node: ReplayWireframe): boolean => node.zIndex !== undefined && node.zIndex > canvas!.zIndex!)).assertTrue();
      expect(records.every((record: SessionReplayRecord): boolean => {
        if (record.type !== ReplayRecordType.INCREMENTAL_SNAPSHOT) return true;
        const mutation = record.data as ReplayMutationData;
        return mutation.source !== 0 || !mutation.removes.some((removed): boolean => removed.id === canvas!.id);
      })).assertTrue();
    });
  });
}
