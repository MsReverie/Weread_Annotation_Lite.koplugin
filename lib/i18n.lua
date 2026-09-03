local GetText = require("gettext")

local zh = {
    ["Weread Annotation Lite"] = "微信读书划线",
    ["Show Weread underlines and thoughts on local books."] = "在本地书籍上显示微信读书划线和想法。",
    ["Enable underlines and thoughts"] = "显示划线与想法",
    ["Fetch underlines"] = "拉取划线",
    ["Weread Annotation Lite: Fetch underlines"] = "微信读书划线：拉取划线",
    ["Auto prefetch underlines and thoughts"] = "自动预取划线与想法",
    ["Show prefetch notifications"] = "显示预取提示",
    ["Weread QR login"] = "微信读书扫码登录",
    ["Clear current book data"] = "清除当前书籍数据",
    ["No document open."] = "当前没有打开文档。",
    ["Clear Weread annotations for this book?"] = "清除本书的微信读书划线数据？",
    ["Current book data cleared."] = "当前书籍数据已清除。",
    ["No items."] = "没有条目。",
    ["Match this local book first."] = "请先匹配本书。",
    ["Could not detect the current chapter."] = "无法识别当前章节。",
    ["Prefetch started."] = "已开始预取。",
    ["No thoughts for this underline."] = "当前划线没有想法。",
    ["Loading thoughts…"] = "正在加载想法…",
    ["Book matched."] = "书籍已匹配。",
    ["No results."] = "没有结果。",
    ["Select matching book"] = "选择匹配的书籍",
    ["Author"] = "作者",
    ["Search Weread book"] = "搜索微信读书书籍",
    ["Cancel"] = "取消",
    ["Search"] = "搜索",
    ["Please use Weread QR login first. The QR login obtains the official API key automatically."] =
        "请先使用微信读书扫码登录。登录后会自动获取官方 API 密钥。",
    ["Network"] = "网络",
    ["%1: offline"] = "%1：离线",
    ["Sync"] = "同步",
    ["Could not load the Weread chapter list."] = "无法加载微信读书目录。",
    ["Please log in first."] = "请先登录。",
    ["Fetching underlines…"] = "正在拉取划线…",
    ["Weread login has expired."] = "微信读书登录已过期。",
    ["Underline prefetch failed: "] = "划线预取失败：",
    ["Underline prefetch finished (%d matched)."] = "划线预取完成（已匹配 %d 条）。",
    ["Underline prefetch failed: offline."] = "划线预取失败：离线。",
    ["Thought prefetch failed."] = "想法预取失败。",
    ["QR login"] = "扫码登录",
    ["QR login failed:\n%1"] = "扫码登录失败：\n%1",
    ["QR login cancelled."] = "已取消扫码登录。",
    ["The QR code has expired. Please try again."] = "二维码已过期，请重试。",
    ["The verification code has expired. Please try again."] = "验证码已过期，请重试。",
    ["Incorrect verification code."] = "验证码不正确。",
    ["Unknown login response"] = "未知登录响应",
    ["Enter the four-digit verification code shown on your phone."] = "请输入手机上显示的四位验证码。",
    ["Verification code required"] = "需要验证码",
    ["Verify"] = "验证",
    ["The verification code must contain four digits."] = "验证码必须为四位数字。",
    ["Verification timed out. Please try again."] = "验证超时，请重试。",
    ["Unknown account"] = "未知账号",
    ["Weread login successful.\n\nAccount: %1\nOfficial API key: successfully configured"] =
        "微信读书登录成功。\n\n账号：%1\n官方 API 密钥：已成功配置",
    ["Check for updates"] = "检查更新",
    ["Checking for updates…"] = "正在检查更新…",
    ["Downloading update…"] = "正在下载更新…",
    ["Update check failed:\n%1"] = "检查更新失败：\n%1",
    ["Unknown error"] = "未知错误",
    ["Already up to date (v%1)."] = "已是最新版本（v%1）。",
    ["Version %1 is available (installed: %2). Install it?"] = "有新版本 %1（当前：%2）。是否安装？",
    ["Install"] = "安装",
    ["Later"] = "稍后",
    ["Update installation failed:\n%1"] = "安装更新失败：\n%1",
    ["Updated to %1. Restart KOReader to load it?"] = "已更新到 %1。是否重启 KOReader 以加载？",
    ["Restart now"] = "立即重启",
}

local function is_zh(lang)
    lang = tostring(lang or "")
    return lang == "zh" or lang:sub(1, 3) == "zh_" or lang:sub(1, 3) == "zh-"
end

local function _(msgid)
    if type(msgid) ~= "string" or msgid == "" then
        return msgid
    end
    if is_zh(GetText.current_lang) and zh[msgid] then
        return zh[msgid]
    end
    return GetText(msgid)
end

return _
