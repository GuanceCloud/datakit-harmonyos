const fs = require('fs');
const path = require('path');

const extDir = path.join(__dirname, '..');
const sdkDir = path.join(extDir, '..', 'ft_sdk');

function readVersionFromPackage(pkgPath) {
  const pkgContent = fs.readFileSync(pkgPath, 'utf8');
  const versionMatch = pkgContent.match(/"version"\s*:\s*"([^"]+)"/);
  if (!versionMatch) {
    throw new Error(`Cannot find version in ${pkgPath}`);
  }
  return versionMatch[1];
}

function replaceInFile(filePath, replacer) {
  const original = fs.readFileSync(filePath, 'utf8');
  const updated = replacer(original);
  if (updated !== original) {
    fs.writeFileSync(filePath, updated, 'utf8');
    console.info(`[ft_sdk_ext] synced version in ${path.relative(extDir, filePath)}`);
  }
}

const sourceVersion = readVersionFromPackage(path.join(sdkDir, 'oh-package.json5'));

replaceInFile(path.join(extDir, 'oh-package.json5'), (content) => {
  return content
    .replace(/("version"\s*:\s*")([^"]+)(")/, `$1${sourceVersion}$3`)
    .replace(/("@guancecloud\/ft_sdk"\s*:\s*")([^"]+)(")/, `$1${sourceVersion}$3`);
});

replaceInFile(path.join(extDir, 'BuildProfile.ets'), (content) => {
  return content.replace(/(export const HAR_VERSION = ')([^']+)(';)/, `$1${sourceVersion}$3`);
});

replaceInFile(path.join(extDir, 'oh-package-lock.json5'), (content) => {
  return content;
});
