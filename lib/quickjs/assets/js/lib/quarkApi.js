import { LocalCache } from "./localCache.js";
import { backErr, formatVideoName, isVideoOrMusic } from "./utils.js";

const CacheFolder = "ftv-cache";
const TAG = "[夸克API]";
const mylog = (...args) => console.log(TAG, ...args);

// 统一使用的 User-Agent
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

function toQuery(obj) {
    let arr = [];
    for (let k in obj) {
        if (obj[k] !== undefined && obj[k] !== null) {
            arr.push(k + '=' + encodeURIComponent(obj[k]));
        }
    }
    return arr.join('&');
}

/**
 * 安全请求工具函数，防止解析 JSON 抛错或网络空响应导致崩溃
 */
async function safeReq(url, options = {}) {
    try {
        const response = await req(url, options);
        if (!response) return null;

        let content = response.content || response;
        if (typeof content === 'string' && content.trim()) {
            try {
                content = JSON.parse(content);
            } catch (e) {
                // 非 JSON 格式，保留原始字符串
            }
        }
        return {
            status: response.status || 200,
            headers: response.headers || {},
            data: content
        };
    } catch (e) {
        mylog(`🚨 网络请求失败 [${url}]:`, e.message);
        return null;
    }
}

/**
 * 根据优先级智能获取最佳分辨率的播放链接（4k -> 2k -> super -> high -> normal -> low）
 */
function getBestPlayUrl(videoList) {
    if (!Array.isArray(videoList) || videoList.length === 0) return null;

    // 清晰度优先级
    const priority = ['4k', '2k', 'super', 'high', 'normal', 'low'];

    for (const res of priority) {
        const target = videoList.find(v => v.resolution === res && v.video_info?.url);
        if (target) {
            return {
                resolution: target.resolution,
                url: target.video_info.url
            };
        }
    }

    // 降级兜底：找任意一个包含 url 的项
    const fallback = videoList.find(v => v.video_info?.url);
    return fallback ? { resolution: fallback.resolution, url: fallback.video_info.url } : null;
}

/**
 * 提取并只保留 Cookie 中的关键字段键值对，舍去多余字段与属性
 */
function pruneCookie(cookieStr) {
    if (!cookieStr) return "";

    // 建议保留的核心身份凭证字段列表（可根据业务需求自行增删）
    const keepKeys = ["__puus", "_UP_A4A_VT_", "ctoken", "tfstk"];

    // 解析字符串中的 Cookie 键值对
    const cookieMap = new Map();
    const items = cookieStr.split(";");

    for (const item of items) {
        const [rawKey, ...valParts] = item.trim().split("=");
        if (!rawKey) continue;

        const key = rawKey.trim();
        const value = valParts.join("=").trim();

        // 过滤掉 Cookie 属性（如 Path, Domain, Expires, Max-Age, SameSite 等）
        const isAttribute = /^(path|domain|expires|max-age|samesite|secure|httponly)$/i.test(key);

        // 如果在白名单内，或者非标准 Cookie 属性且有实际值，则提取
        if (keepKeys.includes(key) || (!isAttribute && value)) {
            cookieMap.set(key, value);
        }
    }

    // 重新拼装为极简的 Cookie 字符串
    return Array.from(cookieMap.entries())
        .map(([k, v]) => `${k}=${v}`)
        .join("; ");
}

/**
 * 刷新夸克 __puus 会话凭证（已精简保留字段）
 */
async function refreshQuarkPuusDirectly(currentCookie) {
    if (!currentCookie) return "";

    try {
        const refreshUrl = `https://drive-pc.quark.cn/1/clouddrive/devices/ever_login?pr=ucpro&fr=pc&uc_param_str=&device_platform=PC_APP`;

        const resObj = await safeReq(refreshUrl, {
            method: 'GET',
            headers: {
                'User-Agent': UA,
                'Cookie': currentCookie,
                'Referer': 'https://pan.quark.cn/',
            },
        });

        if (!resObj) return pruneCookie(currentCookie);

        // 校验 401 彻底失效
        if (resObj.data && resObj.data.status === 401) {
            mylog('❌ Cookie 已彻底失效 (401)');
            return "";
        }

        const resHeaders = resObj.headers || {};
        const setCookieHeader = resHeaders['set-cookie'] || resHeaders['Set-Cookie'] || "";

        // 解析并合并 Cookie
        let workingCookie = currentCookie;

        if (setCookieHeader) {
            // 处理 Set-Cookie 可能是数组或字符串的情况
            const cookiesToProcess = Array.isArray(setCookieHeader) ? setCookieHeader : [setCookieHeader];

            cookiesToProcess.forEach(cookieLine => {
                const match = cookieLine.match(/__puus=([^;]+)/);
                if (match && match[1]) {
                    const newPuus = match[1];
                    const currentPuusMatch = workingCookie.match(/__puus=([^;]+)/);
                    const currentPuus = currentPuusMatch ? currentPuusMatch[1] : "";

                    if (newPuus !== currentPuus) {
                        // mylog(`🎉 成功换取新 __puus`);
                        const regex = new RegExp(`(__puus=)[^;]*`);
                        workingCookie = regex.test(workingCookie)
                            ? workingCookie.replace(regex, `$1${newPuus}`)
                            : `${workingCookie}; __puus=${newPuus}`;
                    }
                }
            });
        }

        // 最终返回经过精简净化后的 Cookie
        return pruneCookie(workingCookie);

    } catch (error) {
        mylog(`🚨 刷新请求异常: ${error.message}`);
        return pruneCookie(currentCookie);
    }
}

const quarkApi = {
    // ---------------- 全局配置开关 ----------------
    // false: 默认值，只展示 4K/最高画质（线路简洁，加载速度快）
    // true : 开启全画质线路展示（4K, 2K, 1080P, 720P, 标清）
    ENABLE_ALL_RESOLUTIONS: false,
    // ----------------------------------------------

    _cookie: "",
    _lastRefreshTime: 0,
    _refreshInterval: 15 * 60 * 1000,
    host: "https://pan.quark.cn/",
    ua: UA,
    resNameMap: {
        '4k': '4K',
        'super': '超清',
        'high': '高清',
        'low': '标清',
    },
    // 详情页
    async detail_getVodPlayInfo_fromShareLinks(quarkLinks) {
        let result = {
            vod_name: '',
            vod_play_from: '',
            vod_play_url: '',
            vod_content: ''
        }
        let playFromList = [];
        let playUrlList = [];
        let movieName = '';

        let linkandStokens = await this.batchCheckValidShareLinks(quarkLinks)

        mylog({ linkandStokens })
        if (linkandStokens.length == 0) {
            return
        }

        quarkLinks = linkandStokens.map(i => i.link)
        mylog("【详情页】开始处理有效quarkLinks:", JSON.stringify(quarkLinks));

        for (let i = 0; i < quarkLinks.length; i++) {
            const shareLink = quarkLinks[i];
            mylog(`【处理链接 ${i + 1}/${quarkLinks.length}】: ${shareLink}`);
            const { shareId } = extractQuarkShareInfo(shareLink);
            if (!shareId) continue;
            const stoken = linkandStokens?.[i]?.stoken
            if (!stoken) {
                continue
            };
            const shareVideoInfo = await quarkApi.getShareDetail(shareId, stoken);
            if (!movieName) {
                movieName = shareVideoInfo?.movieName || "未知视频";
            }
            const videos = shareVideoInfo?.list;

            if (videos && videos.length > 0) {
                result.vod_content += (shareLink + '\n')

                const resolutions = this.ENABLE_ALL_RESOLUTIONS
                    ? Object.keys(this.resNameMap)
                    : ['4k'];
                // mylog(`是否开启全画质: ${this.ENABLE_ALL_RESOLUTIONS}, 拟解析画质列表:`, resolutions);

                for (const resKey of resolutions) {
                    let currentResUrls = [];

                    for (const v of videos) {
                        let videoInfoObj = { ...v, resolution: resKey };
                        let videoInfoStr = JSON.stringify(videoInfoObj);
                        const videoName = formatVideoName(v.file_name, v.size);

                        currentResUrls.push(`${videoName}\$${videoInfoStr}`);
                    }

                    if (currentResUrls.length > 0) {
                        playUrlList.push(currentResUrls.join("#"));

                        const basePrefix = quarkLinks.length > 1 ? `夸克#${i + 1}` : "夸克";
                        const countTag = `(${videos.length})`;
                        const resLabel = this.ENABLE_ALL_RESOLUTIONS
                            ? `-${this.resNameMap[resKey]}`
                            : "";

                        const playFromTag = `${basePrefix} ${countTag}${resLabel}`;
                        playFromList.push(playFromTag);

                        mylog(`画质线路生成] 标签: "${playFromTag}", 包含资源数: ${currentResUrls.length}`);
                    }
                }
            }
        }

        result = {
            ...result,
            vod_name: movieName || "夸克视频",
            vod_play_from: playFromList.join("$$$"),
            vod_play_url: playUrlList.join("$$$"),
        };

        return result;
    },

    async playQuarkVideoFromDetailVideoInfo(videoInfo) {
        // mylog("playQuarkVideoFromDetailVideoInfo videoInfo", videoInfo)
        try {
            const finalResolution = videoInfo?.video_max_resolution || videoInfo.resolution

            videoInfo.to_pdir_fid = await quarkApi.createFolder(CacheFolder);
            const newFid = await quarkApi.save(videoInfo);
            // mylog(` 转存成功，新文件 FID: ${newFid}`);
            const allUrls = await quarkApi.getPlayUrl(newFid);
            let targetVideo = allUrls.find(v => v.resolution === finalResolution && v.video_info?.url);
            let playUrl = targetVideo?.video_info?.url

            if (!playUrl) {
                mylog("targetVideo", targetVideo)
                throw new Error("直连获取失败");
            }
            // mylog(`[转存播放] 期望画质: ${finalResolution} | 实际输出画质: ${targetVideo.resolution}`, playUrl);

            return JSON.stringify({
                parse: 0,
                url: playUrl,
                header: {
                    "User-Agent": quarkApi.ua,
                    "Cookie": await quarkApi.getCookie(),
                },
            });
        } catch (e) {
            return backErr(e)
        }
    },




    async playQuarkVideoFromMyFid(myFid) {
        if (!myFid || typeof myFid !== 'string') {
            throw new Error("无效的 FID 参数");
        }
        const allUrls = await quarkApi.getPlayUrl(myFid);
        let targetVideo = getBestPlayUrl(allUrls);

        const playUrl = targetVideo?.url || '';
        if (!playUrl) {
            throw new Error("直连获取失败，可能是 Cookie 过期或网络问题");
        }
        mylog('playQuarkVideoFromMyFid playUrl ', playUrl)
        return JSON.stringify({
            parse: 0,
            header: await quarkApi.getHeaders(),
            url: playUrl
        });
    },

    /**
        * 内部方法：统一更新内存与本地持久化缓存（仅保留必要字段）
        */
    setlocalCookie(updatedCookie) {
        const cleanCookie = pruneCookie(updatedCookie);
        this._cookie = cleanCookie;

        if (cleanCookie) {
            LocalCache.set('quarkcookie', cleanCookie);
            // mylog(`✅ 精简 Cookie 已同步至内存与本地缓存: ${cleanCookie}`);
        } else {
            LocalCache.set('quarkcookie', "");
            this._lastRefreshTime = 0;
            mylog(`🧹 Cookie 已清空`);
        }
    },

    /**
     * 外部配置/更新入口：强制校验新配置并更新
     */
    async setCookie(configCookie) {
        // mylog("尝试设置/更新配置 Cookie...");
        let targetCookie = "";

        if (configCookie) {
            targetCookie = await refreshQuarkPuusDirectly(configCookie);
        }

        if (!targetCookie) {
            const localCk = LocalCache.get("quarkcookie");
            if (localCk && localCk !== configCookie) {
                mylog("传入的 Cookie 无效，尝试回退使用本地缓存...");
                targetCookie = await refreshQuarkPuusDirectly(localCk);
            }
        }

        if (targetCookie) {
            this._lastRefreshTime = Date.now();
            this.setlocalCookie(targetCookie);
            // mylog("✅ Cookie 已成功配置并生效");
        } else {
            this.setlocalCookie("");
            mylog("❌ 警告：无法获取有效的 Cookie，请检查配置或重新登录！");
        }
    },

    /**
     * 获取最新可用 Cookie（带 15 分钟节流，防频繁发网络请求触发风控）
     */
    async getCookie() {
        let ck = this._cookie || LocalCache.get("quarkcookie");

        if (!ck) {
            mylog("⚠️ 内存与本地缓存中均无 Cookie");
            return "";
        }

        const now = Date.now();
        // 如果内存中有 Cookie，且距离上次刷新不到 15 分钟，直接返回，不再频繁发请求刷新
        if (this._cookie && (now - this._lastRefreshTime < this._refreshInterval)) {
            return this._cookie;
        }

        const validCk = await refreshQuarkPuusDirectly(ck);

        if (validCk) {
            this._lastRefreshTime = now;
            if (validCk !== this._cookie) {
                this.setlocalCookie(validCk);
            }
            return validCk;
        } else {
            this.setlocalCookie("");
            return "";
        }
    },

    async getHeaders() {
        return {
            'User-Agent': this.ua,
            'Cookie': await this.getCookie(),
            'Referer': `${this.host}`
        };
    },



    async getvip() {
        if (!quarkApi._cookie) return "";
        try {
            const url = `https://drive-pc.quark.cn/1/clouddrive/member?pr=ucpro&fr=pc&uc_param_str=&fetch_subscribe=true&_ch=home&fetch_identity=true`;
            const resObj = await safeReq(url, {
                method: 'GET',
                headers: await quarkApi.getHeaders(),
            });
            return resObj?.data?.data?.member_type || "";
        } catch (e) {
            mylog(` 判断 VIP 状态发生异常: ${e.message}`);
            return "";
        }
    },

    async getstoken(shareLink) {
        const { shareId, password = '' } = extractQuarkShareInfo(shareLink);
        if (!shareId) return "";

        let tokenUrl = `https://drive-h.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc&uc_param_str=`;
        const postData = { "pwd_id": shareId, "passcode": password };
        const headers = await quarkApi.getHeaders();

        let resObj = await safeReq(tokenUrl, {
            method: 'POST',
            headers: headers,
            data: postData
        });

        const tokenData = resObj?.data;

        let stoken = tokenData?.data?.stoken || ''
        if (tokenData?.status !== 200 && tokenData.message) {
            return {
                stoken,
                msg: tokenData?.message || ""
            }
        }
        return {
            stoken,
            msg: tokenData?.message || ""
        }

    },

    async checkIfExitTargetFolder(folderName = "ftv-cache", pdirFid = "0") {
        const url = `https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=0&_page=1&_size=50&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,updated_at:desc&fetch_all_file=1&fetch_risk_file_name=1`;
        try {
            let resObj = await safeReq(url, { method: 'GET', headers: await quarkApi.getHeaders() });
            const list = resObj?.data?.data?.list || [];
            const targetFolder = list.find(item => item.dir && item.file_name === folderName);
            return targetFolder ? targetFolder.fid : '';
        } catch (e) {
            mylog(` checkIfExitTargetFolder 发生异常: ${e.message}`);
            return '';
        }
    },

    async createFolder(folderName, pdirFid = "0") {
        const fid = await quarkApi.checkIfExitTargetFolder(folderName, pdirFid);
        if (fid) {
            mylog(` 删除已存在的文件夹: ${folderName}`);
            await this.delete([fid]);
        }
        try {
            let url = `https://drive-pc.quark.cn/1/clouddrive/file?pr=ucpro&fr=pc&uc_param_str=`;
            let postData = {
                "pdir_fid": pdirFid,
                "file_name": folderName,
                "dir_path": "",
                "dir_init_lock": false
            };
            let resObj = await safeReq(url, { method: 'POST', headers: await quarkApi.getHeaders(), data: postData });
            const resData = resObj?.data;
            if (resData?.status === 200 && resData?.code === 0 && resData?.data) {
                return resData.data.fid;
            }
            return "";
        } catch (e) {
            mylog(` 创建文件夹发生异常: ${e.message}`);
            return "";
        }
    },

    async getFolderFilesFidList(folderName = "ftv-cache") {
        const folderFid = await quarkApi.checkIfExitTargetFolder(folderName);
        if (folderFid) {
            const url = `https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=${folderFid}&_page=1&_size=50&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,updated_at:desc&fetch_all_file=1&fetch_risk_file_name=1`;
            let resObj = await safeReq(url, { method: 'GET', headers: await quarkApi.getHeaders() });
            let list = resObj?.data?.data?.list || [];
            return list.map(i => ({ file_name: i.file_name, fid: i.fid, dir: i.dir }));
        }
        return [];
    },

    async getMyRootQuarkFiles(folderFid = "0") {
        try {
            if (folderFid) {
                const url = `https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=${folderFid}&_page=1&_size=50&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,updated_at:desc&fetch_all_file=1&fetch_risk_file_name=1`;
                let resObj = await safeReq(url, { method: 'GET', headers: await quarkApi.getHeaders() });
                return resObj?.data?.data?.list || [];
            }
            return [];
        } catch (err) {
            mylog("❌ [网盘详情] getMyRootQuarkFiles 故障:", err.message);
            return [];
        }
    },

    async delete(filelist) {
        if (!Array.isArray(filelist) || filelist.length === 0) return false;
        try {
            let url = `https://drive-pc.quark.cn/1/clouddrive/file/delete?pr=ucpro&fr=pc&uc_param_str=`;
            let postData = { "action_type": 2, "filelist": filelist, "exclude_fids": [] };
            let resObj = await safeReq(url, { method: 'POST', headers: await quarkApi.getHeaders(), data: postData });
            const resData = resObj?.data;
            return resData?.status === 200 && resData?.code === 0;
        } catch (e) {
            mylog(` 删除文件发生异常: ${e.message}`);
            return false;
        }
    },



    async getShareDetail(shareId, stoken) {
        const back = { movieName: '', list: [] };
        try {
            // mylog(`【getShareDetail】开始获取分享详情 | shareId: ${shareId}, stoken: ${stoken ? '已提供' : '未提供'}`);

            const buildUrl = (targetFid) => {
                let params = {
                    "pr": "ucpro", "fr": "pc", "uc_param_str": "", "ver": "2",
                    "pwd_id": shareId, "stoken": stoken, "pdir_fid": targetFid,
                    "force": "0", "_page": "1", "_size": "200", "_sort": "file_type:asc,file_name:asc"
                };
                return `https://drive-h.quark.cn/1/clouddrive/share/sharepage/detail?${toQuery(params)}`;
            };

            const folderWorker = async (currentFid, queue) => {
                let url = buildUrl(currentFid);
                // mylog(`[请求文件夹] currentFid: ${currentFid}`);

                let resObj = await safeReq(url, { method: 'GET', headers: await quarkApi.getHeaders() });
                const resData = resObj?.data;
                if (!resData || resData.status !== 200 || resData.code !== 0) {
                    // mylog(`【警告】文件夹 ${currentFid} 返回状态异常，已跳过`);
                    throw new Error(resData?.msg)
                }
                let items = resData.data?.list || [];
                // mylog(`[解析列表] currentFid: ${currentFid} | 获取到 ${items.length} 个子项`);
                for (let item of items) {
                    if (item.dir) {
                        if (!back.movieName || currentFid === "0") {
                            back.movieName = item.file_name;
                            // mylog(`设置目录影片名 movieName: ${back.movieName}`);
                        }
                        queue.push(item.fid);
                    } else {
                        if (isVideoOrMusic(item.file_name)) {
                            const videoItem = {
                                fid: item.fid,
                                file_name: item.file_name,
                                pdir_fid: item.pdir_fid,
                                size: item.size,
                                share_fid_token: item.share_fid_token || "",
                                video_max_resolution: item.video_max_resolution || "4k",
                                dir: false,
                                file: true,
                                shareId: shareId,
                                stoken: stoken
                            };
                            back.list.push(videoItem);
                        }

                    }
                }
                return false;
            };

            let folderQueue = ["0"];
            mylog(`【getShareDetail】启动并发队列扫描...`);
            await limitConcurrencyQueue(folderQueue, folderWorker);

            if (back.movieName === "" && back.list.length > 0) {
                back.movieName = back.list[0].file_name.replace(/\.(mp4|mkv|flv|avi|mov|m3u8)$/i, '');
                mylog(`【getShareDetail】未匹配到目录名，由首个视频名推导影片名: ${back.movieName}`);
            }

            mylog(`【getShareDetail】扫描结束 | 推荐影片名: "${back.movieName}" | 提取视频总数: ${back.list.length}`);
            return back;

        } catch (e) {
            mylog(`【错误】队列扫描发生严重异常: ${e.message}`);
            mylog(`【错误堆栈】: ${e.stack}`);
            return back;
        }
    },

    async save(options) {
        try {
            let url = `https://drive-h.quark.cn/1/clouddrive/share/sharepage/save?pr=ucpro&fr=pc&uc_param_str=`;
            const { fid, share_fid_token, pdir_fid, shareId, stoken, to_pdir_fid = "0" } = options;
            let postData = { "fid_list": [fid], "fid_token_list": [share_fid_token], "pdir_fid": pdir_fid, "pwd_id": shareId, "scene": "link", "stoken": stoken, "to_pdir_fid": to_pdir_fid };

            let resObj = await safeReq(url, { method: 'POST', headers: await quarkApi.getHeaders(), data: postData });
            const resData = resObj?.data;

            if (resData?.code === 0 && resData?.data) {
                let taskResp = resData.data.task_resp;
                if (taskResp?.code === 0 && taskResp?.data) {
                    let innerData = taskResp.data;
                    let saveAsFids = innerData.save_as?.save_as_top_fids || innerData.save_as?.save_as_select_top_fids || [];
                    return saveAsFids.length > 0 ? saveAsFids[0] : "";
                }
            }
            return "";
        } catch (e) {
            mylog(` 转存异常: `, e);
            return "";
        }
    },

    async getPlayUrl(myFid) {
        let url = `https://drive-pc.quark.cn/1/clouddrive/file/v2/play?pr=ucpro&fr=pc&uc_param_str=`;
        let postData = { fid: myFid, resolutions: "normal,low,high,super,2k,4k", supports: 'fmp4' };
        let resObj = await safeReq(url, { method: 'POST', headers: await quarkApi.getHeaders(), data: postData });
        const resData = resObj?.data;

        if (resData?.status === 200 && resData?.code === 0 && resData?.data) {
            const videoList = resData.data.video_list || [];
            // 统一注入 file_name
            return videoList.map(item => ({ ...item, file_name: resData.data.file_name }));
        }
        throw new Error(resData.message)
    },

    async checkIfExitVideosFromShareLink(shareLink) {
        try {
            const { shareId } = extractQuarkShareInfo(shareLink);
            if (!shareId) return false;

            const stoken = await quarkApi.getstoken(shareLink);
            if (!stoken) return false;

            const buildUrl = (targetFid) => {
                let params = {
                    "pr": "ucpro", "fr": "pc", "uc_param_str": "", "ver": "2",
                    "pwd_id": shareId, "stoken": stoken, "pdir_fid": targetFid,
                    "force": "0", "_page": "1", "_size": "200", "_sort": "file_type:asc,file_name:asc"
                };
                return `https://drive-h.quark.cn/1/clouddrive/share/sharepage/detail?${toQuery(params)}`;
            };

            const folderWorker = async (currentFid, queue) => {
                try {
                    let url = buildUrl(currentFid);
                    let resObj = await safeReq(url, { method: 'GET', headers: await quarkApi.getHeaders() });
                    const resData = resObj?.data;
                    if (!resData || resData.status !== 200 || resData.code !== 0) return false;

                    let items = resData.data?.list || [];
                    for (let item of items) {
                        if (item.dir) {
                            queue.push(item.fid);
                        } else if ((item.file_type + "").includes('video') || item.obj_category === 'video') {
                            return true; // 找到即终止队列扫描
                        }
                    }
                } catch (err) {
                    mylog(` 请求文件夹 ${currentFid} 失败:`, err.message);
                }
                return false;
            };

            let folderQueue = ["0"];
            return await limitConcurrencyQueue(folderQueue, folderWorker);
        } catch (error) {
            mylog(` checkIfExitVideosFromShareLink 异常: ${error.message}`);
            return false;
        }
    },


    async batchCheckValidShareLinks(shareLinks) {
        const promises = shareLinks.map(async (link) => {
            try {
                const { stoken, msg } = await quarkApi.getstoken(link);
                return{ link, stoken, msg}
            } catch (err) {
                return null;
            }
        });

        const results = await Promise.all(promises);
        mylog('batchCheckValidShareLinks',results)
        let res = results.filter(item => item?.stoken);
        if (res.length === 0) {
            throw new Error(results.findLast(item => !item?.stoken)?.msg)
        }
        return res
    }
};

function extractQuarkShareInfo(shareurl) {
    if (!shareurl) return { shareId: '', password: '' };

    // 使用 [^/?#]+ 确保遇到 /、? 或 # 时停止匹配 shareId
    const idMatch = shareurl.match(/\/s\/([^/?#]+)/);
    const shareId = idMatch ? idMatch[1] : '';

    // 匹配 pwd 参数，并通过 [^&#]+ 在遇到 & 或 # 时提前停止匹配
    let password = '';
    const pwdParamMatch = shareurl.match(/[?&]pwd=([a-zA-Z0-9]{4,6})(?=[&#]|$)/);
    if (pwdParamMatch) {
        password = pwdParamMatch[1];
    }

    return { shareId, password };
}

async function limitConcurrencyQueue(queue, workerFn, batchSize = 10, delay = 50) {
    while (queue.length > 0) {
        const batch = [];
        while (batch.length < batchSize && queue.length > 0) {
            batch.push(queue.shift());
        }

        const results = await Promise.all(
            batch.map(item => workerFn(item, queue))
        );

        if (results.includes(true)) {
            return true;
        }

        if (queue.length > 0 && delay > 0) {
            await new Promise(resolve => setTimeout(resolve, delay));
        }
    }
    return false;
}

export default quarkApi;