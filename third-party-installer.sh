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

# 功能: 日志输出
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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

# 功能: 检查脚本更新
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

# 功能: 智能筛选相关文件
filter_related_files() {
    local all_files="$1"
    local package_name="$2"
    
    local app_name="${package_name#luci-app-}"
    app_name="${app_name#luci-theme-}"
    
    local matched_files=""
    local old_IFS="$IFS"
    IFS=$'\n'
    
    for filename in $all_files; do
        [ -z "$filename" ] && continue
        
        local should_include=0
        
        if echo "$filename" | grep -qiE "^${package_name}[_\.-]"; then
            should_include=1
            log "      [主程序] $filename"
        elif echo "$filename" | grep -qiE "^luci-i18n-${app_name}.*zh-cn"; then
            should_include=1
            log "      [语言包] $filename"
        elif echo "$filename" | grep -qiE "^${app_name}[_\.-]"; then
            if ! echo "$filename" | grep -qi "i18n"; then
                should_include=1
                log "      [架构包] $filename"
            fi
        fi
        
        if [ $should_include -eq 1 ]; then
            matched_files="${matched_files}${filename}\n"
        fi
    done
    
    IFS="$old_IFS"
    
    echo -e "$matched_files" | grep -v "^$"
}

# 功能: 批量安装包文件
install_package_batch() {
    local pkg_files="$1"
    
    log "  [批量安装] 开始"
    
    local arch_pkgs=""
    local main_pkgs=""
    local lang_pkgs=""
    local all_pkgs=""
    
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
            arch_pkgs="${arch_pkgs}${pkg_file}\n"
        fi
    done
    
    IFS="$old_IFS"
    
    local batches="
1|架构依赖包|$arch_pkgs
2|主程序|$main_pkgs
3|语言包|$lang_pkgs
4|通用包|$all_pkgs
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
            
            # 直接调用，输出自动进入父进程日志
            if $PKG_INSTALL "$pkg_file"; then
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

# 功能: 安装或更新第三方包
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
            all_files=$(echo "$files_json" | jsonfilter -e '@[@.type="file"].name' 2>/dev/null | \
                grep "${PKG_EXT}$")
        else
            all_files=$(extract_files_from_json "$files_json" "$PKG_EXT")
        fi
        
        if [ -z "$all_files" ]; then
            log "    未找到 ${PKG_EXT} 文件"
            continue
        fi
        
        log "    可用文件 (共 $(echo "$all_files" | wc -l) 个):"
        echo "$all_files" | while read f; do log "      $f"; done
        
        log "    筛选相关文件:"
        local matched_files=$(filter_related_files "$all_files" "$package_name")
        
        if [ -z "$matched_files" ]; then
            log "    未找到匹配文件"
            continue
        fi
        
        log "    匹配结果 (共 $(echo "$matched_files" | wc -l) 个):"
        echo "$matched_files" | while read f; do log "      $f"; done
        
        log "    开始下载..."
        local temp_dir="/tmp/third_party_${package_name}_$$"
        mkdir -p "$temp_dir"
        
        local download_failed=0
        local downloaded_files=""
        
        local old_IFS="$IFS"
        IFS=$'\n'
        
        for filename in $matched_files; do
            [ -z "$filename" ] && continue
            
            local download_url=$(extract_download_url_from_json "$files_json" "$filename")
            
            if [ -z "$download_url" ]; then
                log "      未找到下载链接: $filename"
                download_failed=1
                break
            fi
            
            local temp_file="${temp_dir}/${filename}"
            
            log "      下载: $filename"
            
            if ! curl -fsSL -o "$temp_file" -H "User-Agent: Mozilla/5.0" "$download_url" 2>/dev/null; then
                log "      下载失败"
                download_failed=1
                break
            fi
            
            if ! validate_downloaded_file "$temp_file" 1024; then
                log "      文件验证失败"
                download_failed=1
                break
            fi
            
            downloaded_files="${downloaded_files}${temp_file}\n"
        done
        
        IFS="$old_IFS"
        
        if [ $download_failed -eq 1 ]; then
            rm -rf "$temp_dir"
            log "    下载失败，尝试下一个源..."
            continue
        fi
        
        log "    所有文件下载完成"
        log "    开始安装..."
        
        if install_package_batch "$(echo -e "$downloaded_files")"; then
            rm -rf "$temp_dir"
            log "  [成功] $package_name"
            log "    版本: $latest_version"
            log "    来源: $platform"
            log "    文件数: $(echo "$matched_files" | wc -l) 个"
            return 0
        else
            rm -rf "$temp_dir"
            log "    安装失败，尝试下一个源..."
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
  $0 install luci-app-openclash
  $0 update luci-app-openclash v1.2.3
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
