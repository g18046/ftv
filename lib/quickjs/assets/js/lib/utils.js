import { LocalCache } from "./localCache.js";

const mylog = getMylog("util")

// 是否是音视频后缀文件
export const VIDEO_REGEX = /(mp4|mkv|flv|avi|mov|m3u8|iso|ts|webm|flac|mp3|m4a|wav|aac|ts)/i;

/**
 * 
 * @param {string } ico 文件名或者文件后缀
 * @returns {boolean} 是不是音视频文件
 */
export function isVideoOrMusic(ico) {
    // 兼容传过来的是filename xxx.mp4
    let index = (ico + '').lastIndexOf('.');
    if (index >= 0) {
        ico = ico.slice(index);
    }
    return VIDEO_REGEX.test(ico);
}

/**
 * 格式化字节大小为可读字符串
 * @param {number} bytes 
 * @returns {string}
 */
export function formatSize(bytes) {
    if (!bytes || bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(1024));
    return (bytes / Math.pow(1024, i)).toFixed(i >= 3 ? 2 : 1) + units[i];
}

/**
 * 影视文件名格式化：[文件大小] S01E02 剧名 [年份]
 * @param {string} fileName 原始文件名
 * @param {number} size 字节大小
 * @returns {string} 格式化后的名称
 */
export function formatVideoName(fileName, size) {
    if (!fileName) return "未知文件";

    // 0. 去除常见扩展名
    let rawName = fileName.replace(/\.(mkv|mp4|avi|flv|rmvb|ts|torrent|iso)$/i, '').trim();
    if (!rawName) return "未知文件";

    // 1. 获取格式化后的大小
    let sizeStr = formatSize(size);

    // 2. 提取季数和集数 (支持 S01E02, S1E2, S01E01-E02, EP02, 第02集, [02])
    let seasonEp = "";
    let seIndex = -1;

    // 匹配 S01E02 格式
    const seMatch = rawName.match(/S(\d+)\s*E(\d+)(?:[-~_.\s]*E?(\d+))?/i);
    if (seMatch) {
        const s = seMatch[1].padStart(2, '0');
        const e1 = seMatch[2].padStart(2, '0');
        seasonEp = seMatch[3]
            ? `S${s}E${e1}-E${seMatch[3].padStart(2, '0')}`
            : `S${s}E${e1}`;
        seIndex = seMatch.index;
    } else {
        // 匹配 EP02、第02集、[02] 格式
        const epMatch = rawName.match(/(?:EP?|第)[-.\s]*(\d+)\s*集?/i) || rawName.match(/\[(\d{1,3})\]/);
        if (epMatch) {
            seasonEp = `E${epMatch[1].padStart(2, '0')}`;
            seIndex = epMatch.index;
        }
    }

    // 3. 提取年份 (1900-2099)
    let yearMatch = rawName.match(/\b(19\d{2}|20\d{2})\b/);
    let yearStr = yearMatch ? yearMatch[1] : "";

    // 4. 精确提取纯净剧名
    let cleanName = "";

    if (seIndex !== -1) {
        // 如果存在季集标识，剧名必定在季集之前
        cleanName = rawName.substring(0, seIndex);
    } else {
        // 没有季集标识时，去除年份标签
        cleanName = rawName;
        if (yearStr) cleanName = cleanName.replace(/\b(19\d{2}|20\d{2})\b.*/, '');
    }

    // 清理剧名中的杂质（压制组、格式标签、方括号/圆括号内容）
    cleanName = cleanName
        .replace(/\b(WEB-?DL|WEBRip|HDTV|BluRay|REMUX|AAC|DDP?\d?|x264|x265|H\.?264|H\.?265|HEVC|AV1|HDR10\+?|DV|Dolby|CHS|CHT|ENG)\b/gi, '')
        .replace(/\[.*?\]|\(.*?\)/g, ' ')
        .replace(/[._]/g, ' ')
        .replace(/[-_.\s]+/g, ' ')
        .trim();

    // 兜底：若没有季集，且清洗后为空，以原始名称作为剧名
    if (!cleanName && !seasonEp) {
        cleanName = rawName;
    }

    // 5. 去重逻辑：如果剧名本身就是年份，不重复展示括号年份
    if (cleanName === yearStr) {
        yearStr = "";
    }

    // 6. 拼接输出：[文件大小] S01E01 剧名 [年份]
    let parts = [
        seasonEp,
        cleanName,
        yearStr ? `[${yearStr}]` : ""
    ].filter(Boolean);

    let middlePart = parts.join(" ");
    return sizeStr ? `[${sizeStr}] ${middlePart}` : middlePart;
}

export function checkAllNotEmpty(...args) {
    // 1. 获取调用者的函数名
    const stack = new Error().stack || '';
    const match = stack.split('\n')[2]?.match(/at\s+([^\s]+)/);
    const callerName = match ? match[1] : 'anonymous';

    // 如果没传任何参数，直接报错
    if (args.length === 0) {
        console.log(`❌ [${callerName}] 判空失败: 未传入任何参数`);
        throw new Error(`[${callerName}] 未传入任何参数`);
    }

    // 2. 遍历检查每一个参数
    args.forEach((item, index) => {
        const isEmpty = !item ||
            (Array.isArray(item) && item.length === 0) ||
            (typeof item === 'object' && Object.keys(item).length === 0);

        if (isEmpty) {
            console.log(`❌ [${callerName}] 第 ${index + 1} 个参数为空:`, item);
            throw new Error(`[${callerName}] 第 ${index + 1} 个参数不能为空`);
        }
    });
}


export function getCallerFunctionName() {
    try {
        const stackLines = new Error().stack?.split('\n') || [];
        // stackLines[0] 是 Error 本身，stackLines[1] 是当前辅助函数，stackLines[2] 才是真正的调用者
        if (stackLines.length > 2) {
            const match = stackLines[2].match(/at\s+([^\s]+)\s+/);
            if (match && match[1]) {
                return match[1];
            }
        }
    } catch (e) {
        // 捕获异常防错
    }
    return 'anonymous';
}
export function backErr(err) {
    let functionName = getCallerFunctionName()
    console.log(`backErr in ${functionName} err:`, err)

    return JSON.stringify({ msg: err?.message })
}

export const PROXY_WORKER = "https://req.0256520.xyz/?url=";


/**
 * 并行检测最快站点 (稳健版)
 */
export async function getFastestBaseUrl(sites, siteKey) {

    let baseUrl = await LocalCache.get(siteKey)

    if (baseUrl) {
        console.log(`缓存读取到${siteKey}的最快站点`, baseUrl)
        return baseUrl
    }


    if (!sites || sites.length === 0) return null;

    const promises = [];

    for (let i = 0; i < sites.length; i++) {
        let domain = sites[i];
        // 确保 URL 格式正确
        let url = domain.startsWith('http') ? domain : 'https://' + domain;

        // 创建 Promise
        const promise = checkSite(url, i);
        promises.push(promise);
    }

    try {
        // 等待所有请求完成
        const results = await Promise.all(promises);

        // 过滤掉失败的检测结果 (null)
        // 注意：只有 statusCode >= 200 && < 300 才会 resolve 对象，否则 resolve(null)
        const validResults = results.filter(r => r !== null);

        if (validResults.length === 0) {
            console.log("⚠️ 所有站点均不可用");
            return null;
        }

        // 按耗时排序，找出最快的
        validResults.sort((a, b) => a.time - b.time);

        const fastest = validResults[0];
        console.log(`✅ 检测到最快站点: ${fastest.site} (${fastest.time}ms)`);

        LocalCache.set(siteKey, fastest.site)
        console.log(`缓存设置成功${siteKey}的最快站点`, fastest.site)
        return fastest.site;

    } catch (e) {
        console.log("❌ 检测过程出错:", e.message);
        return null;
    }
}

/**
 * 检查单个站点
 */
function checkSite(url, index) {
    return new Promise((resolve) => {
        let startTime = new Date().getTime();

        try {
            // 发送 HEAD 请求
            let res = req(url, {
                method: "HEAD",
                timeout: 5000,
                headers: {
                    "User-Agent": PC_UA,
                    "Accept": "*/*"
                }
            });

            let endTime = new Date().getTime();
            let costTime = endTime - startTime;

            // 解析状态码
            let statusCode = 0;
            if (res) {
                // 兼容不同版本的 req 返回值
                statusCode = res.code || res.status || 0;
            }

            console.log(`[${index}] ${url}: ${costTime}ms, Status: ${statusCode}`);

            // 判断是否成功 (2xx 状态码)
            // 注意：有些源可能返回 302 重定向，也可以视为成功，这里严格限制为 2xx
            if (statusCode >= 200 && statusCode < 300) {
                resolve({
                    site: url,
                    time: costTime,
                    status: statusCode
                });
            } else {
                resolve(null);
            }

        } catch (e) {
            // 发生异常（如网络断开），返回 null
            console.log(`[${index}] ${url} 发生异常: ${e.message}`);
            resolve(null);
        }
    });
}

export const PC_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36";


export function safeJsonParse(str) {
    try {
        return typeof str === "string" && (str.startsWith('{') || str.startsWith('[')) ? JSON.parse(str) : str;
    } catch (e) {
        return str;
    }
}




export function getMylog(Tag) {
    return function mylog(...args) {
      
        let functionName = getCallerFunctionName()
     
        console.log(`【${Tag}】[${functionName}方法打印日志]`, ...args);
    }
}



function isErrorReq(data) {
    let isErr = data.error || data.message

    let msg = data.error || data.message

    return [isErr, msg]
}
export const getMyRequest = (customOptions) => {

    let reqfn = async (url, options) => {
        let finalOptions = {
            method: options?.method || "GET",
            ...options,
            headers: {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36",
                ...options?.headers,
                ...customOptions?.headers
            },
        }
        mylog(`🚀 [request] 请求体:`, finalOptions);
        let res = await http(url, finalOptions);
        let data = safeJsonParse(res?.content)

        mylog(`🚀 [request] res:`, data?.slice(0,20));

        const [isErr, msg] = isErrorReq(data)
        if (isErr) {
            mylog(data)
            mylog(msg)
            throw new Error(msg)
        }
        return data;
    }

    return reqfn

};









