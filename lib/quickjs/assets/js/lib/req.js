/**
 * 优化后的 req 函数，支持 JSON 自动处理
 * 
 * 
 * 
 */


let responseHeaders = {}
async function req(url, options = {}) {
  try {
    const fetchOptions = {
      method: (options.method || 'GET').toUpperCase(),
      headers: { ...options.headers }, // 浅拷贝，避免修改原对象
    };

    // 如果提供了 data 且是对象，自动处理 JSON
    let body = options.body || options.data;
    if (body && typeof body === 'object' && !(body instanceof FormData) && !(body instanceof URLSearchParams)) {
      // 自动设置 Content-Type
      if (!fetchOptions.headers['Content-Type']) {
        fetchOptions.headers['Content-Type'] = 'application/json';
      }
      // 自动序列化
      body = JSON.stringify(body);
    }
    
    if (body) {
      fetchOptions.body = body;
    }

    const response = await fetch(url, fetchOptions);
    
    responseHeaders = {};
    response.headers.forEach((value, key) => {
      responseHeaders[key] = value;
    });

    const content = await response.text();

    return {
      headers: responseHeaders,
      code: response.status,
      content: content
    };

  } catch (error) {
    return {
      headers: responseHeaders,
      code: 500,
      content: error.message
    };
  }
}

export default req;