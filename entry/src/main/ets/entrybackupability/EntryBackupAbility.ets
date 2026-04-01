import BackupExtensionAbility, { BundleVersion } from '@ohos.application.BackupExtensionAbility';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'EntryBackupAbility';

export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup() {
    DemoLogger.i(TAG, 'onBackup ok');
  }

  async onRestore(bundleVersion: BundleVersion) {
    DemoLogger.i(TAG, 'onRestore ok', bundleVersion);
  }
}
