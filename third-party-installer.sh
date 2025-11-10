#!/bin/sh

SCRIPT_VERSION="1.0.0"

# 缓存配置
CACHE_FILE="/tmp/third-party-repo.cache"
CACHE_TTL=3600

# 需要初始化为空的变量列表
EMPTY_VARS="SYS_ARCH PKG_EXT PKG_INSTALL ARCH_FALLBACK API_SOURCES GITEE_TOKEN GITCODE_TOKEN"

# 批量初始化变量
for var in $EMPTY_VARS; do
    eval "$var=''"
done

# 功能: 日志输出（优先使用父进程的LOG_FILE）
# 参数: $1=消息内容
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    
    if [ -n "$LOG_FILE" ]; then
        echo "$msg" >> "$LOG_FILE"
    fi
    
    logger -t "third-party-installer" "$1" 2>/dev/null || true
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
    
    local missing=""
    [ -z "$ARCH_FALLBACK" ] && missing="$missing ARCH_FALLBACK"
    [ -z "$PKG_INSTALL" ] && missing="$missing PKG_INSTALL"
    [ -z "$API_SOURCES" ] && missing="$missing API_SOURCES"
    
    if [ -n "$missing" ]; then
        log "配置项缺失:$missing"
        return 1
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
    return 0
}

# 功能: 获取仓库元数据（带缓存）
# 参数: $1=是否强制刷新(0/1，默认0)
# 输出: JSON元数据
# 返回: 0=成功, 1=失败
get_repo_metadata() {
    local force_refresh="${1:-0}"
    
    if [ $force_refresh -eq 0 ] && [ -f "$CACHE_FILE" ]; then
        local cache_age=$(( $(date +%s) - $(stat -c%Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
        
        if [ $cache_age -lt $CACHE_TTL ]; then
            log "  使用缓存数据（${cache_age}秒前）"
            grep -v "^<!--" "$CACHE_FILE" | grep -v "^$"
            return 0
        fi
    fi
    
    log "  查询仓库元数据..."
    
    local metadata=""
    for source_config in $API_SOURCES; do
        local platform=$(echo "$source_config" | cut -d'|' -f1)
        local repo=$(echo "$source_config" | cut -d'|' -f2)
        local branch=$(echo "$source_config" | cut -d'|' -f3)
        
        log "    尝试: $platform ($repo)"
        
        metadata=$(api_get_contents "$platform" "$repo" "" "$branch")
        
        if [ $? -eq 0 ] && [ -n "$metadata" ]; then
            log "    获取成功"
            
            echo "$metadata" > "$CACHE_FILE"
            echo "" >> "$CACHE_FILE"
            echo "<!-- Cached: $(date '+%Y-%m-%d %H:%M:%S') -->" >> "$CACHE_FILE"
            echo "<!-- Platform: $platform -->" >> "$CACHE_FILE"
            echo "<!-- Repository: $repo -->" >> "$CACHE_FILE"
            
            echo "$metadata"
            return 0
        fi
    done
    
    log "  所有源均失败"
    return 1
}

# 功能: 检查单个脚本的更新
# 参数: $1=元数据JSON, $2=脚本文件名, $3=本地路径
# 返回: 0=已更新, 1=无需更新或失败
check_single_script() {
    local metadata="$1"
    local script_name="$2"
    local local_path="$3"
    
    log "  检查 $script_name"
    
    local download_url=$(extract_download_url_from_json "$metadata" "$script_name")
    [ -z "$download_url" ] && {
        log "    未找到下载链接"
        return 1
    }
    
    log "    获取远程版本..."
    local remote_ver=$(curl -fsSL "$download_url" 2>/dev/null | head -20 | \
        grep -o 'SCRIPT_VERSION="[^"]*"' | head -1 | cut -d'"' -f2)
    
    local local_ver=$(grep -o 'SCRIPT_VERSION="[^"]*"' "$local_path" 2>/dev/null | head -1 | cut -d'"' -f2)
    
    log "    本地: ${local_ver:-未安装}, 远程: $remote_ver"
    
    [ "$local_ver" = "$remote_ver" ] && {
        log "    无需更新"
        return 1
    }
    
    log "    下载新版本..."
    local temp="/tmp/${script_name}.new"
    
    curl -fsSL -o "$temp" "$download_url" 2>/dev/null || {
        log "    下载失败"
        return 1
    }
    
    validate_downloaded_file "$temp" 1024 || {
        rm -f "$temp"
        return 1
    }
    
    mv "$temp" "$local_path" && chmod +x "$local_path"
    log "    更新完成: $local_ver → $remote_ver"
    return 0
}

# 功能: 检查脚本更新（auto-update.sh 和自身）
# 返回: 0=无更新, 3=updater已更新, 4=installer已更新, 1=失败
check_scripts_update() {
    log "[检查] 脚本更新"
    
    local metadata=$(get_repo_metadata)
    [ $? -ne 0 ] && return 1
    
    local updater_updated=0
    local installer_updated=0
    
    if check_single_script "$metadata" "auto-update.sh" "/usr/bin/auto-update.sh"; then
        updater_updated=1
    fi
    
    if check_single_script "$metadata" "third-party-installer.sh" "/usr/bin/third-party-installer.sh"; then
        installer_updated=1
    fi
    
    [ $updater_updated -eq 1 ] && return 3
    [ $installer_updated -eq 1 ] && return 4
    return 0
}

# 功能: 检测包文件类型
# 参数: $1=文件名
# 输出: 类型字符串
detect_package_type() {
    local filename="$1"
    
    case "$filename" in
        *.tar.gz|*.tgz)
            if echo "$filename" | grep -qi "openwrt"; then
                echo "tarball_ipk"
            elif echo "$filename" | grep -qi "SNAPSHOT"; then
                echo "tarball_apk"
            else
                echo "tarball_unknown"
            fi
            ;;
        *.ipk) echo "ipk" ;;
        *.apk) echo "apk" ;;
        *) echo "unknown" ;;
    esac
}

# 功能: 批量安装包文件
# 参数: $1=包文件路径列表（换行分隔）
# 返回: 0=全部成功, 1=有失败
install_package_batch() {
    local pkg_files="$1"
    
    log "  [批量安装] 开始"
    
    local arch_pkgs=""
    local main_pkgs=""
    local lang_pkgs=""
    local all_pkgs=""
    local other_pkgs=""
    
    local old_IFS="$IFS"
    IFS=$'\n'
    
    for pkg_file in $pkg_files; do
        [ -z "$pkg_file" ] || [ ! -f "$pkg_file" ] && continue
        
        local filename=$(basename "$pkg_file")
        local size=$(stat -c%s "$pkg_file" 2>/dev/null || echo 0)
        
        if echo "$filename" | grep -qiE "luci-i18n.*zh-cn"; then
            lang_pkgs="${lang_pkgs}${pkg_file}\n"
        elif echo "$filename" | grep -qiE "^luci-(app|theme)-"; then
            main_pkgs="${main_pkgs}${pkg_file}\n"
        elif echo "$filename" | grep -qiE "[_-](all|noarch)\."; then
            all_pkgs="${all_pkgs}${pkg_file}\n"
        elif [ "$size" -gt 5242880 ]; then
            arch_pkgs="${arch_pkgs}${pkg_file}\n"
        else
            other_pkgs="${other_pkgs}${pkg_file}\n"
        fi
    done
    
    IFS="$old_IFS"
    
    local batches="
1|架构依赖包|$arch_pkgs
2|其他依赖|$other_pkgs
3|主程序|$main_pkgs
4|语言包|$lang_pkgs
5|通用包|$all_pkgs
"
    
    local total_ok=0 total_fail=0 total_skip=0
    
    echo "$batches" | while IFS='|' read batch_num batch_name batch_files; do
        [ -z "$batch_num" ] && continue
        [ -z "$batch_files" ] || [ "$batch_files" = "\n" ] && continue
        
        log "  [批次$batch_num] $batch_name"
        
        local old_IFS="$IFS"
        IFS=$'\n'
        
        for pkg_file in $(echo -e "$batch_files"); do
            [ -z "$pkg_file" ] || [ ! -f "$pkg_file" ] && continue
            
            local pkg_name=$(basename "$pkg_file" | sed 's/_.*\.\(ipk\|apk\)$//')
            
            if is_installed "$pkg_name"; then
                log "    跳过已安装: $pkg_name"
                total_skip=$((total_skip + 1))
                continue
            fi
            
            log "    安装: $pkg_name"
            
            if $PKG_INSTALL "$pkg_file" >>"${LOG_FILE:-/dev/null}" 2>&1; then
                log "    成功"
                total_ok=$((total_ok + 1))
            else
                log "    失败"
                total_fail=$((total_fail + 1))
            fi
        done
        
        IFS="$old_IFS"
    done
    
    log "  [批量安装] 完成: 成功${total_ok}个 失败${total_fail}个 跳过${total_skip}个"
    
    [ $total_fail -eq 0 ] && return 0 || return 1
}

# 功能: 解压并安装tar.gz压缩包
# 参数: $1=压缩包路径
# 返回: 0=成功, 1=失败
extract_and_install_tarball() {
    local tarball="$1"
    local temp_dir="/tmp/pkg_extract_$$"
    
    log "  [压缩包] 解压: $(basename "$tarball")"
    
    mkdir -p "$temp_dir"
    
    if ! tar -xzf "$tarball" -C "$temp_dir" 2>/dev/null; then
        log "  解压失败"
        rm -rf "$temp_dir"
        return 1
    fi
    
    local packages=$(find "$temp_dir" -type f \( -name "*.ipk" -o -name "*.apk" \) 2>/dev/null)
    
    if [ -z "$packages" ]; then
        log "  未找到安装包"
        rm -rf "$temp_dir"
        return 1
    fi
    
    local count=$(echo "$packages" | wc -l)
    log "  找到 $count 个安装包"
    
    install_package_batch "$packages"
    local ret=$?
    
    rm -rf "$temp_dir"
    return $ret
}

# 功能: 安装或更新第三方包
# 参数: $1=包名, $2=模式(install/update), $3=当前版本(仅update模式)
# 返回: 0=成功, 2=已是最新, 1=失败
install_third_party_package() {
    local package_name="$1"
    local mode="${2:-install}"
    local current_version="${3:-unknown}"
    
    log "[$([ "$mode" = "update" ] && echo "更新" || echo "安装")] $package_name"
    [ "$mode" = "update" ] && log "  当前版本: $current_version"
    
    local metadata=$(get_repo_metadata)
    
    if [ -z "$metadata" ]; then
        log "  无法获取仓库信息"
        return 1
    fi
    
    local package_dirs=""
    if which jsonfilter >/dev/null 2>&1; then
        package_dirs=$(echo "$metadata" | jsonfilter -e '@[@.type="dir"].name' 2>/dev/null)
    else
        package_dirs=$(extract_dirs_from_json "$metadata")
    fi
    
    if ! echo "$package_dirs" | grep -q "^${package_name}$"; then
        log "  仓库中不存在该包: $package_name"
        return 1
    fi
    
    log "  包目录存在，查询版本..."
    
    for source_config in $API_SOURCES; do
        local platform=$(echo "$source_config" | cut -d'|' -f1)
        local repo=$(echo "$source_config" | cut -d'|' -f2)
        local branch=$(echo "$source_config" | cut -d'|' -f3)
        
        log "  [源] $platform"
        
        local versions_json=$(api_get_contents "$platform" "$repo" "$package_name" "$branch")
        
        if [ -z "$versions_json" ]; then
            log "    查询失败"
            continue
        fi
        
        local versions=""
        if which jsonfilter >/dev/null 2>&1; then
            versions=$(echo "$versions_json" | jsonfilter -e '@[@.type="dir"].name' 2>/dev/null | \
                grep -E '^(v?[0-9]+\.|v[0-9])' | sort -Vr)
        else
            versions=$(extract_dirs_from_json "$versions_json" | grep '^v' | sort -Vr)
        fi
        
        if [ -z "$versions" ]; then
            log "    未找到版本"
            continue
        fi
        
        local latest_version=$(echo "$versions" | head -1)
        log "    最新版本: $latest_version"
        
        if [ "$mode" = "update" ]; then
            local cur_norm=$(normalize_version "$current_version")
            local new_norm=$(normalize_version "$latest_version")
            
            if [ "$cur_norm" = "$new_norm" ]; then
                log "    版本相同，无需更新"
                return 2
            fi
        fi
        
        local files_json=$(api_get_contents "$platform" "$repo" "$package_name/$latest_version" "$branch")
        
        if [ -z "$files_json" ]; then
            log "    无法获取文件列表"
            continue
        fi
        
        local all_files=""
        if which jsonfilter >/dev/null 2>&1; then
            all_files=$(echo "$files_json" | jsonfilter -e '@[@.type="file"].name' 2>/dev/null)
        else
            all_files=$(extract_files_from_json "$files_json" "$PKG_EXT")
            if [ -z "$all_files" ]; then
                all_files=$(extract_files_from_json "$files_json" ".tar.gz")
            fi
        fi
        
        if [ -z "$all_files" ]; then
            log "    未找到可用文件"
            continue
        fi
        
        log "    可用文件:"
        echo "$all_files" | while read f; do log "      $f"; done
        
        local matched_file=$(find_best_match "$all_files" "$package_name")
        
        if [ -z "$matched_file" ]; then
            log "    未找到匹配文件"
            continue
        fi
        
        local download_url=$(extract_download_url_from_json "$files_json" "$matched_file")
        
        if [ -z "$download_url" ]; then
            log "    无法获取下载链接"
            continue
        fi
        
        log "    下载: $matched_file"
        
        local temp_file="/tmp/third_party_${matched_file}"
        
        if ! curl -fsSL -o "$temp_file" -H "User-Agent: Mozilla/5.0" "$download_url" 2>/dev/null; then
            log "    下载失败"
            rm -f "$temp_file"
            continue
        fi
        
        if ! validate_downloaded_file "$temp_file" 1024; then
            log "    文件验证失败"
            rm -f "$temp_file"
            continue
        fi
        
        local pkg_type=$(detect_package_type "$matched_file")
        
        log "    开始安装 (类型: $pkg_type)"
        
        case "$pkg_type" in
            tarball_*)
                extract_and_install_tarball "$temp_file"
                ;;
            ipk|apk)
                install_package_batch "$temp_file"
                ;;
            *)
                log "    未知文件类型"
                rm -f "$temp_file"
                continue
                ;;
        esac
        
        local ret=$?
        rm -f "$temp_file"
        
        if [ $ret -eq 0 ]; then
            log "  [成功] $package_name"
            log "    版本: $latest_version"
            log "    来源: $platform"
            return 0
        fi
    done
    
    log "  [失败] 所有源均失败"
    return 1
}

# 功能: 显示使用说明
usage() {
    cat <<EOF
第三方软件包安装器 v${SCRIPT_VERSION}

用法: $0 <模式> [参数...]

模式:
  install <包名>              - 安装指定包
  update <包名> <当前版本>    - 更新指定包
  --check-script-update       - 检查脚本更新

示例:
  # 首次安装
  $0 install luci-app-passwall

  # 检查更新
  $0 update luci-app-passwall v1.2.3

  # 检查脚本更新
  $0 --check-script-update

返回码:
  0  - 成功
  1  - 失败
  2  - 已是最新版本（仅更新模式）
  3  - auto-update.sh 已更新（仅检查脚本更新模式）
  4  - installer 自身已更新（仅检查脚本更新模式）
EOF
}

# 功能: 主入口
main() {
    if [ $# -lt 1 ]; then
        usage
        return 1
    fi
    
    load_config || return 1
    load_common_lib || {
        log "无法加载公共函数库，部分功能可能不可用"
    }
    
    case "$1" in
        --check-script-update)
            check_scripts_update
            ;;
        update)
            if [ $# -lt 3 ]; then
                log "错误: update 模式需要包名和当前版本"
                usage
                return 1
            fi
            install_third_party_package "$2" "update" "$3"
            ;;
        install)
            if [ $# -lt 2 ]; then
                log "错误: install 模式需要包名"
                usage
                return 1
            fi
            install_third_party_package "$2" "install"
            ;;
        *)
            log "错误: 未知模式: $1"
            usage
            return 1
            ;;
    esac
}

main "$@"
