// 网盘推送工具

import quarkApi from './quarkApi.js'
import GuangyaApi from './guangyaApi.js';
import Api115 from './api115.js';
import { getMylog, backErr, safeJsonParse } from './utils.js';
const mylog = getMylog('PanUtils')

let lastInitTag = ''
export async function initPans(ext, Tag = '') {
    mylog(Tag + " init")
    if (lastInitTag) {
        mylog("已经初始化过了:", lastInitTag)
        return
    }
    lastInitTag = Tag
    // 初始化网盘列表 (带网络缺失容错保护)
    try {
        const { quarkck, guangya, _115ck } = ext || {};
        const [quarkCookie, guangyaRes, _115Cookie] = await Promise.all([
            quarkck ? req(quarkck).content : Promise.resolve(''),
            guangya ? req(guangya).content : Promise.resolve(''),
            _115ck ? req(_115ck).content : Promise.resolve('')
        ]);
        
        let guangyaConfig = {};
        try {
            if (guangyaRes && typeof guangyaRes === 'string' && guangyaRes.trim().startsWith('{')) {
                guangyaConfig = JSON.parse(guangyaRes);
            }
        } catch (_) {}

        await Promise.all([
            quarkCookie && quarkApi && quarkApi.setCookie ? quarkApi.setCookie(quarkCookie) : Promise.resolve(),
            GuangyaApi && GuangyaApi.init ? GuangyaApi.init(guangyaConfig) : Promise.resolve(),
            _115Cookie && Api115 && Api115.setCookie ? Api115.setCookie(_115Cookie) : Promise.resolve()
        ]);
    } catch (err) {
        mylog('initPans 容错保护生效:', err);
    }
}

/**
 * 网盘类型枚举
 */
export const panType = {
    _115Links: "115Links",
    quarkLinks: "quarkLinks",
    guangyaLinks: "guangyaLinks"
};

/**
 * 统一处理推送详情（支持双参数：links 链接与 vod 自定义元数据）
 * @async
 * @function pushDetail
 * @param {string|string[]|Object} links 传入的链接、链接数组或网盘对象
 * @param {Object} [vod={}] 自定义的视频元数据对象（包含 vod_name, vod_remarks, vod_pic, vod_content 等）
 * @returns {Promise<string>} 返回符合 TVBox 标准的 JSON 字符串
 */
export async function pushDetail(links, vod = {}) {
    try {
        mylog('🔥 [pushDetail] 收到链接数据：', links, '自定义元数据:', vod);
        let linksObj = {};
        let rawLinks = []; 

        // 兼容单参数传入时，如果是个包含 links 和 vod 的对象
        let targetLinks = links;
        let customVod = vod;
        if (!Array.isArray(links) && typeof links === 'object' && links !== null && (links.links || links.vod)) {
            targetLinks = links.links || links;
            customVod = links.vod || vod;
        }

        if (Array.isArray(targetLinks)) {
            mylog('📂 [pushDetail] 检测到传入的是链接数组，开始智能分类...');
            for (const link of targetLinks) {
                if (typeof link !== 'string') continue;
                rawLinks.push(link);
                if (Api115.is115ShareLink(link)) {
                    (linksObj[panType._115Links] ??= []).push(link);
                } else if (link.includes('quark')) {
                    (linksObj[panType.quarkLinks] ??= []).push(link);
                } else if (link.includes('guangya')) {
                    (linksObj[panType.guangyaLinks] ??= []).push(link);
                }
            }
        } else if (typeof targetLinks === 'object' && targetLinks !== null) {
            linksObj = targetLinks;
            for (const val of Object.values(linksObj)) {
                if (Array.isArray(val)) {
                    rawLinks.push(...val.filter(v => typeof v === 'string'));
                } else if (typeof val === 'string') {
                    rawLinks.push(val);
                }
            }
        } else if (typeof targetLinks === 'string') {
            rawLinks = [targetLinks];
            mylog('🔗 [pushDetail] 检测到传入的是单条字符串/链接');
            if (Api115.is115ShareLink(targetLinks)) return await api115Push(targetLinks);
            if (targetLinks.includes('quark')) return await quarkPush(targetLinks);
            if (targetLinks.includes('guangya')) return await guanyaPush(targetLinks);
            if (targetLinks.includes('magnet:') || targetLinks.includes('ed2k:')) {
                return targetLinks.startsWith("115") ? await api115Cili(targetLinks.replace(/^115\s*/, '')) : await guanyaCili(targetLinks);
            }
            if (targetLinks.includes('http') || targetLinks.includes('file://')) return await normalPush(targetLinks);
            throw new Error("不支持的推送链接");
        } else {
            throw new Error("不支持的参数类型");
        }

        mylog('⚡ [pushDetail] 开始并发解析各网盘链接...');
        let lastError = null; 

        const validEntries = Object.entries(linksObj).filter(([_, val]) => {
            const list = [].concat(val).filter(Boolean);
            return list.length > 0;
        });

        const results = await Promise.all(
            validEntries.map(async ([key, val]) => {
                const linkList = [].concat(val).filter(Boolean);
                try {
                    let res = null;
                    if (key.includes('115')) {
                        res = await Api115.detail_getVodPlayInfo_fromShareLinks(linkList, false);
                    } else if (key.includes('quark')) {
                        res = await quarkApi.detail_getVodPlayInfo_fromShareLinks(linkList);
                    } else if (key.includes('guangya')) {
                        res = await GuangyaApi.detail_getVodPlayInfo_fromShareLinks(linkList, false);
                    }

                    if (typeof res === 'string') {
                        try { res = JSON.parse(res); } catch (e) { }
                    }
                    return res?.list || (Array.isArray(res) ? res : [res]);
                } catch (e) {
                    mylog(`❌ [pushDetail] 网盘 [${key}] 解析异常:`, e);
                    lastError = e; 
                    return [];
                }
            })
        );

        const allVodList = results.flat().filter(v => v && (v.vod_play_url || v.vod_play_from));
        mylog(`📦 [pushDetail] 解析完成，有效视频源总数: ${allVodList.length}`);

        if (!allVodList.length) {
            throw lastError || new Error("未获取到有效视频");
        }
        mylog('🔀 [pushDetail] 正在合并多网盘/多线路数据并拍平 vod_content...');
        let primary = allVodList[0];
        primary.vod_play_from = allVodList.map(v => v.vod_play_from).filter(Boolean).join('$$$'); primary.vod_play_url = allVodList.map(v => v.vod_play_url).filter(Boolean).join('$$$');

        // 收集解析出的 vod_content 以及最初传入的 rawLinks 进行回填
        const contents = allVodList.map(v => v.vod_content)

      
        primary.vod_content = contents.join('\n');

        // 🔥 核心：高性能自定义元数据合并与保护拼接
        let finalVod = primary;
        if (customVod && typeof customVod === 'object') {
            finalVod = {
                ...primary,
                ...customVod,
                vod_play_from: primary.vod_play_from,
                vod_play_url: primary.vod_play_url,
            };
            if (customVod.vod_content) {
                finalVod.vod_content = customVod.vod_content + '\n' + primary.vod_content;
            }
        }

        return JSON.stringify({ list: [finalVod] });
    } catch (err) {
        mylog('❌ [pushDetail] 错误:', err);
        return backErr(err);
    }
}

/**
 * 统一播放分发
 */
export async function pushPlay(flag, id, vipFlags) {
    mylog(`🔥 [pushPlay] 收到播放请求 -> flag: ${flag}, id: ${id}`);
    try {
        if (id.startsWith("http")) {
            mylog('🌐 [pushPlay] 识别为直链播放');
            return JSON.stringify({ parse: 0, url: id });
        }

        const info = JSON.parse(id);
        if (flag.startsWith("光鸭")) {
            mylog('🦆 [pushPlay] 走光鸭播放逻辑');
            if (flag.includes("光鸭离线")) {
                mylog('⏳ [pushPlay] 触发光鸭后台异步字幕获取...');
                getPushSubsBykw(info?.fileName).catch(err => mylog('后台获取字幕失败:', err));
            }
            return await GuangyaApi.playGuangyaFromVideoFileInfo(info);
        }
        if (flag.startsWith("夸克")) {
            mylog('🪐 [pushPlay] 走夸克播放逻辑');
            return await quarkApi.playQuarkVideoFromDetailVideoInfo(info);
        }
        if (flag.startsWith("115磁")) {
            mylog('🧲 [pushPlay] 走115磁力播放逻辑');
            return await Api115.playVideoFromMyNewFile(info);
        }
        if (flag.startsWith("115")) {
            mylog('☁️ [pushPlay] 走115网盘播放逻辑');
            return await Api115.playVideoFromDetailVideoInfo(info);
        }

        throw new Error("不支持的播放标识");
    } catch (err) {
        mylog('❌ [pushPlay] 错误:', err);
        return backErr(err);
    }
}

// 字幕服务本地代理地址（直接写死）
const SUBTITLE_SERVER_URL = 'https://subs.0256520.xyz/api/subs?kw=';

/**
 * 从文本或对象中提取并规范化标准番号 (如 "ABP-919")
 * @param {string | Object} kw 包含番号的字符串或对象
 * @returns {string} 提取出的标准大写番号；若提取失败则返回空字符串 ''
 */
export function getFanhaoFrom(kw) {
    if (!kw) return '';
    let text = typeof kw === 'object' ? (kw.vod_name || kw.name || '') : String(kw);
    text = text.trim();
    if (!text) return '';

    const standardPattern = /^[a-zA-Z]{2,6}-\d{2,5}$/;
    if (standardPattern.test(text)) {
        return text.toUpperCase();
    }
    const match = text.match(/([a-zA-Z]{2,6})-?(\d{2,5})/i);
    let keyword = '';
    if (match) {
        keyword = `${match[1].toUpperCase()}-${match[2]}`;
    }
    return keyword;
}

/**
 * 根据传入的关键字（或视频对象）提取标准番号，并从远端字幕服务获取/预加载字幕
 * @param {string | Object} kw 包含番号信息的字符串或对象
 * @param {boolean} refresh 需要立即推送更新字幕
 * @returns {Promise<{subs: Array<Object>, fanhao: string} | Array>} 返回字幕列表与解析后的标准番号对象
 */
export async function getPushSubsBykw(kw, refresh = true) {
    try {
        const keyword = getFanhaoFrom(kw);
        if (!keyword) return [];
        mylog(`原始文本: "${kw}" -> 提取出的番号: "${keyword}"`);

        const res = await http(`${SUBTITLE_SERVER_URL}${keyword}`, {
            timeout: 20000
        });

        const data = safeJsonParse(res?.content);
        mylog('获取到的字幕列表:', data?.subs);

        const subs = data?.subs || [];
        if (subs.length > 0 && refresh) {
            const bestSub = selectBestSubtitle(subs);
            if (bestSub) {
                await refreshSubtitle(bestSub).catch(err => mylog('预加载首选字幕失败:', err));
            }
        }

        return {
            subs,
            fanhao: keyword
        };
    } catch (err) {
        mylog('获取字幕异常:', err);
        return [];
    }
}

/**
 * 智能加权筛选最佳字幕
 */
function selectBestSubtitle(subs) {
    if (!Array.isArray(subs) || subs.length === 0) return null;

    const getScore = (sub) => {
        const name = (sub.name || '').toLowerCase();
        const url = (sub.url || '').toLowerCase();

        if (url.includes('zh-cn') || name.includes('简体')) return 3;
        if (url.includes('jp-zh-cn') || name.includes('jp-zh')) return 2;
        if (url.includes('eng-zh') || name.includes('英')) return 1;
        return 0;
    };

    let sortedSubs = [...subs].sort((a, b) => getScore(b) - getScore(a));
    return sortedSubs[0];
}

/**
 * 刷新字幕的异步函数（适配 FongMi QuickJS 环境）
 */
async function refreshSubtitle(sub) {
    mylog('准备刷新字幕:', sub);

    let port = await getPort() || 9978;
    let subUrl = '';
    if (typeof sub === 'string') {
        subUrl = sub;
    } else if (sub) {
        subUrl = sub.url || sub.path || '';
    }

    if (!subUrl) {
        throw new Error('没有有效的字幕链接');
    }

    let targetApi = `http://127.0.0.1:${port}/action`;
    let refreshUrl = targetApi +
        '?do=refresh' +
        '&type=subtitle' +
        '&path=' + encodeURIComponent(subUrl);

    mylog(`正在请求刷新地址: ${refreshUrl}`);

    try {
        let response = await http(refreshUrl);
        let result = await safeJsonParse(response);
        mylog('字幕刷新成功，返回结果:', result);
        return result;
    } catch (error) {
        mylog('字幕刷新失败:', error);
        throw error;
    }
}

async function normalPush(id) {
    let vod = {
        vod_id: id,
        vod_name: "推送视频",
        vod_play_from: "一般推送",
        vod_play_url: id,
        vod_pic: "https://img.icons8.com/color/480/video-playlist.png",
        vod_content: id
    };
    return JSON.stringify({ list: [vod] });
}

async function guanyaCili(clink) {
    return await GuangyaApi.getVodDetailFromClink(clink)
}

async function guangyaPush(gyshareLink) {
    return await GuangyaApi.getVodDetailFromShareLinks([gyshareLink]);
}

async function quarkPush(id) {
    try {
        const shareUrl = id;
        let { vod_name, vod_play_from, vod_play_url } = await quarkApi.detail_getVodPlayInfo_fromShareLinks([shareUrl])
        let vod = {
            vod_id: id,
            vod_name: vod_name || "推送内容",
            vod_play_from: vod_play_from || "夸克云盘",
            vod_play_url: vod_play_url,
            vod_pic: "https://img.icons8.com/color/480/video-playlist.png",
            vod_content: shareUrl
        };
        return JSON.stringify({ list: [vod] });
    } catch (err) {
        return backErr(err)
    }
}

async function api115Push(shareUrl) {
    try {
        return await Api115.detail_getVodPlayInfo_fromShareLinks([shareUrl], true)
    }
    catch (err) {
        return backErr(err)
    }
}

async function api115Cili(clink) {
    try {
        return await Api115.detail_getVodPlayInfo_fromClink(clink)
    }
    catch (err) {
        return backErr(err)
    }
}