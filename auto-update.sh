#!/bin/sh

SCRIPT_VERSION="2.0.0"

# 日志配置
LOG_FILE="/tmp/auto-update.log"
DEVICE_MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || echo '未知设备')"
PUSH_TITLE="$DEVICE_MODEL 插件更新通知"

# 排除列表（不自动更新的包）
EXCLUDE_PACKAGES="kernel kmod- base-files busybox libc musl opkg uclient-fetch ca-bundle ca-certificates luci-app-lucky"

# 需要初始化为空的变量列表
EMPTY_VARS="SYS_ARCH PKG_EXT PKG_INSTALL PKG_UPDATE AUTO_UPDATE CRON_TIME INSTALL_PRIORITY GITEE_TOKEN GITCODE_TOKEN THIRD_PARTY_INSTALLED API_SOURCES THIRD_PARTY_INSTALLER ARCH_FALLBACK OFFICIAL_PACKAGES NON_OFFICIAL_PACKAGES OFFICIAL_UPDATED OFFICIAL_SKIPPED OFFICIAL_FAILED THIRDPARTY_UPDATED THIRDPARTY_SAME THIRDPARTY_NOTFOUND THIRDPARTY_FAILED UPDATED_PACKAGES FAILED_PACKAGES CONFIG_BACKED_UP"

# 批量初始化变量
for var in $EMPTY_VARS; do
    eval "$var=''"
done

CONFIG_BACKED_UP=0

# 功能: 日志输出
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    logger -t "auto-update" "$1" 2>/dev/null || true
}

# 功能: 加载配置文件
load_config() {
    local conf="/etc/auto-setup.conf"
    if [ ! -f "$conf" ]; then
        log "配置文件不存在: $conf"
        log "请先运行 auto-setup 进行初始化"
        return 1
    fi
    
    . "$conf"
    log "配置已加载: $conf"
    
    local has_issue=0
    local required_vars="AUTO_UPDATE CRON_TIME INSTALL_PRIORITY SYS_ARCH PKG_EXT PKG_INSTALL API_SOURCES ARCH_FALLBACK"
    
    for var in $required_vars; do
        eval "local val=\$$var"
        if [ -z "$val" ]; then
            log "  配置项 $var 缺失"
            has_issue=1
        fi
    done
    
    [ $has_issue -eq 0 ] && log "  所有配置项正常"
    
    if [ -z "$SYS_ARCH" ] || [ -z "$PKG_INSTALL" ] || [ -z "$API_SOURCES" ]; then
        log "缺少关键配置，请重新运行 auto-setup"
        return 1
    fi
    
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        PKG_UPDATE="opkg update"
    else
        PKG_UPDATE="apk update"
    fi
    
    return 0
}

# 功能: 加载公共函数库
load_common_lib() {
    local lib="/usr/lib/auto-tools-common.sh"
    if [ ! -f "$lib" ]; then
        log "公共函数库不存在: $lib"
        return 1
    fi
    
    . "$lib"
    log "公共函数库已加载"
    return 0
}

# 功能: 检查包是否在排除列表
# 参数: $1=包名
# 返回: 0=需要排除, 1=不排除
is_package_excluded() {
    case "$1" in luci-i18n-*) return 0 ;; esac
    for pattern in $EXCLUDE_PACKAGES; do
        case "$1" in $pattern*) return 0 ;; esac
    done
    return 1
}

# 功能: 检查包是否已安装
# 参数: $1=包名
# 返回: 0=已安装, 1=未安装
is_installed() {
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        opkg list-installed | grep -q "^$1 "
    else
        apk info -e "$1" >/dev/null 2>&1
    fi
}

# 功能: 获取包版本
# 参数: $1=查询类型(list-installed/list), $2=包名
# 输出: 版本号
get_package_version() {
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        opkg "$1" 2>/dev/null | grep "^$2 " | awk '{print $3}'
    else
        case "$1" in
            list-installed)
                apk info "$2" 2>/dev/null | grep "^$2-" | sed "s/^$2-//" | cut -d'-' -f1
                ;;
            list)
                apk search "$2" 2>/dev/null | grep "^$2-" | sed "s/^$2-//" | cut -d'-' -f1
                ;;
        esac
    fi
}

# 功能: 安装语言包
# 参数: $1=主包名
install_language_package() {
    local pkg="$1"
    local lang_pkg=""
    
    case "$pkg" in
        luci-app-*)   lang_pkg="luci-i18n-${pkg#luci-app-}-zh-cn" ;;
        luci-theme-*) lang_pkg="luci-i18n-theme-${pkg#luci-theme-}-zh-cn" ;;
        *) return 0 ;;
    esac
    
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        opkg list 2>/dev/null | grep -q "^$lang_pkg " || return 0
    else
        apk search "$lang_pkg" 2>/dev/null | grep -q "^$lang_pkg" || return 0
    fi
    
    local action="安装"
    is_installed "$lang_pkg" && action="升级"
    
    log "    ${action}语言包 $lang_pkg"
    if $PKG_INSTALL "$lang_pkg" >>"$LOG_FILE" 2>&1; then
        log "    语言包${action}成功"
    else
        log "    语言包${action}失败（不影响主程序）"
    fi
}

# 功能: 备份配置
backup_config() {
    if [ $CONFIG_BACKED_UP -eq 1 ]; then
        return 0
    fi
    
    local backup_dir="/tmp/config_backup"
    log "  备份配置到 $backup_dir"
    rm -rf "$backup_dir" 2>/dev/null
    mkdir -p "$backup_dir"
    cp -r /etc/config/* "$backup_dir/" 2>/dev/null && \
        log "  配置备份成功" || log "  配置备份失败"
    
    CONFIG_BACKED_UP=1
}

# 功能: 获取更新计划描述
# 输出: 更新计划的可读字符串
get_update_schedule() {
    local cron_entry=$(crontab -l 2>/dev/null | grep "auto-update.sh" | grep -v "^#" | head -n1)
    
    [ -z "$cron_entry" ] && { echo "未设置"; return; }
    
    local minute=$(echo "$cron_entry" | awk '{print $1}')
    local hour=$(echo "$cron_entry" | awk '{print $2}')
    local day=$(echo "$cron_entry" | awk '{print $3}')
    local weekday=$(echo "$cron_entry" | awk '{print $5}')
    
    local week_name=""
    case "$weekday" in
        0|7) week_name="日" ;;
        1) week_name="一" ;;
        2) week_name="二" ;;
        3) week_name="三" ;;
        4) week_name="四" ;;
        5) week_name="五" ;;
        6) week_name="六" ;;
    esac
    
    local hour_str=""
    if [ "$hour" != "*" ] && ! echo "$hour" | grep -q "/"; then
        hour_str=$(printf "%02d" "$hour")
    fi
    
    if [ "$weekday" != "*" ]; then
        if [ -n "$hour_str" ]; then
            echo "每周${week_name} ${hour_str}点"
        else
            echo "每周${week_name}"
        fi
    elif echo "$hour" | grep -q "^\*/"; then
        local h=$(echo "$hour" | sed 's/\*\///')
        echo "每${h}小时"
    elif echo "$day" | grep -q "^\*/"; then
        local d=$(echo "$day" | sed 's/\*\///')
        if [ -n "$hour_str" ]; then
            echo "每${d}天 ${hour_str}点"
        else
            echo "每${d}天"
        fi
    elif [ "$hour" != "*" ] && [ "$day" = "*" ]; then
        echo "每天${hour_str}点"
    elif [ "$hour" = "*" ] && echo "$minute" | grep -q "^\*/"; then
        local m=$(echo "$minute" | sed 's/\*\///')
        echo "每${m}分钟"
    elif [ "$hour" = "*" ] && [ "$minute" != "*" ]; then
        echo "每小时"
    else
        echo "$minute $hour $day * $weekday"
    fi
}

# 功能: 发送推送通知
# 参数: $1=标题, $2=内容
# 返回: 0=成功, 1=失败
send_push() {
    [ ! -f "/etc/config/wechatpush" ] && { log "wechatpush 未安装"; return 1; }
    [ "$(uci get wechatpush.config.enable 2>/dev/null)" != "1" ] && { log "wechatpush 未启用"; return 1; }
    
    local token=$(uci get wechatpush.config.pushplus_token 2>/dev/null)
    local api="pushplus" url="http://www.pushplus.plus/send"
    
    if [ -z "$token" ]; then
        token=$(uci get wechatpush.config.serverchan_3_key 2>/dev/null)
        api="serverchan3" url="https://sctapi.ftqq.com/${token}.send"
    fi
    
    if [ -z "$token" ]; then
        token=$(uci get wechatpush.config.serverchan_key 2>/dev/null)
        api="serverchan" url="https://sc.ftqq.com/${token}.send"
    fi
    
    [ -z "$token" ] && { log "未配置推送服务"; return 1; }
    
    log "发送推送 ($api)"
    
    local response=""
    if [ "$api" = "pushplus" ]; then
        local content=$(echo "$2" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
        response=$(curl -s -X POST "$url" -H "Content-Type: application/json" \
            -d "{\"token\":\"$token\",\"title\":\"$1\",\"content\":\"$content\",\"template\":\"txt\"}")
        echo "$response" | grep -q '"code":200' && { log "推送成功"; return 0; }
    else
        response=$(curl -s -X POST "$url" -d "text=$1" -d "desp=$2")
        echo "$response" | grep -q '"errno":0\|"code":0' && { log "推送成功"; return 0; }
    fi
    
    log "推送失败: $response"
    return 1
}

# 功能: 发送状态推送
send_status_push() {
    : > "$LOG_FILE"
    
    log "[状态推送] 开始"
    
    load_config
    
    local schedule=$(get_update_schedule)
    
    local message="自动更新已启用\n\n"
    message="${message}**脚本版本**: $SCRIPT_VERSION\n"
    message="${message}**更新计划**: $schedule\n\n"
    message="${message}---\n"
    message="${message}设备: $DEVICE_MODEL\n"
    message="${message}时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    log "推送内容:"
    log "  版本: $SCRIPT_VERSION"
    log "  计划: $schedule"
    
    send_push "$PUSH_TITLE" "$message"
    
    log "[状态推送] 完成"
}

# 功能: 分类已安装的包
classify_packages() {
    log "[步骤1] 分类已安装包"
    
    log "更新软件源"
    if ! $PKG_UPDATE >>"$LOG_FILE" 2>&1; then
        log "软件源更新失败"
        return 1
    fi
    log "软件源更新成功"
    
    OFFICIAL_PACKAGES=""
    NON_OFFICIAL_PACKAGES=""
    local excluded_count=0
    
    local pkgs=""
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        pkgs=$(opkg list-installed 2>/dev/null | awk '{print $1}' | grep -v "^luci-i18n-")
    else
        pkgs=$(apk info 2>/dev/null | grep -v "^luci-i18n-")
    fi
    
    local total=$(echo "$pkgs" | wc -l)
    
    log "检测到 $total 个已安装包（已排除语言包）"
    log "分类中..."
    
    for pkg in $pkgs; do
        if echo " $THIRD_PARTY_INSTALLED " | grep -q " $pkg "; then
            NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
        elif is_package_excluded "$pkg"; then
            excluded_count=$((excluded_count + 1))
        elif echo "$PKG_INSTALL" | grep -q "opkg"; then
            if opkg info "$pkg" 2>/dev/null | grep -q "^Description:"; then
                OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg"
            else
                NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
            fi
        else
            if apk info "$pkg" 2>/dev/null | grep -q "^origin:"; then
                OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg"
            else
                NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
            fi
        fi
    done
    
    local official_count=$(echo $OFFICIAL_PACKAGES | wc -w)
    local non_official_count=$(echo $NON_OFFICIAL_PACKAGES | wc -w)
    
    log "包分类完成:"
    log "  官方源: $official_count 个"
    log "  第三方源: $non_official_count 个"
    log "  已排除: $excluded_count 个"
    
    return 0
}

# 功能: 更新官方源的包
update_official_packages() {
    log "[步骤2] 更新官方源包"
    
    OFFICIAL_UPDATED=0
    OFFICIAL_SKIPPED=0
    OFFICIAL_FAILED=0
    UPDATED_PACKAGES=""
    FAILED_PACKAGES=""
    
    local count=$(echo $OFFICIAL_PACKAGES | wc -w)
    log "需要检查的官方源包: $count 个"
    
    for pkg in $OFFICIAL_PACKAGES; do
        local cur=$(get_package_version list-installed "$pkg")
        local new=$(get_package_version list "$pkg")
        
        if [ "$cur" != "$new" ] && [ -n "$new" ]; then
            log "升级 $pkg: $cur → $new"
            log "  正在升级..."
            
            if echo "$PKG_INSTALL" | grep -q "opkg"; then
                if opkg upgrade "$pkg" >>"$LOG_FILE" 2>&1; then
                    log "  升级成功"
                    UPDATED_PACKAGES="${UPDATED_PACKAGES}\n    - $pkg: $cur → $new"
                    OFFICIAL_UPDATED=$((OFFICIAL_UPDATED + 1))
                    install_language_package "$pkg"
                else
                    log "  升级失败"
                    FAILED_PACKAGES="${FAILED_PACKAGES}\n    - $pkg"
                    OFFICIAL_FAILED=$((OFFICIAL_FAILED + 1))
                fi
            else
                if apk upgrade "$pkg" >>"$LOG_FILE" 2>&1; then
                    log "  升级成功"
                    UPDATED_PACKAGES="${UPDATED_PACKAGES}\n    - $pkg: $cur → $new"
                    OFFICIAL_UPDATED=$((OFFICIAL_UPDATED + 1))
                else
                    log "  升级失败"
                    FAILED_PACKAGES="${FAILED_PACKAGES}\n    - $pkg"
                    OFFICIAL_FAILED=$((OFFICIAL_FAILED + 1))
                fi
            fi
        else
            log "保持最新 $pkg: $cur"
            OFFICIAL_SKIPPED=$((OFFICIAL_SKIPPED + 1))
        fi
    done
    
    log "官方源检查完成:"
    log "  升级: $OFFICIAL_UPDATED 个"
    log "  已是最新: $OFFICIAL_SKIPPED 个"
    log "  失败: $OFFICIAL_FAILED 个"
    
    return 0
}

# 功能: 更新第三方源的包
update_thirdparty_packages() {
    log "[步骤3] 更新第三方包"
    
    THIRDPARTY_UPDATED=0
    THIRDPARTY_SAME=0
    THIRDPARTY_NOTFOUND=0
    THIRDPARTY_FAILED=0
    local thirdparty_updated_list=""
    local thirdparty_notfound_list=""
    local thirdparty_failed_list=""
    
    local check_list=""
    for pkg in $NON_OFFICIAL_PACKAGES; do
        case "$pkg" in
            luci-app-*|luci-theme-*|lucky) check_list="$check_list $pkg" ;;
        esac
    done
    
    local count=$(echo $check_list | wc -w)
    [ $count -eq 0 ] && { log "没有需要检查的第三方插件"; return 0; }
    
    log "需要检查的第三方插件: $count 个"
    
    for pkg in $check_list; do
        local cur=$(get_package_version list-installed "$pkg")
        log "检查 $pkg (当前版本: $cur)"
        
        "$THIRD_PARTY_INSTALLER" update "$pkg" "$cur"
        
        case $? in
            0)
                THIRDPARTY_UPDATED=$((THIRDPARTY_UPDATED + 1))
                thirdparty_updated_list="${thirdparty_updated_list}\n    - $pkg: $cur → 最新版"
                log "  已更新"
                ;;
            2)
                THIRDPARTY_SAME=$((THIRDPARTY_SAME + 1))
                log "  已是最新版本"
                ;;
            *)
                THIRDPARTY_FAILED=$((THIRDPARTY_FAILED + 1))
                thirdparty_failed_list="${thirdparty_failed_list}\n    - $pkg"
                log "  更新失败"
                ;;
        esac
    done
    
    log "第三方源检查完成:"
    log "  已更新: $THIRDPARTY_UPDATED 个"
    log "  已是最新: $THIRDPARTY_SAME 个"
    log "  失败: $THIRDPARTY_FAILED 个"
    
    return 0
}

# 功能: 生成更新报告
# 输出: 格式化的报告文本
generate_report() {
    local updates=$((OFFICIAL_UPDATED + THIRDPARTY_UPDATED))
    local strategy="官方源优先"
    [ "$INSTALL_PRIORITY" != "1" ] && strategy="第三方源优先"
    
    local non_official_count=$(echo $NON_OFFICIAL_PACKAGES | wc -w)
    local excluded_count=0
    
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        local all_pkgs=$(opkg list-installed 2>/dev/null | awk '{print $1}')
    else
        local all_pkgs=$(apk info 2>/dev/null)
    fi
    
    for pkg in $all_pkgs; do
        is_package_excluded "$pkg" && excluded_count=$((excluded_count + 1))
    done
    
    local report="脚本版本: $SCRIPT_VERSION\n"
    report="${report}时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    report="${report}设备: $DEVICE_MODEL\n"
    report="${report}策略: $strategy\n\n"
    
    report="${report}官方源检查完成:\n"
    report="${report}  升级: $OFFICIAL_UPDATED 个\n"
    [ -n "$UPDATED_PACKAGES" ] && report="${report}$UPDATED_PACKAGES\n"
    report="${report}  已是最新: $OFFICIAL_SKIPPED 个\n"
    report="${report}  不在官方源: $non_official_count 个\n"
    report="${report}  已排除: $excluded_count 个\n"
    report="${report}  失败: $OFFICIAL_FAILED 个\n"
    [ -n "$FAILED_PACKAGES" ] && report="${report}$FAILED_PACKAGES\n"
    report="${report}\n"
    
    report="${report}第三方源检查完成:\n"
    report="${report}  已更新: $THIRDPARTY_UPDATED 个\n"
    report="${report}  已是最新: $THIRDPARTY_SAME 个\n"
    report="${report}  失败: $THIRDPARTY_FAILED 个\n"
    report="${report}\n"
    
    [ $updates -eq 0 ] && report="${report}[提示] 所有软件包均为最新版本\n\n"
    
    report="${report}详细日志: $LOG_FILE"
    
    echo "$report"
}

# 功能: 主更新流程
run_update() {
    : > "$LOG_FILE"  # 清空日志
    exec >> "$LOG_FILE" 2>&1
    log "OpenWrt 自动更新 v${SCRIPT_VERSION}"
    log "开始执行 (PID: $$)"
    log "日志文件: $LOG_FILE"
    
    load_config || return 1
    
    log "系统架构: $SYS_ARCH"
    log "包管理器: $(echo $PKG_INSTALL | awk '{print $1}')"
    log "包格式: $PKG_EXT"
    log "安装优先级: $([ "$INSTALL_PRIORITY" = "1" ] && echo "官方源优先" || echo "第三方源优先")"
    
    load_common_lib || {
        log "无法加载公共函数库，部分功能可能不可用"
    }
    
    export LOG_FILE
    export ARCH_FALLBACK
    export API_SOURCES
    export PKG_INSTALL
    export GITEE_TOKEN
    export GITCODE_TOKEN
    
    log "[步骤0] 检查脚本更新"
    if [ -x "$THIRD_PARTY_INSTALLER" ]; then
        "$THIRD_PARTY_INSTALLER" --check-script-update
        case $? in
            3)
                log "auto-update.sh 已更新，重启脚本..."
                exec "$0"
                ;;
            4)
                log "third-party-installer.sh 已更新"
                ;;
            0)
                log "脚本均为最新版本"
                ;;
            *)
                log "脚本更新检查失败"
                ;;
        esac
    else
        log "第三方安装器不存在: $THIRD_PARTY_INSTALLER"
    fi
    
    classify_packages || return 1
    
    if [ "$INSTALL_PRIORITY" = "1" ]; then
        log "[策略] 官方源优先，第三方源补充"
        update_official_packages
        update_thirdparty_packages
    else
        log "[策略] 第三方源优先，官方源补充"
        update_thirdparty_packages
        update_official_packages
    fi
    
    if [ $CONFIG_BACKED_UP -eq 1 ] && [ -d "/tmp/config_backup" ]; then
        log "配置备份信息:"
        log "  备份目录: /tmp/config_backup"
        log "  恢复命令: cp -r /tmp/config_backup/* /etc/config/"
        log "  清理命令: rm -rf /tmp/config_backup"
    fi
    
    log "[完成] 更新流程结束"
    
    local report=$(generate_report)
    log "$report"
    
    send_push "$PUSH_TITLE" "$report"
}

# 功能: 参数处理
if [ "$1" = "ts" ]; then
    send_status_push
    exit 0
fi

run_update
