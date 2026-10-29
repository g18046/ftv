import req from './req.js';

const testShareLink = 'https://drive.uc.cn/s/59b2885db1f64'


const cookie = `__sdid=AATK/KXmuSwNPOw1TXjGVUGE0vtncRGRrab3bouUBFqkQ1U2766kiQ12cLULkoZt/ZkcbdVy10jEmpUrVouLt9kro/revMAqMHPGQumzesZrrQ==; __pus=9b76e239140dd39f635e954da5a727edAAT+RLmp4X8AtKe5p+1+A3uvc6Vzbr0DR9hWJKZRMaNzFvj0sOY8wQNV7/ZR+DaBGCTeCrbmMtYw53zfrvAvfMKX; __kp=45ddead0-6177-11f1-b845-a3adb385f205; __kps=AAS0Z2qMmHl4bQvieoLx48Dz; __ktd=fBp+N2W/tLicUfhhbn5Row==; __uid=AAS0Z2qMmHl4bQvieoLx48Dz; __puus=d2637e4d5e615d9c2fb1534b7de87208AAS6GAqqi/LeaumXjpo5xZj9wgu6drMWDZhhhy5szErRBinBKpNo3dXA91Rcqtifk3chUs1feKMQffRALmf4OhtOivb8QLLl+63gvxMocQwvD7IWh1pZnorrAA8sADQ5vDhUstEjwmlFGWHYKgDb5roSLg7yKBCZQoK5qmthZxKgJuXynHcwWC9+3BDUyhZH7vE=`

const headers = {
    Host: 'pc-api.uc.cn',
    referer: 'https://drive.uc.cn/',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/89.0.4389.90 Safari/537.36 Edg/89.0.774.54',
    cookie: cookie
}
const api = {
    detail: async function (shareLink) {

        const shareid = extractShareId(shareLink);
        const url = `https://pc-api.uc.cn/1/clouddrive/share/sharepage/v2/detail?pr=UCBrowser&fr=pc`;


        const postData = {
            "pwd_id": shareid,
            "passcode": "",
            "force": 0,
            "page": 1,
            "size": 50,
            "fetch_banner": 1,
            "fetch_share": 1,
            "fetch_total": 1,
            "sort": "file_type:asc,file_name:asc",
            "banner_platform": "other",
            "web_platform": "windows",
            "fetch_error_background": 1
        }
        const response = await req(url, {
            method: 'POST',
            headers: headers,
            data: postData
        })
        const data = response.content.data
        const backData = {
            shareId: shareid,
            stoken: data.token_info.stoken,
            list: data.detail_info.list.map(item => ({
                fid: item.fid,
                file_name: item.file_name,
                pdir_fid: item.pdir_fid,
                size: item.size,
                dir: item.dir,
                file: item.file,
                share_fid_token: item.share_fid_token
            }))

        }
        return backData;
    },
    async getAllVideosFromShareLink(ShareLink) {
        const { stoken, shareId, list } = await api.detail(ShareLink);

        try {
            let folderQueue = list.filter(item => item.dir).map(item => item.fid);

            console.log(` 共有 ${folderQueue.length} 个文件夹需要扫描`);
            let allVideoFiles = [];
            const buildUrl = (targetFid) => {
                let params = {
                    pr: "UCBrowser",
                    fr: "pc",
                    pwd_id: shareId,
                    stoken: stoken,
                    pdir_fid: targetFid,
                    force: 0,
                    _page: 1,
                    _size: 50,
                    _fetch_banner: 0,
                    _fetch_share: 0,
                    _fetch_total: 1,
                    _sort: "file_type:asc,file_name:asc"
                };
                return `https://pc-api.uc.cn/1/clouddrive/share/sharepage/detail?${toQuery(params)}`;
            };
            while (folderQueue.length > 0) {
                let currentFid = folderQueue.shift();
                let url = buildUrl(currentFid);
                console.log(`正在扫描文件夹 fid=${currentFid}，剩余 ${folderQueue.length} 个文件夹`);
                let resData = await req(url, { method: 'GET', headers: headers })

                resData = resData.content

                let items = resData.data?.list || [];
                for (let item of items) {
                    if (item.dir) {
                        folderQueue.push(item.fid);
                    } else {
                        if (item.file_type === 'video' || (item.file_name && item.file_name.match(/\.(mp4|mkv|flv|avi|mov|m3u8)$/i))) {
                            allVideoFiles.push({
                                fid: item.fid,
                                file_name: item.file_name,
                                pdir_fid: item.pdir_fid,
                                size: item.size,
                                status: item.status,
                                share_fid_token: item.share_fid_token || "",
                                dir: false,
                                file: true,
                                shareId: shareId,
                                stoken: stoken
                            });
                        }
                    }
                }
                if (folderQueue.length > 0) await new Promise(resolve => setTimeout(resolve, 150));
            }
            console.log(`从分享链接解析到的视频文件列表数量: `, allVideoFiles.length, "第一个数据", allVideoFiles[0]);
            return allVideoFiles;
        } catch (e) {
            console.error(`队列扫描发生严重异常: `, e);
            return [];
        }
    },
    async getVip() {
        const url = `https://pc-api.uc.cn/1/clouddrive/member?pr=UCBrowser&fr=pc&fetch_subscribe=true&_ch=home`
        const data = await req(url, { method: 'GET', headers: headers })
        const vipType = data.content.data.member_type || ""
        console.log(vipType)

    },
    async save(shareId, fid, stoken) {
        const url = `https://pc-api.uc.cn/1/clouddrive/share/sharepage/save?ve=1.1.0.21&fve=1.8.8&pr=UCBrowser&fr=win&sys=win32&ut=OWzfCxD9h0it3ATdhZexzXnpN0K2zmnsqE4DyUQC1BuFgA%3D%3D&ch=pcuc@default`;
        const postData = {
            "stoken": "a6QGClAJdyl1Pj58VvGYwg6lyWi+JnnlCLdH0NXrFPo=",
            "pwd_id": "59b2885db1f64",
            "fid_list": [
                "66ba9522ea754e3795d1e69bd19c0b1f"
            ],
            "pdir_fid": "4fcd0ee4180c448fa25d77bf6606358f",
            "fid_token_list": [
                "fdfd8d2432d9910dd2b3cc8924deec08"
            ],
            "to_pdir_fid": "076761e7c40b433cac17df6e6343602a"
        }
    }

}

function extractShareId(shareurl) {
    let match = shareurl.match(/\/s\/([a-zA-Z0-9]+)/);
    let shareId = match ? match[1] : null;
    return shareId;
}

function toQuery(obj) {
    let arr = [];
    for (let k in obj) {
        arr.push(k + '=' + encodeURIComponent(obj[k]));
    }
    return arr.join('&');
}


async function test() {
    const data = await api.getAllVideosFromShareLink(testShareLink);
    // await api.getVip()
}

test();
export default api;