const fs = require('fs');
const path = require('path');

const baseDir = path.join(__dirname, '..');
const pkgPath = path.join(baseDir, 'oh-package.json5');
const pkgContent = fs.readFileSync(pkgPath, 'utf8');
const versionMatch = pkgContent.match(/"version"\s*:\s*"([^"]+)"/);
const version = versionMatch ? versionMatch[1] : '0.0.0';

const outDir = path.join(baseDir, 'src', 'main', 'cpp', 'include');
if (!fs.existsSync(outDir)) {
    fs.mkdirSync(outDir, { recursive: true });
}

fs.writeFileSync(path.join(outDir, 'ft_version.h'), `#pragma once
#define FT_VERSION "${version}"
`);
