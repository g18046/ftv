import req from "./req.js"
import { getMylog } from "./utils.js";

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

// 1. 基础长效 Cookie（放置不变的身份凭证，如 BDUSS、BAIDUID 等）
let cookie = `XFT=K8+eE3bX9WD7kZm4J4//cq6lNJZmabncl4VspRnAhwI=; XFI=884486f1-3cd4-ff5f-2d9c-53e2a0764d60; XFCS=F868363D84C3A02C4C5FA6FB9EBB5A373C1D8FFD4328AC3034309D7A5451D008; csrfToken=gZS7sD6HmVHK4cRB1SKrOyhZ; BAIDUID=CF54FD84CF1E501E50946225164CB740:FG=1; BAIDUID_BFESS=CF54FD84CF1E501E50946225164CB740:FG=1; __bid_n=1a0bf075ffa8064882efb3; Hm_lvt_182d6d59474cf78db37e0b2248640ea5=1789911327; HMACCOUNT=DEEAD1150B646755; newlogin=1; ploganondeg=1; ppfuid=4d4139b6949c14453930f06c90fa732a; XFI=255bac50-b4f8-11f1-a84d-35e61b7e30b7; undefined; XFT=XMTL2N+QRBwANgl/HppeofbTNzuy1MthtBa0+/3HZF4=; BDUSS=DRXcEVpZVVWaXV5NVhjZElDNUxEVHNjTFA4SnVKQTdPfjl5Y0dOQ1JaUEZidGRxSVFBQUFBJCQAAAAAAAAAAAEAAAA6YP1izOzG9Dk5MQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMXhr2rF4a9qT; BDUSS_BFESS=DRXcEVpZVVWaXV5NVhjZElDNUxEVHNjTFA4SnVKQTdPfjl5Y0dOQ1JaUEZidGRxSVFBQUFBJCQAAAAAAAAAAAEAAAA6YP1izOzG9Dk5MQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMXhr2rF4a9qT; STOKEN=fc7e6e7127b0fb6301494ae0383a2643cc3892ae2b426a65ebe711d65eebea41; Hm_lvt_7a3960b6f067eb0085b7f96ff5e660b0=1789911847; PANWEB=1; Hm_lpvt_182d6d59474cf78db37e0b2248640ea5=1789918317; BDCLND=Fef%2BtO5ku4OgYEBFcUXmNTM1Stb%2FnOFk7dUKiNpd7HE%3D; PANPSC=8941845077415961399%3Afuky8UrKH%2BmvdFrlmiD6N1cS2d9ns3O5C61tf8CKQkiUogE0BdWhPHAy8T66GFwAnR2SrT9COgu1kha5%2BjnnHeNHiOwr%2ByPWC%2BYWBHXUXSuAzpMjKfHvSiVcbkeHIEUe5qyWi6dfu0ttcQe%2BbgwEaXWegKR%2ByMKcWP%2FWBC2ONxfgK8WiEYvObjEIKJQ%2BkRn2uPZxTPIZzXRtoLnfYC42LfDSJFbrrClx353Sfy6Ui1wYgiuV7l9mvr%2FZql%2BYuxBLeVLW8rVN%2BrUCCGwaIX39Xj7Xtoplhtl%2BlQ7qwrZwQfXsUQ7%2BYGCTKJKxVlqrIDxM; ndut_fmt=5C4B372781E385103ECD8DB7514D28C2575C60F5A9C2E6FA569B8951451B8CD3; ab_sr=1.0.1_NGRiN2ExNmI0NjgyOTc1ZDRjMjFhMmNmNjQ4ZTZiNGRlMjcxOTY5MTY4ZjlmMzQzNzgzYjFkMmU5OGE3ZGM4MTI4YmRiZGZlNWU1NWZlNGVlNjZmMjE5NzkyMjZjOGI4MjQ3ZTBhNGY4NGU4OTA5YTZhNTU1Zjc2MTliMzUwZjU5NDNjNTUzMTQ4ZGRjYzFmMDQxNTg3MjVmZDNlMzg5ZGQyMDFhZWFjY2FmM2U1OGQ4MmI0NGMwNDczNzg1OTFkN2JmMTIyMjkxNmE0ZGM1NTM3YTdjZmNiOWZiMTY2OTdkODk4MjYwZTQyYWE4M2JhY2ZmNWJjYmY1NWM2Nzk1Mw==; Hm_lpvt_7a3960b6f067eb0085b7f96ff5e660b0=1789919892`;

let bdstoken = '';

// 常见视频后缀列表
const VIDEO_EXTS = ['.mp4', '.mkv', '.avi', '.rmvb', '.flv', '.wmv', '.mov', '.ts', '.m4v'];

function isVideo(filename) {
    if (!filename) return false;
    const ext = filename.slice(filename.lastIndexOf(".")).toLowerCase();
    return VIDEO_EXTS.includes(ext);
}

function toQuery(obj) {
    let arr = [];
    for (let k in obj) {
        arr.push(k + '=' + encodeURIComponent(obj[k]));
    }
    return arr.join('&');
}

// 辅助函数：自动捕获并合并响应头中的 Set-Cookie
function mergeCookie(resHeaders, oldCookie) {
    let setCookieHeader = resHeaders['set-cookie'] || resHeaders['Set-Cookie'];
    if (!setCookieHeader) return oldCookie;

    if (Array.isArray(setCookieHeader)) {
        setCookieHeader = setCookieHeader.join(';');
    }

    let cookiesMap = {};
    oldCookie.split(';').forEach(item => {
        const parts = item.split('=');
        if (parts.length >= 2) cookiesMap[parts[0].trim()] = parts.slice(1).join('=').trim();
    });

    setCookieHeader.split(';').forEach(item => {
        const parts = item.split('=');
        if (parts.length >= 2) {
            const key = parts[0].trim();
            const val = parts.slice(1).join(';').split(';')[0].trim();
            if (!['expires', 'Max-Age', 'path', 'domain', 'secure', 'httponly'].includes(key)) {
                cookiesMap[key] = val;
            }
        }
    });

    let newArr = [];
    for (let k in cookiesMap) {
        newArr.push(`${k}=${cookiesMap[k]}`);
    }
    return newArr.join('; ');
}

const mylog = getMylog("baiduApi")
const baiduApi = {

    getCookie() {
        return cookie;
    },

    // ⭐️ 核心封装：统一请求方法，自动更新 Cookie 并解析 res.data
    async request(url, options = {}) {
        options.headers = options.headers || {};
        options.headers['User-Agent'] = options.headers['User-Agent'] || UA;
        options.headers['Cookie'] = this.getCookie();

        mylog('request url', url);
        let res = await req(url, options);

        // 自动提取响应头中的 Set-Cookie 并更新全局 cookie
        if (res && res.headers) {
            cookie = mergeCookie(res.headers, cookie);
        }

        // 自动将 content 解析为 JSON 挂载到 data 上
        if (res && res.content) {
            try {
                res.data = JSON.parse(res.content);
            } catch (e) {
                res.data = res.content;
            }
        }
        return res;
    },

    list: async function (shareLink) {
        const matchUrl = shareLink.match(/pan\.baidu\.com\/(s\/|wap\/init\?surl=)([^?&#]+)/);
        let matchPwd = shareLink.match(/(?:[?&]pwd=|[提取码密码pwd][：:]\s*)([a-zA-Z0-9]{4})/i);

        if (!matchUrl) throw new Error("解析分享链接失败");
        let rawMatch = matchUrl[2];
        let shorturl = rawMatch.replace(/^1+/, '').split('?')[0].split('#')[0];
        let surl = rawMatch.startsWith('1') ? rawMatch.substring(1) : rawMatch;
        let pwd = matchPwd ? matchPwd[1] : '';

        if (!bdstoken) {
            bdstoken = await this.getbdstoken();
        }

        if (pwd) {
            const verifyUrl = `https://pan.baidu.com/share/verify?surl=${surl}`;
            const verifyBody = `pwd=${pwd}`;

            let verifyRes = await this.request(verifyUrl, {
                method: 'post',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                    'Referer': shareLink
                },
                body: verifyBody
            });

            mylog('verify res:', verifyRes.data);
        }

        let listUrl = `https://pan.baidu.com/share/list?shorturl=${shorturl}&bdstoken=${bdstoken}&web=5&desc=1&showempty=0&page=1&num=9999&order=time&root=1`;

        let res = await this.request(listUrl, {
            method: 'get',
            headers: { 'Referer': shareLink }
        });

        const data = res.data;

        if (data.errno !== 0) {
            throw new Error(`获取文件列表失败 (errno: ${data.errno}): ${data.show_msg || '未知错误'}`);
        }

        return {
            share_id: data.share_id || data.shareid,
            uk: data.uk || data.share_uk,
            list: data.list
        }
    },


    async getMyfiles() {
        let res = await this.request(`https://pan.baidu.com/api/list?order=time&desc=1&num=100&page=1`, {
            method: 'get'
        })

        mylog('getMyfiles res.list', res)

        return res.list || []
    },
    getbdstoken: async function () {
        if (bdstoken) return bdstoken;

        const url = `https://pan.baidu.com/api/gettemplatevariable?fields=[%22bdstoken%22,%22token%22,%22uk%22,%22isdocuser%22,%22servertime%22]`

        let res = await this.request(url, { method: 'get' });
        bdstoken = res.data.result.bdstoken;
        return bdstoken;
    },


    getDirPathFromFile(file, uk) {
        // mylog('getDirPathFromFile file.path', file.path)
        // mylog('getDirPathFromFile file.server_filename', file.server_filename)
        let dirPath = file.path.startsWith('/sharelink') ? file.path : `/sharelink${uk}-${file.fs_id}/${file.server_filename}`
        return dirPath
    },
    getVideosInfoFromShareLink: async function (shareLink) {
        const shareInfo = await this.list(shareLink);
        if (!shareInfo || !shareInfo.uk || !shareInfo.share_id) {
            mylog('获取基础分享信息失败');
            return [];
        }

        const { uk, share_id, list } = shareInfo;
        const resultVideos = [];
        const folderQueue = [];

        for (let i = 0; i < list.length; i++) {
            const item = list[i];
            if (item.isdir == 1) {
                let dirPath = this.getDirPathFromFile(item, uk)
                folderQueue.push({ dirPath: dirPath, fs_id: item.fs_id });
            } else {
                if (isVideo(item.server_filename)) {
                    resultVideos.push(item);
                }
            }
        }

        while (folderQueue.length > 0) {
            const currentFolder = folderQueue.shift();
            const dirPath = currentFolder.dirPath;

            const queryObj = {
                uk: uk,
                shareid: share_id,
                order: 'name',
                desc: 0,
                page: 1,
                num: 1000,
                dir: dirPath
            };

            const query = toQuery(queryObj);
            const url = `https://pan.baidu.com/share/list?${query}`;

            try {
                let res = await this.request(url, {
                    method: 'get',
                    headers: { 'Referer': shareLink }
                });
                const data = res.data;

                if (data.errno !== 0 || !data.list) {
                    mylog(`目录请求异常: ${dirPath}`, data);
                    continue;
                }

                for (let item of data.list) {
                    if (item.isdir === 1) {
                        folderQueue.push({ dirPath: this.getDirPathFromFile(item, uk), fs_id: item.fs_id });
                    } else {
                        if (isVideo(item.server_filename)) {
                            resultVideos.push(item);
                        }
                    }
                }
            } catch (error) {
                mylog(error);
            }
        }

        return {
            shareid: share_id,
            from: uk,
            list: resultVideos,
            referer: shareLink
        };
    },

    deleteFolder: async function (folderPathList = ["/ftv-cache"]) {
        mylog(`正在删除文件夹: ${folderPathList}`);
        const bdstoken = await this.getbdstoken();
        const url = `https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete&bdstoken=${bdstoken}`
        const postData = `filelist=[${folderPathList.map(item => ('\"' + item + '\"'))}]`

        let res = await this.request(url, {
            method: 'post',
            headers: { "Content-Type": 'application/x-www-form-urlencoded' },
            body: postData
        });
        mylog(res.data);
    },

    createFolder: async function (folerPath = "ftv-cache") {
        const bdstoken = await this.getbdstoken();
        if (!bdstoken) {
            mylog('获取百度网盘 bdstoken 失败');
            return;
        }

        let myfiles = await this.getMyfiles() || []
        mylog('myfiles', myfiles)
        if (myfiles.find(item => item.server_filename === 'ftv-cache')) {
            await this.deleteFolder()
            await new Promise((res, rej) => setTimeout(res, 500))
        }

        mylog(`正在创建文件夹: ${folerPath}`);

        const url = `https://pan.baidu.com/api/create?a=commit&bdstoken=${bdstoken}`
        const postData = { "path": folerPath, "isdir": "1", block_list: '[]' }

        let res = await this.request(url, {
            method: 'post',
            headers: { "Content-Type": 'application/x-www-form-urlencoded' },
            body: toQuery(postData)
        });

        mylog('createFolder res.data', res.data)
        return res.data;
    },

    save: async function (options) {
        let { shareid, from, fs_id, path, referer } = options;

        if (!path) path = '/ftv-cache'
        if (!shareid || !from || !fs_id || !path || !referer) {
            mylog('参数不全', options);
            return;
        }
        await this.createFolder(path)

        mylog('正在保存文件 options:', options);

        const url = `https://pan.baidu.com/share/transfer?shareid=${shareid}&from=${from}&ondup=newcopy`
        const postData = `fsidlist=[${fs_id}]&path=${path}`

        let res = await this.request(url, {
            method: 'post',
            headers: { "Content-Type": 'application/x-www-form-urlencoded', referer: referer },
            body: postData
        });

        const data = res.data;

        if (data.errno !== 0) {
            mylog('保存文件失败', data);
            return [];
        }
        mylog('save data.extra.list', data.extra.list)
        return data.extra.list;
    },

    async getPlayLinkFromMyFilePath(myfile) {

        if (!myfile.to) {
            throw new Error(myfile)
        }

        let arr = `["${myfile.to}"]`
        let reqbody = `target=${encodeURIComponent(arr)}&dlink=1`

        mylog('reqbody', reqbody)
        let res = await this.request(`https://pan.baidu.com/api/filemetas?`, {
            method: "post",
            headers: { "Content-Type": 'application/x-www-form-urlencoded' },
            body: reqbody
        })


        let link = res?.data?.info?.[0]?.dlink

        mylog('link',link)

        return link|| ''
    }

}

async function test() {
    const { list, shareid, referer, from } = await baiduApi.getVideosInfoFromShareLink(`https://pan.baidu.com/s/134VdHQb0aaOzCO_Vo3cCuw?pwd=wogg`)
    mylog('获取到的视频列表：', list.length, list[0]);
    mylog('获取到的视频信息：', { shareid, referer, from });

    let [myfile] = await baiduApi.save({
        shareid, referer, from, fs_id: list[0].fs_id
    })

    baiduApi.getPlayLinkFromMyFilePath(myfile)
}

test();

export default baiduApi;