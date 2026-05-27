import { describe, it, expect } from '@ohos/hypium';
import { BaseContentBean, baseContentBeanToString } from '../../main/ets/components/bean/BaseContentBean';
import { LineProtocolBean, TimeUtils } from '../../main/ets/components/bean/LineProtocolBean';
import { LogBean } from '../../main/ets/components/bean/LogBean';
import { Status } from '../../main/ets/components/bean/Status';
import { Constants } from '../../main/ets/components/Constants';
import { ResourceParams } from '../../main/ets/components/rum/bean/ResourceParams';
import { UserData } from '../../main/ets/components/rum/bean/UserData';

interface ValueWrapper {
  value: string;
}

class ResourceLoadValue {
  public value: number;

  constructor(value: number) {
    this.value = value;
  }
}

function createRepeatedText(char: string, length: number): string {
  let result = '';
  for (let i = 0; i < length; i++) {
    result += char;
  }
  return result;
}

export default function beanModelUnitTest() {
  describe('BeanModelUnit', () => {
    it('lineProtocolBeanShouldExposeCountsJsonAndEscapedLine', 0, () => {
      const tags: Record<string, object> = {};
      tags['tag key'] = 'tag,value' as Object;
      const fields: Record<string, object> = {};
      fields['message'] = 'hello world' as Object;
      fields['count'] = 3 as Object;

      const bean = new LineProtocolBean('measurement', tags, fields, 123);
      const line = bean.toLineProtocol();
      const json = bean.toJSON();
      const cloned = LineProtocolBean.fromJSON(json);

      expect(bean.getTagCount()).assertEqual(1);
      expect(bean.getFieldCount()).assertEqual(2);
      expect(line.includes('tag key=tag\\,value')).assertTrue();
      expect(line.includes('message="hello\\ world"')).assertTrue();
      expect(line.includes('count=3')).assertTrue();
      expect(cloned.getMeasurement()).assertEqual('measurement');
      expect(cloned.getTimeNano()).assertEqual(123);
    });

    it('baseContentBeanShouldMergeServiceTagAndMessageField', 0, () => {
      const bean = BaseContentBean.createWithDefaultMeasurement('hello', 1000);
      bean.setServiceName('test-service');
      bean.addTag('env', 'prod' as Object);
      bean.addField('custom', 'value' as Object);

      const tags = bean.getAllTags();
      const fields = bean.getAllFields();
      const service = tags[Constants.KEY_SERVICE] as ValueWrapper;
      const message = fields[Constants.KEY_MESSAGE] as ValueWrapper;

      expect(bean.getMeasurement()).assertEqual(Constants.FT_LOG_DEFAULT_MEASUREMENT);
      expect(bean.getTimeNano()).assertEqual(TimeUtils.millisToNanos(1000));
      expect(service.value).assertEqual('test-service');
      expect(String(tags['env'])).assertEqual('prod');
      expect(message.value).assertEqual('hello');
      expect(String(fields['custom'])).assertEqual('value');
      expect(bean.toJSON().time).assertEqual(1000);
    });

    it('logBeanShouldAddStatusTagAndExtendedFields', 0, () => {
      const log = new LogBean('log message', 1000);
      log.setStatus(Status.WARN.name);
      log.addProperty('error_code', 500 as Object);

      const tags = log.getAllTags();
      const fields = log.getAllFields();
      const status = tags[Constants.KEY_STATUS] as ValueWrapper;
      const message = fields[Constants.KEY_MESSAGE] as ValueWrapper;

      expect(status.value).assertEqual(Status.WARN.name);
      expect(message.value).assertEqual('log message');
      expect(Number(fields['error_code'])).assertEqual(500);
      expect(log.isValid()).assertTrue();
      expect(log.getDescription().startsWith('[warn]')).assertTrue();
    });

    it('baseContentBeanShouldCoverMutationHelpersAndLimitBranches', 0, () => {
      const longContent = createRepeatedText('x', 30725);
      const longBase = BaseContentBean.createWithDefaultMeasurement(longContent, 1000);
      const longLog = new LogBean(longContent, 1000);
      const emptyBase = BaseContentBean.createWithDefaultMeasurement('', 0);
      const bean = BaseContentBean.createWithDefaultMeasurement('seed', 1000);

      bean.setContent('updated');
      bean.setTime(2000);
      bean.setServiceName('svc');
      bean.addTag('', 'ignored' as Object);
      bean.addTag('tag_one', 'one' as Object);
      const moreTags: Record<string, object> = {};
      moreTags['tag_two'] = 'two' as Object;
      bean.appendTags(moreTags);
      bean.appendTags(JSON.parse('null') as Record<string, object>);
      bean.removeTag('tag_two');
      bean.addField('', 'ignored' as Object);
      bean.addField('field_one', 'one' as Object);
      const moreFields: Record<string, object> = {};
      moreFields['field_two'] = 'two' as Object;
      bean.appendFields(moreFields);
      bean.appendFields(JSON.parse('null') as Record<string, object>);
      bean.removeField('field_two');

      expect(longBase.getContent().length).assertEqual(30720);
      expect(longLog.getContent().length).assertEqual(30720);
      expect(emptyBase.getContent()).assertEqual('');
      expect(bean.getContent()).assertEqual('updated');
      expect(bean.getTime()).assertEqual(1000);
      expect(bean.getServiceName()).assertEqual('svc');
      expect(String(bean.getTag('tag_one'))).assertEqual('one');
      expect(JSON.stringify(bean.getTag('tag_two'))).assertEqual('{}');
      expect(bean.getTag('missing') === undefined).assertTrue();
      expect(bean.hasTag('tag_one')).assertTrue();
      expect(bean.hasTag('missing')).assertFalse();
      expect(bean.getTagCount()).assertEqual(2);
      expect(String(bean.getField('field_one'))).assertEqual('one');
      expect(JSON.stringify(bean.getField('field_two'))).assertEqual('{}');
      expect(bean.getField('missing') === undefined).assertTrue();
      expect(bean.hasField('field_one')).assertTrue();
      expect(bean.hasField('missing')).assertFalse();
      expect(bean.getFieldCount()).assertEqual(2);

      bean.clearTags();
      bean.clearFields();

      expect(JSON.stringify(bean.getTag('tag_one'))).assertEqual('{}');
      expect(JSON.stringify(bean.getField('field_one'))).assertEqual('{}');
      expect(baseContentBeanToString(bean).includes('"content":"updated"')).assertTrue();
    });

    it('logBeanShouldCoverPropertyCloneAndLongDescriptionBranches', 0, () => {
      const longMessage = createRepeatedText('m', 105);
      const log = new LogBean(longMessage, 1000);
      const property: Record<string, object> = {};
      property['code'] = 500 as Object;
      property['remove_me'] = 'gone' as Object;

      log.setStatus(Status.ERROR.name);
      log.setProperty(property);
      log.removeProperty('remove_me');
      log.addTag('custom_tag', 'tag-value' as Object);
      log.addField('custom_field', 'field-value' as Object);

      const cloned = log.clone();
      log.setProperty(JSON.parse('null') as Record<string, object>);

      expect(Object.keys(log.getProperty()).length).assertEqual(0);
      expect(cloned.getStatus()).assertEqual(Status.ERROR.name);
      expect(Number(cloned.getProperty()['code'])).assertEqual(500);
      expect(JSON.stringify(cloned.getProperty()['remove_me'])).assertEqual('{}');
      expect(String(cloned.getAllTags()['custom_tag'])).assertEqual('tag-value');
      expect(String(cloned.getAllFields()['custom_field'])).assertEqual('field-value');
      expect(cloned.getDescription()).assertEqual(`[error] ${createRepeatedText('m', 100)}...`);
    });

    it('statusShouldCoverLookupAliasesEqualityAndString', 0, () => {
      const statuses = Status.getAllStatuses();

      expect(statuses.length).assertEqual(6);
      expect(Status.fromName('trace')).assertEqual(Status.TRACE);
      expect(Status.fromName('debug')).assertEqual(Status.DEBUG);
      expect(Status.fromName('INFO')).assertEqual(Status.INFO);
      expect(Status.fromName('warn')).assertEqual(Status.WARN);
      expect(Status.fromName('warning')).assertEqual(Status.WARN);
      expect(Status.fromName('error')).assertEqual(Status.ERROR);
      expect(Status.fromName('fatal')).assertEqual(Status.FATAL);
      expect(Status.fromName('critical')).assertEqual(Status.FATAL);
      expect(Status.fromName('missing')).assertNull();
      expect(Status.fromName(JSON.parse('null') as string)).assertNull();
      expect(Status.ERROR.equals(Status.ERROR)).assertTrue();
      expect(Status.ERROR.equals(Status.WARN)).assertFalse();
      expect(Status.FATAL.toString()).assertEqual('fatal');
    });

    it('lineProtocolBeanShouldCoverEmptySkipBooleanObjectCloneAndTimeHelpers', 0, () => {
      const empty = new LineProtocolBean('empty', {}, {}, TimeUtils.millisToNanos(2));
      const skippedTags: Record<string, object> = {};
      skippedTags['skip_null'] = JSON.parse('null') as Object;
      const skippedFields: Record<string, object> = {};
      skippedFields['skip_null'] = JSON.parse('null') as Object;
      const skipBean = new LineProtocolBean('skip', skippedTags, skippedFields, 3);
      const fields: Record<string, object> = {};
      fields['truthy'] = true as Object;
      fields['falsy'] = false as Object;
      fields['object_value'] = new ResourceLoadValue(8) as Object;
      const rich = new LineProtocolBean('rich', {}, fields, 4);
      const cloned = rich.clone();
      const taggedTags: Record<string, object> = {};
      taggedTags['region'] = 'cn' as Object;
      const tagged = new LineProtocolBean('tagged', taggedTags, {}, 5);
      const taggedClone = tagged.clone();
      const invalid = new LineProtocolBean('', {}, {}, 0);

      const skipLine = skipBean.toLineProtocol();
      const richLine = rich.toLineProtocol();
      const nowNanos = TimeUtils.currentTimeNanos();
      const nowMillis = TimeUtils.currentTimeMillis();

      expect(empty.hasTags()).assertFalse();
      expect(empty.hasFields()).assertFalse();
      expect(empty.getTimeMillis()).assertEqual(2);
      expect(empty.toLineProtocol()).assertEqual(`empty ${TimeUtils.millisToNanos(2)}`);
      expect(skipLine.includes('skip_null')).assertFalse();
      expect(richLine.includes('truthy=')).assertTrue();
      expect(richLine.includes('falsy=')).assertTrue();
      expect(richLine.includes('object_value=')).assertTrue();
      expect(cloned.getMeasurement()).assertEqual('rich');
      expect(cloned.getFieldCount()).assertEqual(3);
      expect(String(taggedClone.getTags()['region'])).assertEqual('cn');
      expect(rich.isValid()).assertTrue();
      expect(invalid.isValid()).assertFalse();
      expect(rich.getDescription()).assertEqual('[rich] tags:0, fields:3, time:4');
      expect(nowNanos > 0).assertTrue();
      expect(nowMillis > 0).assertTrue();
    });

    it('userDataShouldCloneCompareAndRoundTripExtsJson', 0, () => {
      const exts: Record<string, string> = {};
      exts['role'] = 'admin';
      const user = new UserData('id-1', 'name-1', 'user@example.com', exts);
      user.addExt('region', 'cn');
      const json = user.getExtsJsonString();

      const parsed = new UserData();
      parsed.setExtsWithJsonString(json);
      const cloned = user.clone();

      expect(user.isValid()).assertTrue();
      expect(user.isSignedIn()).assertTrue();
      expect(parsed.getExt('role')).assertEqual('admin');
      expect(parsed.getExt('region')).assertEqual('cn');
      expect(user.equals(cloned)).assertTrue();

      cloned.removeExt('region');
      expect(user.equals(cloned)).assertFalse();
    });

    it('resourceParamsShouldConvertMapsAndPropertiesToJson', 0, () => {
      const params = new ResourceParams();
      const requestHeaders = new Map<string, string[]>();
      requestHeaders.set('Accept', ['application/json']);
      const responseHeaders = new Map<string, string[]>();
      responseHeaders.set('Content-Type', ['application/json']);

      params.setUrl('https://example.com');
      params.setResourceMethod('POST');
      params.setRequestHeaderMap(requestHeaders);
      params.setResponseHeaderMap(responseHeaders);
      params.setResponseContentType('application/json');
      params.setResponseContentLength(12);
      params.setResourceStatus(200);
      params.addProperty('resourceLoad', new ResourceLoadValue(100));

      const json = params.toJSON();

      expect(json.url).assertEqual('https://example.com');
      expect(json.resourceMethod).assertEqual('POST');
      expect(json.requestHeaderMap['Accept'][0]).assertEqual('application/json');
      expect(json.responseHeaderMap['Content-Type'][0]).assertEqual('application/json');
      expect(json.responseContentType).assertEqual('application/json');
      expect(json.responseContentLength).assertEqual(12);
      expect(json.resourceStatus).assertEqual(200);
      expect(JSON.stringify(json.property['resourceLoad'])).assertEqual('{"value":100}');
    });
  });
}
