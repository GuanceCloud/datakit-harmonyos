import { describe, it, expect } from '@ohos/hypium';
import { Constants } from '../../main/ets/components/Constants';
import { ActionBean } from '../../main/ets/components/db/bean/ActionBean';
import { SyncData } from '../../main/ets/components/db/bean/SyncData';
import { ViewBean } from '../../main/ets/components/db/bean/ViewBean';
import { DataType } from '../../main/ets/components/enum/Enums';

class DbObjectValue {
  public value: string;

  constructor(value: string) {
    this.value = value;
  }
}

class DbCircularAttr {
  public value: string = 'circular';
  public self?: DbCircularAttr;
}

export default function dbBeanModelUnitTest() {
  describe('DbBeanModelUnit', () => {
    it('actionBeanShouldCoverFieldsJsonCountersCloneAndBranches', 0, () => {
      const action = new ActionBean('action-id', 'tap button', 'click', 100);
      const extraAttr = new Map<string, object>();
      extraAttr.set('object_attr', new DbObjectValue('object') as Object);

      action.setId('action-id-2');
      action.setActionName('tap submit');
      action.setActionType('tap');
      action.setActionDuration(12);
      action.setIsClose(true);
      action.setErrorCount(1);
      action.setLongTaskCount(2);
      action.setResourceCount(3);
      action.setPendingResource(1);
      action.setSessionId('direct-session');
      action.setViewName('direct-view');
      action.setViewId('direct-view-id');
      action.setViewReferrer('direct-referrer');
      action.setSessionInfo('session-id');
      action.setViewInfo('view-name', 'view-id', 'referrer');
      action.setExtraAttr(extraAttr);
      action.addExtraAttr('string_attr', 'tag-value' as Object);

      const jsonText = action.getAttrJsonString();
      action.setAttrJsonString('{"role":"admin","count":2}');
      expect(String(action.getExtraAttr().get('role'))).assertEqual('admin');
      action.setAttrJsonString('{bad json');
      expect(String(action.getExtraAttr().get('role'))).assertEqual('admin');
      action.setAttrJsonString('');
      expect(String(action.getExtraAttr().get('role'))).assertEqual('admin');
      const circularAttr = new DbCircularAttr();
      circularAttr.self = circularAttr;
      action.addExtraAttr('circular_attr', circularAttr as Object);
      expect(action.getAttrJsonString()).assertEqual('{}');
      action.setAttrJsonString('{"role":"admin","count":2}');

      action.incrementErrorCount();
      action.incrementLongTaskCount();
      action.incrementResourceCount();
      action.incrementPendingResource();
      action.decrementPendingResource();
      action.decrementPendingResource();
      action.decrementPendingResource();
      action.calculateDuration();

      expect(action.getId()).assertEqual('action-id-2');
      expect(action.getStartTime()).assertEqual(100);
      expect(action.getActionName()).assertEqual('tap submit');
      expect(action.getActionType()).assertEqual('tap');
      expect(action.getSessionId()).assertEqual('session-id');
      expect(action.getViewName()).assertEqual('view-name');
      expect(action.getViewId()).assertEqual('view-id');
      expect(action.getViewReferrer()).assertEqual('referrer');
      expect(action.getIsClose()).assertTrue();
      expect(action.getActionDuration()).assertEqual(12);
      expect(action.getErrorCount()).assertEqual(2);
      expect(action.getLongTaskCount()).assertEqual(3);
      expect(action.getResourceCount()).assertEqual(4);
      expect(action.getPendingResource()).assertEqual(0);
      expect(jsonText.includes('object_attr')).assertTrue();
      expect(action.isValid()).assertTrue();
      expect(new ActionBean('', '', '', 0).isValid()).assertFalse();

      const roundTrip = ActionBean.fromJSON(action.toJSON());
      const cloned = roundTrip.clone();
      expect(cloned.getId()).assertEqual('action-id-2');
      expect(cloned.getDuration()).assertEqual(12);
      expect(String(cloned.getTags()['role'])).assertEqual('admin');
      expect(Number(cloned.getProperty()['count'])).assertEqual(2);
      expect(cloned.toString().includes('tap submit')).assertTrue();
      expect(ActionBean.fromJSON(JSON.parse('{"id":"fallback","actionName":"name","actionType":"type"}')).getStartTime() > 0)
        .assertTrue();

      const openAction = new ActionBean('open', 'open', 'tap', 1);
      openAction.calculateDuration();
      expect(openAction.getDuration() > 0).assertTrue();
      openAction.close();
      expect(openAction.getIsClose()).assertTrue();
      expect(openAction.getDuration() > 0).assertTrue();
    });

    it('syncDataShouldCoverJsonCloneValidityPackageIdAndReset', 0, () => {
      const syncData = new SyncData(DataType.LOG);
      syncData.setId(7);
      syncData.setUuid('uuid-1');
      syncData.setDataString('df_rum_harmonyos_log,sdk_data_id=uuid-1 value=1i 100');
      syncData.setTime(100);
      syncData.setCustomDataTypeString('log_error_sampled');

      expect(syncData.getId()).assertEqual(7);
      expect(syncData.getDataType()).assertEqual(DataType.LOG);
      expect(syncData.getDataTypeString()).assertEqual(DataType.LOG.toString());
      expect(syncData.getCustomDataTypeString()).assertEqual('log_error_sampled');
      expect(syncData.getLineProtocolDataWithPkgId('pkg')).assertEqual(
        'df_rum_harmonyos_log,sdk_data_id=pkg.uuid-1 value=1i 100'
      );
      expect(syncData.getLineProtocolDataWithPkgId('')).assertEqual(syncData.getDataString());
      expect(syncData.isValid()).assertTrue();

      const cloned = syncData.clone();
      const roundTrip = SyncData.fromJSON(syncData.toJSON());
      expect(cloned.toString().includes('df_rum_harmonyos_log')).assertTrue();
      expect(cloned.getUuid()).assertEqual('uuid-1');
      expect(roundTrip.getId()).assertEqual(7);
      expect(roundTrip.getDataString()).assertEqual(syncData.getDataString());

      const fallback = SyncData.fromJSON(JSON.parse('{"dataType":"log"}'));
      expect(fallback.getId()).assertEqual(0);
      expect(fallback.getDataString()).assertEqual('');
      expect(fallback.getTime() > 0).assertTrue();

      syncData.reset();
      expect(syncData.isValid()).assertFalse();
      expect(syncData.getId()).assertEqual(0);
      expect(syncData.getUuid()).assertEqual('');
      expect(syncData.getDataString()).assertEqual('');
      expect(syncData.getTime() > 0).assertTrue();
    });

    it('viewBeanShouldCoverFieldsMonitorJsonCountersCloneAndBranches', 0, () => {
      const view = new ViewBean('view-id', 'Home', 100);
      const extraAttr = new Map<string, object>();
      const property: Record<string, object> = {};
      const tags: Record<string, string> = {};
      property['screen'] = 'home' as Object;
      tags['env'] = 'test';
      extraAttr.set('custom_attr', 'custom' as Object);

      view.setId('view-id-2');
      view.setViewName('Detail');
      view.setViewReferrer('Home');
      view.setIsClose(false);
      view.setSessionId('session-id');
      view.setActionCount(1);
      view.setErrorCount(2);
      view.setLongTaskCount(3);
      view.setViewLoadTime(4);
      view.setTimeSpent(5);
      view.setResourceCount(6);
      view.setPendingResource(1);
      view.setDataUpdateTime(7);
      view.setDataUploadTime(8);
      view.setViewUpdateTime(9);
      view.setExtraAttr(extraAttr);
      view.addExtraAttr('another_attr', new DbObjectValue('another') as Object);
      view.setProperty(property);
      view.setTags(tags);
      view.setBatteryCurrentMax(11);
      view.setBatteryCurrentAvg(12);
      view.setCpuTickCount(13);
      view.setCpuTickCountPerSecond(14);
      view.setFpsMini(15);
      view.setFpsAvg(16);
      view.setMemoryMax(17);
      view.setMemoryAvg(18);

      const attrJson = view.getAttrJsonString();
      view.setAttrJsonString('{"plain":"value","property":{"p":1},"tags":{"t":"yes"}}');
      expect(String(view.getExtraAttr().get('plain'))).assertEqual('value');
      expect(Number(view.getProperty()['p'])).assertEqual(1);
      expect(view.getTags()['t']).assertEqual('yes');
      view.setAttrJsonString('{bad json');
      expect(String(view.getExtraAttr().get('plain'))).assertEqual('value');

      view.incrementActionCount();
      view.incrementErrorCount();
      view.incrementLongTaskCount();
      view.incrementResourceCount();
      view.incrementPendingResource();
      view.decrementPendingResource();
      view.decrementPendingResource();
      view.decrementPendingResource();
      view.calculateLoadTime();
      view.calculateTimeSpent();
      view.markAsUploaded();
      view.updateView();
      view.setLastErrorTime(999);

      expect(view.getId()).assertEqual('view-id-2');
      expect(view.getViewName()).assertEqual('Detail');
      expect(view.getViewReferrer()).assertEqual('Home');
      expect(view.getStartTime()).assertEqual(100);
      expect(view.getIsClose()).assertFalse();
      expect(view.getSessionId()).assertEqual('session-id');
      expect(view.getActionCount()).assertEqual(2);
      expect(view.getErrorCount()).assertEqual(3);
      expect(view.getLongTaskCount()).assertEqual(4);
      expect(view.getResourceCount()).assertEqual(7);
      expect(view.getPendingResource()).assertEqual(0);
      expect(view.getViewLoadTime() > 0).assertTrue();
      expect(view.getTimeSpent() > 0).assertTrue();
      expect(view.getDataUpdateTime() > 0).assertTrue();
      expect(view.getDataUploadTime() > 0).assertTrue();
      expect(view.getViewUpdateTime()).assertEqual(10);
      expect(view.getLastErrorTime()).assertEqual(999);
      expect(view.isValid()).assertTrue();
      expect(new ViewBean('', '', 0).isValid()).assertFalse();
      expect(attrJson.includes(Constants.KEY_RUM_PROPERTY)).assertTrue();
      expect(view.getExtraAttr().has('battery_current_max')).assertFalse();

      const roundTrip = ViewBean.fromJSON(view.toJSON());
      const cloned = roundTrip.clone();
      expect(cloned.getId()).assertEqual('view-id-2');
      expect(cloned.getTags()['t']).assertEqual('yes');
      expect(Number(cloned.getProperty()['p'])).assertEqual(1);
      expect(cloned.toString().includes('Detail')).assertTrue();

      const fallback = ViewBean.fromJSON(JSON.parse('{"id":"fallback","viewName":"Fallback"}'));
      expect(fallback.getStartTime() > 0).assertTrue();
      expect(fallback.getViewUpdateTime()).assertEqual(1);

      view.setTags(JSON.parse('null') as Record<string, string>);
      view.setProperty(JSON.parse('null') as Record<string, object>);
      expect(Object.keys(view.getTags()).length).assertEqual(0);
      expect(Object.keys(view.getProperty()).length).assertEqual(0);

      const closedView = new ViewBean('closed', 'Closed', 100);
      closedView.setTimeSpent(77);
      closedView.close();
      closedView.calculateTimeSpent();
      expect(closedView.getTimeSpent() > 0).assertTrue();
    });
  });
}
