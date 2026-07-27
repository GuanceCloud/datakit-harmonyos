import { DataModifier, DataModifierValue, LineDataModifier } from '@guancecloud/ft_sdk/Index';

export const FIELD_MASK = '[field-masked]';
export const LINE_MASK = '[line-masked]';
export const LINE_SOURCE_MESSAGE = 'demo-line-sensitive-message';

/**
 * Demo-only callbacks installed by EntryAbility. They deliberately target
 * namespaced test fields so normal demo traffic is unaffected.
 */
export class DemoDataModifier implements DataModifier {
  modify(key: string, _value: DataModifierValue): DataModifierValue | null {
    if (key === 'demo_sensitive_tag' || key === 'demo_sensitive_field') {
      return FIELD_MASK;
    }
    return null;
  }
}

export class DemoLineDataModifier implements LineDataModifier {
  modify(_measurement: string, data: Map<string, DataModifierValue>): Map<string, DataModifierValue> | null {
    const patch = new Map<string, DataModifierValue>();
    if (data.get('message') === LINE_SOURCE_MESSAGE) {
      patch.set('message', LINE_MASK);
    }
    if (data.has('demo_line_sensitive_field')) {
      patch.set('demo_line_sensitive_field', LINE_MASK);
    }
    return patch.size === 0 ? null : patch;
  }
}
