// 导出模块对象
export const LocalCache = {
    // 默认命名空间
    _rule: 'ftv',

    // // 配置命名空间
    // setRule(rule) {
    //     this._rule = rule;
    //     return this; // 支持链式调用
    // },

    get(key, defaultValue = '') {
        const val = local.get(this._rule, key);
        return (val !== null && val !== undefined && val !== '') ? val : defaultValue;
    },

    set(key, value) {
        const str = (typeof value === 'object') ? JSON.stringify(value) : String(value);
        local.set(this._rule, key, str);
    },

    getObject(key) {
        try {
            const val = this.get(key);
            return val ? JSON.parse(val) : null;
        } catch (e) {
            return null;
        }
    },

    remove(key) {
        local.delete(this._rule, key);
    }
};