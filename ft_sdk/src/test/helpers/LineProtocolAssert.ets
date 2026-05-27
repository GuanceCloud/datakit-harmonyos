import { expect } from '@ohos/hypium';
import { Constants } from '../../main/ets/components/Constants';

export class LineProtocolAssert {
  public static withoutSdkDataId(lineProtocol: string): string {
    const withoutLeadingFlag = lineProtocol.replace(new RegExp(Constants.KEY_SDK_DATA_FLAG + '=[^,]+,'), '');
    return withoutLeadingFlag.replace(new RegExp(',\\s?' + Constants.KEY_SDK_DATA_FLAG + '=[\\w\\d]+'), '');
  }

  public static assertContains(lineProtocol: string, expected: string): void {
    expect(lineProtocol.includes(expected)).assertTrue();
  }
}
