// 从 @icon-park/svg 包生成 SVG 文件到项目资源目录
// 用法：node scripts/generate_iconpark_svgs.js

const fs = require('fs');
const path = require('path');

const iconParkSvgPath = process.argv[2] || path.join(__dirname, '..', 'node_modules', '@icon-park', 'svg');
const outputDir = path.join(__dirname, '..', 'qml', 'assets', 'icons', 'iconpark');

// 常用图标列表：名称 -> IconPark 图标名
const icons = {
    'like': 'Like',
    'unlike': 'Unlike',
    'star': 'Star',
    'star-filled': 'StarOne',
    'share': 'Share',
    'comment': 'Comment',
    'message': 'Message',
    'history': 'History',
    'search': 'Search',
    'home': 'Home',
    'video': 'Video',
    'live': 'Videocamera',
    'settings': 'Setting',
    'fullscreen': 'FullScreen',
    'fullscreen-exit': 'OffScreen',
    'volume': 'VolumeUp',
    'volume-small': 'VolumeSmall',
    'volume-notice': 'VolumeNotice',
    'volume-mute': 'VolumeMute',
    'play': 'Play',
    'pause': 'Pause',
    'subtitles': 'Text',
    'close': 'Close',
    'more': 'More',
    'bell': 'BellRing',
    'fire': 'Fire',
    'coin': 'Bitcoin',
    'money': 'PaperMoney',
    'user': 'User',
    'thumb-up': 'ThumbsUp',
    'thumb-down': 'ThumbsDown',
    'send': 'Send',
    'loading': 'Loading',
    'refresh': 'Refresh'
};

if (!fs.existsSync(iconParkSvgPath)) {
    console.error(`未找到 @icon-park/svg 包：${iconParkSvgPath}`);
    console.error('请先安装：npm install @icon-park/svg');
    process.exit(1);
}

if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
}

const iconsDir = path.join(iconParkSvgPath, 'lib', 'icons');
const missing = [];
const generated = [];

for (const [fileName, iconName] of Object.entries(icons)) {
    const iconFile = path.join(iconsDir, `${iconName}.js`);
    if (!fs.existsSync(iconFile)) {
        missing.push(iconName);
        continue;
    }

    try {
        const iconModule = require(iconFile);
        const svg = iconModule.default({
            theme: 'outline',
            size: 48,
            strokeWidth: 3,
            strokeLinecap: 'round',
            strokeLinejoin: 'round'
        });

        const outputFile = path.join(outputDir, `${fileName}.svg`);
        fs.writeFileSync(outputFile, svg, 'utf8');
        generated.push(`${fileName}.svg`);
    } catch (e) {
        console.error(`生成 ${iconName} 失败：`, e.message);
        missing.push(iconName);
    }
}

console.log(`已生成 ${generated.length} 个 SVG 图标到 ${outputDir}`);
if (generated.length > 0) {
    console.log(generated.join('\n'));
}

if (missing.length > 0) {
    console.log('\n以下图标未找到：');
    console.log(missing.join('\n'));
}
