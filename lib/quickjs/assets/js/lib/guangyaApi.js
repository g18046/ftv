import { formatSize } from "./utils.js";

const TAG = "[光鸭API]";
const mylog = (...args) => console.log(TAG, ...args);

let memoryTokenStore = {
    "token_type": "Bearer",
    "access_token": "",
    "refresh_token": "",
    "expires_in": 7200,
    "sub": "aiRRy0KiciHtKXB1",
    "updatedAt": 0
};

let guangyaConfig = {
    "client_id": "",
    "refresh_token": ""
};

let refreshPromise = null;

const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/**
 * 统一解析分享链接，提取 shareId 和 code
 */
function parseShareLink(shareLink) {
    if (!shareLink || typeof shareLink !== 'string') return { shareId: '', code: '' };
    const shareId = shareLink.match(/\/s\/([^?]+)/)?.[1] || '';
    const code = shareLink.match(/[?&]code=([^&]+)/)?.[1] || '';
    return { shareId, code };
}

async function getValidAccessToken() {
    const token = memoryTokenStore.access_token;
    const currentTime = Math.floor(Date.now() / 1000);
    const expiresAt = (memoryTokenStore.updatedAt || 0) + (memoryTokenStore.expires_in || 0);
    const isNeedRefresh = !token || (currentTime >= (expiresAt - 300));

    if (!isNeedRefresh) return token;

    if (refreshPromise) {
        return await refreshPromise;
    }

    refreshPromise = refreshAccessToken().finally(() => {
        refreshPromise = null;
    });

    return await refreshPromise;
}

async function headers() {
    let token = await getValidAccessToken();

    return {
        'Content-Type': 'application/json',
        "referer": "https://www.guangyapan.com/",
        "Authorization": "Bearer " + token,
    };
}

function safeJsonParse(json) {
    try {
        return typeof json === "string" ? JSON.parse(json) : json;
    } catch (e) {
        return json;
    }
}

async function refreshAccessToken() {
    const url = 'https://account.guangyapan.com/v1/auth/token';
    try {
        memoryTokenStore.refresh_token = guangyaConfig?.refresh_token;
        const postData = {
            "client_id": guangyaConfig?.client_id,
            "grant_type": "refresh_token",
            "refresh_token": memoryTokenStore.refresh_token
        };

        let res = await req(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            data: postData
        });
        res = safeJsonParse(res.content);
        if (res?.access_token) {
            memoryTokenStore = {
                "token_type": res.token_type || "Bearer",
                "access_token": res.access_token,
                "refresh_token": res.refresh_token || memoryTokenStore.refresh_token,
                "expires_in": res.expires_in || 7200,
                "sub": res.sub || memoryTokenStore.sub,
                "updatedAt": Math.floor(Date.now() / 1000)
            };
            mylog("✅ Token 刷新成功！");
        }
        return memoryTokenStore.access_token;
    } catch (e) {
        console.error('刷新 Token 失败:', e);
        return "";
    }
}

// 判断是否为视频文件后缀
function isVideoFileName(filename = '') {
    return /\.(mp4|mkv|avi|flv|ts|mov|rmvb|wmv|m3u8|iso)$/i.test(filename);
}

/**
 * 📌 修改点 1：递归获取指定目录下的【所有文件】（不过滤任何类型，只展开文件夹）
 * 纯粹用于轮询时准确统计全量文件数
 */
async function getAllFilesRecursive(apiInstance, targetId) {
    let list = await apiInstance.getFileList(targetId);
    if (!Array.isArray(list) || list.length === 0) return [];

    let allFiles = [];
    for (const file of list) {
        const isDirectory = file.resType == 2 || (!file.ext && !file.fileSize);

        if (isDirectory) {
            const subFiles = await getAllFilesRecursive(apiInstance, file.fileId);
            allFiles.push(...subFiles);
        } else {
            allFiles.push(file);
        }
    }
    return allFiles;
}

/**
 * 📌 修改点 2：从文件列表中过滤出视频文件
 * 存储/轮询完成后，再调用此函数提取用于播放的视频文件
 */
function filterVideoFiles(filesList = []) {
    return filesList.filter(file => {
        const mime = file.mimeType || file.mineType || '';
        const fileName = file.fileName || '';
        const fileSize = file.fileSize || file.size || 0;

        // 视频判断规则：Mime类型包含video OR 视频后缀 OR 文件大于5MB
        return mime.includes('video') || isVideoFileName(fileName) || fileSize > 5 * 1024 * 1024;
    });
}

const GuangyaApi = {
    init(config) {
        guangyaConfig = config;
    },

    /**
     * 🧹 准备全新的缓存文件夹（清理旧文件夹，创建新文件夹）
     */
    async prepareCacheFolder(folderName = "ftv-cache") {
        try {
            // 1. 获取根目录文件列表，查找已存在的同名缓存文件夹
            const rootFiles = await this.getFileList("");
            const oldFolders = rootFiles.filter(item => item.fileName.includes(folderName) && item.resType == 2);

            // 2. 如果存在旧的缓存文件夹，调用批量删除并同步等待清空回收站
            if (oldFolders.length > 0) {
                const oldIds = oldFolders.map(f => f.fileId);
                mylog(`🧹 发现历史缓存文件夹 (数量: ${oldIds.length})，正在清理...`);
                await this.deleteFiles(oldIds, true);
            }

            // 3. 创建全新的缓存文件夹
            const newFolderId = await this.createFolder("", folderName);
            mylog(`📁 已成功重建当次缓存文件夹, FolderId: ${newFolderId}`);
            return newFolderId;
        } catch (error) {
            console.error("准备缓存文件夹发生异常:", error);
            return await this.createFolder("", folderName);
        }
    },

    async get_share_summary(shareLink) {
        try {
            const { shareId } = parseShareLink(shareLink);
            if (!shareId) return null;

            const apiurl = `https://api.guangyapan.com/userres/v1/get_share_summary`;
            let res = safeJsonParse(await req(apiurl, { method: 'POST', data: { shareId } }).content);
            return res?.data?.title || '';
        } catch (error) {
            console.error("获取分享摘要失败:", error);
            return null;
        }
    },

    async getVodDetailFromShareLinks(shareUrlArray, defaultName = "") {
        await this.prepareCacheFolder("ftv-cache").catch(e => console.error("清理缓存失败:", e));

        if (!Array.isArray(shareUrlArray) || shareUrlArray.length === 0) {
            return JSON.stringify({
                list: [{
                    vod_id: "",
                    vod_name: defaultName || "光鸭网盘",
                    vod_play_from: "光鸭网盘",
                    vod_play_url: "",
                    vod_pic: "https://img.icons8.com/color/480/video-playlist.png",
                    vod_content: ""
                }]
            });
        }

        let detectedVodName = defaultName;
        if (!detectedVodName && shareUrlArray[0]) {
            detectedVodName = await this.get_share_summary(shareUrlArray[0]);
        }

        const promises = shareUrlArray.map(async (url) => {
            try {
                const videos = await GuangyaApi.get_share_VideoListFromShareLink(url);
                if (videos && videos.length > 0) {
                    videos.sort((a, b) => (b.fileSize || b.size || 0) - (a.fileSize || a.size || 0));

                    return videos.map((file) => {
                        const cleanName = (file.fileName || "未知资源")
                            .replace(/\.(mp4|mkv|avi|flv|ts|mov|rmvb|wmv|m3u8|iso)$/i, '')
                            .trim();
                        return `${cleanName}$${JSON.stringify(file)}`;
                    });
                }
            } catch (e) {
                mylog(`解析链接失败: ${url}`, e);
            }
            return [];
        });

        const results = await Promise.all(promises);
        const playList = results.flat();

        if (!detectedVodName && playList.length > 0) {
            detectedVodName = playList[0].split('$')[0];
        }

        const primaryLink = shareUrlArray[0] || "";
        let vod = {
            vod_id: primaryLink,
            vod_name: detectedVodName || "光鸭网盘资源",
            vod_remarks: "",
            vod_play_from: "光鸭网盘",
            vod_play_url: playList.join("#"),
            vod_pic: "https://img.icons8.com/color/480/video-playlist.png",
            vod_content: primaryLink
        };
        return JSON.stringify({ list: [vod] });
    },

    /**
     * 解析磁力/离线链接并生成 TVBox 详情（按文件大小从大到小排序）
     */
    async getVodDetailFromClink(clink, defaultName = "") {
        const cacheFolderId = await this.prepareCacheFolder("ftv-cache");

        const videoFiles = await this.getAllVideoInfoFromClink(clink, cacheFolderId);


        // 按文件大小从大到小排序
        videoFiles.sort((a, b) => (b.fileSize || b.size || 0) - (a.fileSize || a.size || 0));

        const playList = videoFiles.map(file => {
            const cleanName = (file.fileName || "未知集数")
                .replace(/\.(mp4|mkv|avi|flv|ts|mov|rmvb|wmv|m3u8|iso)$/i, '')
                .trim();
            const playParam = { fileId: file.fileId, gcid: file.gcid,fileName:cleanName||file.fileName };
            return `[${formatSize(file.fileSize)}]${cleanName}$${JSON.stringify(playParam)}`;
        });

        const firstVideo = videoFiles[0] || {};
        const vodName = defaultName || firstVideo.fileName || "推送磁力";

        let vod = {
            vod_id: clink,
            vod_name: vodName,
            vod_play_from: "光鸭离线"+`(${videoFiles.length})`,
            vod_play_url: playList.join("#"),
            vod_pic: firstVideo?.thumbnail || "https://img.icons8.com/color/480/video-playlist.png",
            vod_content: clink
        };

        mylog(`🚀 [推送detail] vodResult (视频数:${videoFiles.length})`);
        return JSON.stringify({ list: [vod] });
    },

    async playGuangyaFromMyFid(myFid) {
        const playurl = await GuangyaApi.getDownloadUrlFromFileId(myFid);
        return JSON.stringify({
            parse: 0,
            header: { "User-Agent": UA },
            url: playurl
        });
    },

    async playGuangyaFromVideoFileInfo(videoFileInfo) {
        let fileId = typeof videoFileInfo === 'string' ? safeJsonParse(videoFileInfo)?.fileId : videoFileInfo?.fileId;
        const accessToken = typeof videoFileInfo === 'string' ? safeJsonParse(videoFileInfo)?.accessToken : videoFileInfo?.accessToken;

        if (accessToken && fileId) {
            const newVideoFileInfo = await GuangyaApi.restore_share(accessToken, [fileId]);
            if (!newVideoFileInfo) {
                return JSON.stringify({ msg: '转存失败' });
            }
            fileId = newVideoFileInfo.fileId;
        }

        if (!fileId) {
            return JSON.stringify({ parse: 0, url: "" });
        }

        const playurl = await GuangyaApi.getDownloadUrlFromFileId(fileId);

        this.checkAndAutoCleanAsync();

        return JSON.stringify({ parse: 0, header: { "User-Agent": UA }, url: playurl });
    },

    async getFileList(parentId = '') {
        try {
            const url = `https://api.guangyapan.com/userres/v1/file/get_file_list`;
            const postData = { "pageSize": 9999, "orderBy": 3, "sortType": 1, "parentId": parentId, "page": 0 };
            let res = await req(url, { method: 'post', headers: await headers(), data: postData });
            res = safeJsonParse(res.content);
            return res?.data?.list || [];
        } catch (error) {
            console.error(error);
            return [];
        }
    },

    async createFolder(parentId = "", folderName = "ftv-cache") {
        try {
            const url = `https://api.guangyapan.com/userres/v1/file/create_dir`;
            const postData = { "dirName": folderName, "parentId": parentId, "failIfNameExist": false };
            let obj = await req(url, { method: 'post', headers: await headers(), data: postData });
            obj = safeJsonParse(obj.content);
            return obj?.data?.fileId || '';
        } catch (error) {
            console.error(error);
            return '';
        }
    },

    /**
     * 📌 修改点 3：解决只离线了部分文件的问题。
     * 解析离线资源时保留【全量文件索引】，不再跳过非视频文件，确保全部文件转存离线
     */
    async resolve(ciLink) {
        try {
            const url = `https://api.guangyapan.com/cloudcollection/v1/resolve_res`;
            let res = safeJsonParse(await req(url, { method: 'post', headers: await headers(), data: { "url": ciLink } }).content);

            if (!res || res.code == 117) return null;

            let newName = '';
            let subfiles = [];
            let fileIndexes = [];
            const resType = res.data?.resType;

            if (resType == 1) {
                subfiles = res.data?.btResInfo?.subfiles || [];
                newName = res.data?.btResInfo?.fileName || '';
            } else if (resType == 3) {
                newName = res.data?.emuleResInfo?.fileName || '';
            }

            if (subfiles.length > 0) {
                // 彻底保留所有文件索引，让云盘完整离线所有文件
                fileIndexes = subfiles.map(file => file.fileIndex);
            }

            return { newName, fileIndexes };
        } catch (error) {
            mylog(error);
            return null;
        }
    },

    async createTaskWithResolved(ciLink, resolved, cacheFolderFId) {
        try {
            mylog(`createTaskWithResolved ciLink`,ciLink)
            mylog(`⚡ 开始创建离线任务，目标文件夹: ${cacheFolderFId}, 解析结果:`, resolved);
            if (!resolved) return '';
            const { fileIndexes, newName } = resolved;

            const url = `https://api.guangyapan.com/cloudcollection/v1/create_task`;
            const postData = { "fileIndexes": fileIndexes, "url": ciLink, "parentId": cacheFolderFId, "newName": newName };
            mylog(`⚡ 创建离线任务，请求数据:`, postData);
            let res = safeJsonParse(await req(url, { method: 'post', headers: await headers(), data: postData }).content);
            mylog(`⚡ 创建离线任务响应:`, res);
            return res?.data?.taskId || '';
        } catch (error) {
            console.error(error);
            return '';
        }
    },

    /**
     * 📌 修改点 4：轮询时按【全量文件数】判断，完成后过滤视频返回
     */
    async getAllVideoInfoFromClink(clink, targetFolderId = "") {
        try {
            const folderId = targetFolderId || (await this.createFolder("", "ftv-cache"));
            const resolved = await this.resolve(clink);

            if (!resolved || !folderId) return [];

            const expectedCount = resolved.fileIndexes?.length || 1;

            const taskId = await this.createTaskWithResolved(clink, resolved, folderId);
            if (!taskId) return [];

            mylog(`⚡ 开始极速轮询离线结果，目标【总文件数】: ${expectedCount}`);

            // 渐进式轮询全量文件
            const allFiles = await pollForFileFast(async () => {
                // 1. 递归提取目录下所有文件（含文件夹内）
                const files = await getAllFilesRecursive(this, folderId);

                mylog(`⚡ 轮询中，已成功落盘总文件数: ${files.length} / ${expectedCount}`);

                // 2. 只要落盘的总文件数达到预期数量，就立即判定离线成功返回
                if (files.length >= expectedCount) {
                    return files;
                }
                return null;
            });

            // 拿到全量文件后（无论是轮询完成还是超时保底），再统一过滤出视频文件
            const finalAllFiles = (allFiles && allFiles.length > 0)
                ? allFiles
                : await getAllFilesRecursive(this, folderId);

            const videoFiles = filterVideoFiles(finalAllFiles);
            mylog(`🎯 全量文件数: ${finalAllFiles.length}，成功提取视频文件数: ${videoFiles.length}`);

            return videoFiles;
        } catch (error) {
            console.error('❌ 获取离线视频信息发生错误:', error);
            return [];
        }
    },

    async getDownloadUrlFromFileId(fileId = "") {
        try {
            if (!fileId) return "";
            const url = `https://api.guangyapan.com/userres/v1/get_res_download_url`;
            let res = safeJsonParse(await req(url, { method: 'POST', headers: await headers(), data: { fileId } }).content);
            return res.data?.signedURL || '';
        } catch (error) {
            console.error(error);
            return '';
        }
    },

    async deleteFiles(fileIds = [], autoClearRecycle = false) {
        if (!fileIds || fileIds.length === 0) return true;
        try {
            const url = 'https://api.guangyapan.com/userres/v1/file/delete_file';
            let res = safeJsonParse(await req(url, { method: 'POST', headers: await headers(), data: { fileIds } }).content);

            if (autoClearRecycle) {
                await this.clearRrecycleBin().catch(e => {
                    mylog('清空回收站异常，忽略继续执行', e);
                });
            }
            return res?.msg === 'success';
        } catch (error) {
            mylog('删除失败', error);
            return false;
        }
    },

    async clearRrecycleBin() {
        try {
            const url = `https://api.guangyapan.com/userres/v1/file/clear_recycle_bin`;
            let res = safeJsonParse(await req(url, { method: 'POST', headers: await headers() }).content);
            mylog('🧹 异步清空回收站完成');
            return res?.msg === 'success';
        } catch (e) {
            mylog('清空回收站失败', e);
        }
    },

    checkAndAutoCleanAsync() {
        setTimeout(async () => {
            try {
                if (Math.random() < 0.1) {
                    await this.clearRrecycleBin();
                }
            } catch (e) { }
        }, 1000);
    },

    async get_share_page_files_list(shareLink, parentId = "", accessToken) {
        const apiurl = `https://api.guangyapan.com/userres/v1/get_share_page_files_list`;
        const postbody = { "pageSize": 999, accessToken, "orderBy": 0, "sortType": 0, parentId };
        try {
            let res = safeJsonParse(await req(apiurl, { method: 'POST', data: postbody }).content);
            return res?.data?.list || [];
        } catch (error) {
            console.error(error);
            return [];
        }
    },

    async getAllVideosFromShareLink(shareLink, folderId = "", accessToken) {
        const fileList = await this.get_share_page_files_list(shareLink, folderId, accessToken);
        if (!Array.isArray(fileList) || fileList.length === 0) return [];

        let allVideos = [];
        for (const file of fileList) {
            const mime = file.mimeType || file.mineType || '';
            if (file.resType == 2) {
                const subVideos = await this.getAllVideosFromShareLink(shareLink, file.fileId, accessToken);
                allVideos.push(...subVideos);
            } else if (mime.includes('video') || isVideoFileName(file.fileName) || (file.fileSize && file.fileSize > 10 * 1024 * 1024)) {
                file.accessToken = accessToken;
                allVideos.push(file);
            }
        }
        return allVideos;
    },

    async get_share_VideoListFromShareLink(shareLink) {
        const accessToken = await this.get_share_access_token(shareLink);
        if (!accessToken) throw new Error('无法获取分享链接的访问令牌');
        return await this.getAllVideosFromShareLink(shareLink, "", accessToken);
    },

    async get_share_access_token(shareLink) {
        try {
            const { shareId, code } = parseShareLink(shareLink);
            if (!shareId) throw new Error('无法解析分享链接');
            const apiurl = `https://api.guangyapan.com/userres/v1/get_share_access_token`;
            let res = safeJsonParse(await req(apiurl, { method: 'POST', data: { shareId, code } }).content);
            return res?.data?.accessToken || '';
        } catch (error) {
            console.error(error);
            return '';
        }
    },

    /**
     * 📌 修改点 5：优化转存落盘的轮询匹配
     */
    async restore_share(accessToken, fileIds = [''], parentId = "") {
        let targetParentId = parentId;

        if (!targetParentId) {
            const rootFiles = await this.getFileList("");
            const cacheDir = rootFiles.find(item => item.fileName === "ftv-cache" && item.resType == 2);
            targetParentId = cacheDir ? cacheDir.fileId : (await this.createFolder("", "ftv-cache"));
        }

        const apiurl = `https://api.guangyapan.com/userres/v1/restore_share`;
        const postbody = { accessToken, fileIds, parentId: targetParentId };

        try {
            let res = safeJsonParse(await req(apiurl, { method: 'POST', data: postbody, headers: await headers() }).content);

            if (res?.msg !== 'success') {
                return null;
            }

            // 极速轮询转存结果（只要目录中有文件即认为成功）
            return await pollForFileFast(async () => {
                const files = await this.getFileList(targetParentId);
                return files.length > 0 ? files[0] : null;
            });
        } catch (error) {
            console.error("restore_share 异常:", error);
            return null;
        }
    }
};

/**
 * ⚡ 渐进式无限轮询器（直到成功或达到总超时）
 */
async function pollForFileFast(doFn, maxTimeoutMs = 2 * 60 * 1000) {
    const startTime = Date.now();
    let attempt = 0;

    while (true) {
        attempt++;
        try {
            const res = await doFn();
            if (res) {
                mylog(`⚡ 第 ${attempt} 次成功！(耗时: ${((Date.now() - startTime) / 1000).toFixed(1)}s)`);
                return res;
            }
        } catch (e) {
            console.error(`⚠️ 第 ${attempt} 次轮询请求异常:`, e);
        }

        // 超时保护（默认 2 分钟）
        if (maxTimeoutMs > 0 && (Date.now() - startTime) >= maxTimeoutMs) {
            console.warn(`⏳ 轮询已超时 (${maxTimeoutMs / 1000}s)`);
            return null;
        }

        // 动态退避：1~3次(200ms) -> 4~8次(500ms) -> 9~15次(1s) -> 15次以上(2s)
        const delay = attempt <= 3 ? 200 : attempt <= 8 ? 500 : attempt <= 15 ? 1000 : 2000;
        await new Promise(resolve => setTimeout(resolve, delay));
    }
}
function isFolder(file) {
    return file.resType == 2 && !file.ext;
}

function isFile(file) {
    return file.resType == 1 && file.ext;
}

export default GuangyaApi;