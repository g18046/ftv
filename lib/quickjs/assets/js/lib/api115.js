import { safeJsonParse, formatVideoName, formatSize, getMylog, VIDEO_REGEX, backErr } from './utils.js';
import { LocalCache } from './localCache.js';

const mylog = getMylog('115api');

// 全局强制使用异步 http 接口，最大化利用并发，绝不卡顿主线程
const request = async (url, options = {}) => {
    let res = await http(url, {
        method: "GET",
        headers: api.getHeaders(options),
        ...options
    });
    let data = safeJsonParse(res?.content);
    if (data?.error) {
        mylog(data);
        mylog(data?.error);
        throw new Error(data.error);
    }
    return data;
};

const DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 115Browser/36.0.1 Chromium/125.0';

const api = {
    _cookie: '',

    setCookie(newCookie) {
        this._cookie = (newCookie || "").replace(/[\r\n]/g, "").trim();
        LocalCache.set('api115_cookie', this._cookie);
    },

    getCookie() {
        if (!this._cookie) {
            this._cookie = LocalCache.get('api115_cookie') || '';
        }
        return this._cookie;
    },

    getHeaders(extraHeaders = {}) {
        return {
            'User-Agent': DEFAULT_USER_AGENT,
            'cookie': this.getCookie(),
            ...extraHeaders
        };
    },

    // 判断是否为有效的 115 网盘分享链接
    is115ShareLink(url) {
        if (typeof url !== 'string' || !url.trim()) return false;
        const pattern = /^https?:\/\/(?:[a-zA-Z0-9-]+\.)*(?:115\.com|115cdn\.com|anxia\.com)\/s\/[a-zA-Z0-9]+(?:\?.*)?$/i;
        return pattern.test(url.trim());
    },

    /**
     * 妥善处理缓存文件夹与回收站的清理逻辑
     * @param {boolean} forceRecreate 是否强制清理旧文件夹并新建
     */
    async purgeAndGetCacheFolder(forceRecreate = true) {
        const folderName = "ftv-cache";
        let cacheFolderCid = await this.getCacheFolder();

        if (cacheFolderCid && forceRecreate) {
            mylog("正在删除旧 ftv-cache 缓存文件夹, CID:", cacheFolderCid);
            await this.delete(cacheFolderCid, '0');
            cacheFolderCid = null;
        }

        if (!cacheFolderCid) {
            mylog("正在新建全新的 ftv-cache 缓存文件夹...");
            const url = "https://webapi.115.com/files/add";
            const body = `pid=0&cname=${encodeURIComponent(folderName)}`;
            const h = this.getHeaders({ "Content-Type": "application/x-www-form-urlencoded" });

            const resJson = await request(url, {
                method: "POST",
                headers: h,
                body: body
            });

            if (resJson?.error) {
                throw new Error(`创建缓存文件夹失败: ${resJson.error}`);
            }
            cacheFolderCid = resJson?.cid || "";
            mylog("全新 ftv-cache 创建成功, CID:", cacheFolderCid);
        }

        await this.cleanRecycleBinTarget(folderName);
        return cacheFolderCid;
    },

    /**
     * 彻底清空回收站中包含 targetName 的所有记录
     */
    async cleanRecycleBinTarget(targetName = "ftv-cache") {
        const rids = await this.getRecycleBinTargetRids(targetName);
        if (rids && rids.length > 0) {
            mylog(`查找到回收站待清理的 ${targetName} 记录共 ${rids.length} 条，发起精清...`);
            await this.clean(rids);
        } else {
            mylog("回收站无符合条件的废弃缓存文件夹");
        }
    },

    async getRecycleBinTargetRids(targetName = "ftv-cache") {
        const url = 'https://webapi.115.com/rb?aid=7&cid=0&offset=0&limit=100&source=&format=json';
        const resJson = await request(url, {
            method: 'GET',
            headers: this.getHeaders()
        });
        const list = resJson?.data || [];

        return list
            .filter(item => item.file_name && item.file_name.includes(targetName))
            .map(item => item.id);
    },

    async clean(rids = []) {
        try {
            const ridArray = typeof rids === 'string' ? [rids] : rids;
            if (!ridArray || ridArray.length === 0) return;
            const url = `https://webapi.115.com/rb/clean`;
            const bodyParams = ['password=200154'];
            ridArray.forEach((rid, index) => {
                bodyParams.push(`rid[${index}]=${encodeURIComponent(rid)}`);
            });

            const body = bodyParams.join('&');
            const resJson = await request(url, {
                method: "POST",
                headers: this.getHeaders({ "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" }),
                body: body
            });

            mylog("回收站精准清理结果:", resJson?.state ? "成功" : resJson?.error || "失败");
        } catch (e) {
            backErr(e)
        }
    },

    async delete(fids = [], fromFolderCid = "0") {
        const fidArray = Array.isArray(fids) ? fids : [fids];
        if (fidArray.length === 0) return;

        const url = `https://webapi.115.com/rb/delete`;
        const bodyParams = [`pid=${fromFolderCid}`, 'ignore_warn=0', 'format=json'];
        fidArray.forEach((fid, index) => {
            bodyParams.push(`fid[${index}]=${encodeURIComponent(fid)}`);
        });

        const body = bodyParams.join('&');
        const resJson = await request(url, {
            method: "POST",
            headers: this.getHeaders({ "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" }),
            body: body
        });
        mylog("移入回收站动作完毕, 结果:", resJson?.state ? "成功" : resJson?.error || "失败");
    },

    /**
     * 处理多个/单个磁链链接
     */
    async detail_getVodPlayInfo_fromClink(clink = '') {
        mylog("【详情页】处理磁链:", clink);

        let links = [];
        if (Array.isArray(clink)) {
            links = clink;
        } else if (typeof clink === 'string' && clink.trim()) {
            links = clink.split(/[\n,\s]+/).map(item => item.trim()).filter(Boolean);
        }

        links = [...new Set(links.filter(l => typeof l === 'string' && l.length > 0))];
        if (links.length === 0) {
            return JSON.stringify({ list: [] });
        }

        // 维持并发解析，此处单条任务异常会直接往外抛出
        const results = await Promise.all(
            links.map(async (link) => {
                const videos = (await this.getLiXianVideoList(link)) || [];
                return { link, videos };
            })
        );

        const validResults = results.filter(r => r.videos && r.videos.length > 0);
        if (validResults.length === 0) {
            return JSON.stringify({ list: [] });
        }

        const isSingle = validResults.length === 1;
        const vodList = [];

        validResults.forEach(({ link, videos }, index) => {
            videos.sort((a, b) => (b.s || 0) - (a.s || 0));
            const movieName = videos[0].n || videos[0].shareName || "磁力视频";

            const playUrl = videos.map(video => {
                const formattedSize = formatSize(video.s);
                const titleWithSize = `[${formattedSize}] ${video.n}`;
                const vodItem = JSON.stringify({
                    fid: video.fid,
                    n: video.n,
                    pc: video.pc
                });
                return `${titleWithSize}$${vodItem}`;
            }).join("#");

            vodList.push({
                vod_name: movieName,
                vod_play_from: isSingle ? `115磁链(${videos.length}集)` : `115磁链-${index + 1}(${videos.length}集)`,
                vod_play_url: playUrl,
                vod_pic: "https://img.icons8.com/color/480/video-playlist.png",
                vod_content: link
            });
        });

        mylog("【详情页】磁链解析生成的 vod 列表:", vodList);
        return JSON.stringify({ list: vodList });
    },

   /**
     * 处理多个/单个分享链接，解析 115 网盘中的视频列表并生成 TVBox 格式的视频详情结构。
     * 
     * @async
     * @function detail_getVodPlayInfo_fromShareLinks
     * @param {string|string[]} [shareLink=''] - 需要解析的 115 分享链接，支持单条字符串（空格/换行/逗号分隔）或链接数组。
     * @param {boolean} [isFinal=true] - 控制返回格式：true 时返回封装好带有 `list` 的 JSON 字符串；false 时返回纯 `vodList` 数组。
        * @returns {Promise<string|Object[]>} 返回 JSON 字符串（当 isFinal 为 true 时）或 vod 列表对象数组（当 isFinal 为 false 时）。
     * 
     * @example
     * // 示例 1: 直接返回符合 TVBox 标准的 JSON 字符串
     * const jsonResult = await api115.detail_getVodPlayInfo_fromShareLinks("https://115.com/s/123456");
     * 
     * // 示例 2: 作为子模块调用，仅获取数组用于上层聚合拼接
     * const listArray = await api115.detail_getVodPlayInfo_fromShareLinks(["link1", "link2"], false);
     */
    async detail_getVodPlayInfo_fromShareLinks(shareLink = '', isFinal = true) {
        mylog("【详情页】处理分享链接:", shareLink);

        let links = [];
        if (Array.isArray(shareLink)) {
            links = shareLink;
        } else if (typeof shareLink === 'string' && shareLink.trim()) {
            links = shareLink.split(/[\n,\s]+/).map(item => item.trim()).filter(Boolean);
        }

        const validLinks = [...new Set(links.filter(link => this.is115ShareLink(link)))];
        if (validLinks.length === 0) {
            mylog("未识别到有效的 115 分享链接，跳过处理:", shareLink);
            return JSON.stringify({ list: [] });
        }

        const results = await Promise.all(
            validLinks.map(async (link) => {
                const videos = (await this.getAllVideosFromShareLink(link)) || [];
                return { link, videos };
            })
        );

        const validResults = results.filter(r => r.videos && r.videos.length > 0);
        if (validResults.length === 0) {
            return JSON.stringify({ list: [] });
        }

        const isSingle = validResults.length === 1;
        const vodList = [];
        validResults.forEach(({ link, videos }, index) => {
            const movieName = videos[0].shareName || "推送视频";
            const playUrl = videos.map(video => {
                const vodItem = JSON.stringify({
                    fid: video.fid,
                    shareId: video.shareId,
                    password: video.password
                });
                return `${formatVideoName(video.n, video.s)}$${vodItem}`;
            }).join("#");

            vodList.push({
                vod_name: movieName,
                vod_play_from: isSingle ? `115网盘(${videos.length}集)` : `115网盘-${index + 1}(${videos.length}集)`,
                vod_play_url: playUrl,
                vod_pic: "https://img.icons8.com/color/480/video-playlist.png",
                vod_content: link
            });
        });
        mylog("【详情页】分享链接解析生成的 vod 列表:", vodList);

        if (isFinal) {
            return JSON.stringify({ list: vodList });
        } else {
            return vodList
        }

    },

    async playVideoFromMyNewFile(myNewFile) {
        const pc = myNewFile?.pc || "";
        if (!pc) {
            throw new Error("播放失败：PickCode 为空！");
        }
        let playType = myNewFile.class === 'PLAY_MUS_MAP_ID' ? "music" : 'video';

        if (playType === "music") {
            return JSON.stringify({
                parse: 0,
                url: `https://webapi.115.com/files/music?pickcode=${myNewFile.pc}&share_id=&download=2`,
                header: {
                    'User-Agent': DEFAULT_USER_AGENT,
                    referer: "https://115.com/",
                    cookie: this.getCookie(),
                }
            });
        }
        const playUrl = `https://115vod.com/webapi/files/video?pickcode=${pc}&share_id=0&local=1`;
        let resJson = await request(playUrl, {
            method: 'GET',
            headers: this.getHeaders({ referer: playUrl })
        });
        let finalPlayUrl = resJson?.origin_file_url || resJson?.download_url || '';
        return JSON.stringify({
            parse: 0,
            url: finalPlayUrl,
            header: {
                'User-Agent': DEFAULT_USER_AGENT,
                cookie: this.getCookie(),
                "Referer": "https://115vod.com/"
            }
        });
    },

    async playVideoFromDetailVideoInfo(videoInfo) {
        const info = typeof videoInfo === 'string' ? JSON.parse(videoInfo) : videoInfo;
        const { fid, shareId, password } = info;
        if (!fid) {
            throw new Error('playVideoFromDetailVideoInfo err fid');
        }
        const myNewFile = await this.save(fid, shareId, password);
        return await this.playVideoFromMyNewFile(myNewFile);
    },

    async getShareDetail(shareLink, cid = '0') {
        const shareInfo = extractShareInfo(shareLink);
        if (!shareInfo) throw new Error("无效的 115 分享链接");

        const { shareId, password } = shareInfo;
        const url = `https://115cdn.com/webapi/share/snap?share_code=${shareId}&offset=0&limit=1000&asc=0&o=file_name&cid=${cid}&receive_code=${encodeURIComponent(password)}&format=json`;

        const res = await request(url, {
            method: 'GET',
            headers: this.getHeaders()
        });

        // mylog('getShareDetail res?.data?.list?.[0]', res?.data?.list?.[0]);
        if (!res?.data?.list?.[0]) {
            mylog('getShareDetail res', res);
        }
        return {
            shareId,
            password,
            list: res?.data?.list || [],
            shareName: res?.data?.shareinfo?.share_title || ''
        };
    },

    async getAllVideosFromShareLink(shareLink = '') {
        const { shareId, password, list, shareName = '' } = await this.getShareDetail(shareLink);
        if (!shareId) return [];

        let currentFolders = [];
        const allVideoFiles = [];

        const processItem = (item) => {
            if (!item.fid) {
                currentFolders.push(item.cid);
            } else if (VIDEO_REGEX.test(item.n || item.ico) || item.class === 'AVI') {
                allVideoFiles.push({
                    ...item,
                    shareId,
                    password,
                    shareName,
                });
            }
        };

        for (const item of list || []) {
            processItem(item);
        }

        const buildUrl = (cid) =>
            `https://115cdn.com/webapi/share/snap?share_code=${shareId}&offset=0&limit=1000&asc=0&o=file_name&cid=${cid}&receive_code=${encodeURIComponent(password)}&format=json`;

        while (currentFolders.length > 0) {
            const foldersToProcess = [...currentFolders];
            currentFolders = [];

            for (const cid of foldersToProcess) {
                const resData = await request(buildUrl(cid), { method: 'GET', headers: this.getHeaders() });
                const items = resData?.data?.list || [];
                for (const item of items) {
                    processItem(item);
                }
            }
        }
        mylog(`解析分享链视频成功，找到 ${allVideoFiles.length} 个视频文件`);
        allVideoFiles.sort((a, b) =>
            (a.n || '').localeCompare(b.n || '', undefined, { numeric: true, sensitivity: 'base' })
        );
        return allVideoFiles;
    },

    async getNewCacheVideos() {
        const targetFolderCid = await this.getCacheFolder();
        if (!targetFolderCid) return null;

        const allFiles = await this.getAllFilesRecursive(targetFolderCid);
        if (!allFiles || allFiles.length === 0) return null;
        return allFiles;
    },

    async getAllFilesRecursive(startCid) {
        let currentFolders = [startCid];
        const videoFiles = [];

        while (currentFolders.length > 0) {
            const cid = currentFolders.shift();
            const items = await this.listFolderFiles(cid);

            if (Array.isArray(items)) {
                for (const item of items) {
                    if (item.cid && !item.fid) {
                        currentFolders.push(item.cid);
                    } else if (item.fid) {
                        const isVideo = VIDEO_REGEX.test(item.n || item.ico) || item.class === 'AVI';
                        if (isVideo) {
                            videoFiles.push(item);
                        }
                    }
                }
            }
        }
        return videoFiles;
    },

    async listFolderFiles(cid = '0') {
        const url = `https://webapi.115.com/files?aid=1&cid=${cid}&offset=0&limit=1000&type=0&show_dir=1&fc_mix=0&natsort=1&count_folders=1&format=json&custom_order=0`;
        const json = await request(url, {
            method: 'GET',
            headers: this.getHeaders()
        });
        return json?.data || [];
    },

    async getCacheFolder() {
        const rootfiles = await this.listFolderFiles('0');
        const cacheFolderFile = rootfiles.find(file => file.n === "ftv-cache" || file.ns === "ftv-cache");
        return cacheFolderFile ? cacheFolderFile.cid : null;
    },

    async save(fids, shareId, password) {
        const fidStr = Array.isArray(fids) ? fids.join(",") : fids;
        const targetFolderCid = await this.purgeAndGetCacheFolder(true);

        const url = `https://115cdn.com/webapi/share/receive`;
        const body = `share_code=${shareId}&receive_code=${encodeURIComponent(password)}&file_id=${encodeURIComponent(fidStr)}&cid=${targetFolderCid}`;
        mylog("发起保存到 115 动作...", body);

        const resJson = await request(url, {
            method: "POST",
            headers: this.getHeaders({ "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" }),
            body: body
        });

        mylog('save 结果', resJson);
        if (resJson?.error) {
            throw new Error(`转存失败: ${resJson.error}`);
        }
        let tryCount = 0;
        const maxTryCount = 10;
        let pollDelay = 500;
        let files = null;
        while (tryCount < maxTryCount) {
            await new Promise(resolve => setTimeout(resolve, pollDelay));
            tryCount++;

            files = await this.getNewCacheVideos();
            if (files && files.length > 0) {
                mylog(`第 ${tryCount} 次轮询：文件已成功落盘就绪`);
                break;
            }
            pollDelay = Math.min(pollDelay + 300, 2000);
        }
        if (!files || files.length === 0) {
            throw new Error("转存超时：未能在缓存目录中检测到生成的文件");
        }
        return files[0] || null;
    },
    async getLiXianVideoList(clink) {
        if (!clink) return null;
        const targetFolderCid = await this.purgeAndGetCacheFolder(true);
        await request('https://clouddownload.115.com/web/?ac=task_clear', {
            method: "POST",
            headers: this.getHeaders()
        });
        const body = `url[0]=${encodeURIComponent(clink)}&wp_path_id=${targetFolderCid}`;
        mylog("发送磁力离线添加任务...", body);
        const addUrl = `https://clouddownload.115.com/web/?ac=add_task_urls`;
        await request(addUrl, {
            method: "POST",
            headers: this.getHeaders({ "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" }),
            body: body
        });
        const taskCountUrl = `https://clouddownload.115.com/web/?ac=task_count`;
        let tryCount = 0;
        const maxTryCount = 15;
        let pollDelay = 600;
        while (tryCount < maxTryCount) {
            await new Promise(resolve => setTimeout(resolve, pollDelay));
            tryCount++;

            const countRes = await request(taskCountUrl, {
                method: "POST",
                headers: this.getHeaders({ "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" })
            });
            const downloadingCount = countRes?.downloading_count;
            if (downloadingCount === 0 || downloadingCount === undefined) {
                mylog(`第 ${tryCount} 次轮询确认：离线任务处理完毕`);
                break;
            }
            pollDelay = Math.min(pollDelay + 300, 2000);
        }
        return await this.getNewCacheVideos();
    }
};
function extractShareInfo(shareurl) {
    if (!api.is115ShareLink(shareurl)) return null;
    const match = shareurl.match(/\/s\/([^?]+)\?password=([^&#/]+)/);
    return match ? {
        shareId: match[1],
        password: match[2]
    } : null;
}

export default api;