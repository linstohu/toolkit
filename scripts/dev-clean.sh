#!/usr/bin/env bash
set -u

# Exit codes: 0 success, 1 environment/preflight failure, 2 invalid arguments.

DRY_RUN=0
MENU_SNAPSHOT=''
SELECTED_IDS=''
SUCCESS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
SELECTION_CANCELLED=0
CONFIRMATION_CANCELLED=0
CLEANUP_TMPDIR=''

XCODE_DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
SWIFTPM_CACHE="$HOME/Library/Caches/org.swift.swiftpm"
SWIFTPM_USER_CACHE="$HOME/.swiftpm/cache"
GRADLE_CACHE="$HOME/.gradle/caches"
VSCODE_CACHE="$HOME/Library/Application Support/Code/Cache"
VSCODE_CACHED_DATA="$HOME/Library/Application Support/Code/CachedData"
VSCODE_GPU_CACHE="$HOME/Library/Application Support/Code/GPUCache"
VSCODE_BUNDLE_CACHE="$HOME/Library/Caches/com.microsoft.VSCode"
JETBRAINS_CACHE="$HOME/Library/Caches/JetBrains"

CLEANER_IDS=()
CLEANER_LABELS=()
CLEANER_KIB=()
CLEANER_KINDS=()

home_is_safe() {
  local home="${HOME:-}"
  [ -n "$home" ] || return 1
  case "$home" in /*) ;; *) return 1 ;; esac
  [ "$home" != / ] && [ -d "$home" ] && [ ! -L "$home" ]
}

path_ancestors_are_safe() {
  local current="$1"
  local parent
  local home="${HOME:-}"
  while [ "$current" != "$home" ]; do
    [ "$current" != / ] || return 1
    [ ! -L "$current" ] || return 1
    parent="$(dirname "$current")"
    [ "$parent" != "$current" ] || break
    current="$parent"
  done
}

is_allowed_path() {
  case "$1" in
    "$XCODE_DERIVED"|"$SWIFTPM_CACHE"|"$SWIFTPM_USER_CACHE"|"$GRADLE_CACHE"|\
    "$VSCODE_CACHE"|"$VSCODE_CACHED_DATA"|"$VSCODE_GPU_CACHE"|\
    "$VSCODE_BUNDLE_CACHE"|"$JETBRAINS_CACHE") : ;;
    *) return 1 ;;
  esac
  home_is_safe || return 1
}

path_kib() {
  local path="$1"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf '0\n'
    return 0
  fi
  du -sk "$path" 2>/dev/null | awk 'NR == 1 { print $1; found = 1 } END { if (!found) print 0 }'
}

format_kib() {
  awk -v kib="$1" 'BEGIN {
    if (kib < 1) printf "0 B\n";
    else if (kib < 1024) printf "%d KiB\n", kib;
    else if (kib < 1048576) printf "%.1f MiB\n", kib / 1024;
    else printf "%.1f GiB\n", kib / 1048576;
  }'
}

clear_path() {
  local path="$1"
  local mode="$2"
  is_allowed_path "$path" || return 1
  path_ancestors_are_safe "$(dirname "$path")" || return 1
  if [ "$mode" = preview ]; then
    printf '%s\n' "$path"
    return 0
  fi
  [ "$mode" = apply ] || return 2
  if [ -L "$path" ]; then
    rm -f -- "$path"
  elif [ -d "$path" ]; then
    find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  elif [ -e "$path" ]; then
    return 1
  fi
}

register_cleaner() {
  CLEANER_IDS+=("$1")
  CLEANER_LABELS+=("$2")
  CLEANER_KIB+=("$3")
  CLEANER_KINDS+=("$4")
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

register_path_cleaner() {
  local id="$1"
  local label="$2"
  local path
  local kib=0
  local found=0
  shift 2

  for path in "$@"; do
    if path_exists "$path"; then
      kib=$((kib + $(path_kib "$path")))
      found=1
    fi
  done
  [ "$found" -eq 1 ] || return 0
  register_cleaner "$id" "$label" "$kib" path
}

docker_is_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

pip_is_available() {
  command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1
}

yarn_generation() {
  local version
  local major

  command -v yarn >/dev/null 2>&1 || return 1
  version="$(yarn --version 2>/dev/null)" || return 1
  case "$version" in *.*) : ;; *) return 1 ;; esac
  major=${version%%.*}
  case "$major" in ''|*[!0-9]*) return 1 ;; esac

  if [ "$major" -eq 1 ]; then
    printf 'classic\n'
  elif [ "$major" -ge 2 ]; then
    printf 'modern\n'
  else
    return 1
  fi
}

has_unavailable_simulator() {
  local devices
  command -v xcrun >/dev/null 2>&1 || return 1
  devices="$(xcrun simctl list devices unavailable 2>/dev/null)" || return 1
  printf '%s\n' "$devices" | grep -Eq '^[[:space:]]+[^[:space:]].*\([^)]*\)[[:space:]]+\([^)]*unavailable'
}

register_cleaners() {
  CLEANER_IDS=()
  CLEANER_LABELS=()
  CLEANER_KIB=()
  CLEANER_KINDS=()

  register_path_cleaner xcode-derived 'Xcode DerivedData' "$XCODE_DERIVED"
  register_path_cleaner swiftpm 'SwiftPM 缓存' "$SWIFTPM_CACHE" "$SWIFTPM_USER_CACHE"
  register_path_cleaner gradle 'Gradle 缓存' "$GRADLE_CACHE"
  register_path_cleaner vscode 'VS Code 缓存' "$VSCODE_CACHE" "$VSCODE_CACHED_DATA" "$VSCODE_GPU_CACHE" "$VSCODE_BUNDLE_CACHE"
  register_path_cleaner jetbrains 'JetBrains 缓存' "$JETBRAINS_CACHE"

  has_unavailable_simulator && register_cleaner simulator 'iOS Simulator 不可用设备' dynamic native
  command -v brew >/dev/null 2>&1 && register_cleaner brew 'Homebrew 缓存' dynamic native
  command -v npm >/dev/null 2>&1 && register_cleaner npm 'npm 缓存' dynamic native
  command -v pnpm >/dev/null 2>&1 && register_cleaner pnpm 'pnpm Store' dynamic native
  yarn_generation >/dev/null && register_cleaner yarn 'Yarn 缓存' dynamic native
  pip_is_available && register_cleaner pip 'pip 缓存' dynamic native
  command -v uv >/dev/null 2>&1 && register_cleaner uv 'uv 缓存' dynamic native
  command -v pod >/dev/null 2>&1 && register_cleaner cocoapods 'CocoaPods 缓存' dynamic native
  command -v go >/dev/null 2>&1 && register_cleaner go 'Go 构建缓存' dynamic native
  if docker_is_available; then
    register_cleaner docker-build 'Docker 构建缓存' dynamic native
    register_cleaner docker-images 'Docker 未使用镜像' dynamic native
    register_cleaner docker-containers 'Docker 已停止容器' dynamic native
  fi
}

register_cleaners_and_print_ids() {
  local index=0
  register_cleaners
  while [ "$index" -lt "${#CLEANER_IDS[@]}" ]; do
    printf '%s\n' "${CLEANER_IDS[$index]}"
    index=$((index + 1))
  done
}

preview_command() {
  printf '[预览]'
  printf ' %s' "$@"
  printf '\n'
}

clear_existing_path() {
  path_exists "$1" || return 0
  clear_path "$1" "$2"
}

run_path_cleaner() {
  local id="$1"
  local mode="$2"
  case "$id" in
    xcode-derived) clear_existing_path "$XCODE_DERIVED" "$mode" ;;
    swiftpm)
      clear_existing_path "$SWIFTPM_CACHE" "$mode" || return $?
      clear_existing_path "$SWIFTPM_USER_CACHE" "$mode"
      ;;
    gradle) clear_existing_path "$GRADLE_CACHE" "$mode" ;;
    vscode)
      clear_existing_path "$VSCODE_CACHE" "$mode" || return $?
      clear_existing_path "$VSCODE_CACHED_DATA" "$mode" || return $?
      clear_existing_path "$VSCODE_GPU_CACHE" "$mode" || return $?
      clear_existing_path "$VSCODE_BUNDLE_CACHE" "$mode"
      ;;
    jetbrains) clear_existing_path "$JETBRAINS_CACHE" "$mode" ;;
    *) return 2 ;;
  esac
}

run_cleaner() {
  local id="$1"
  local mode="${2:-}"
  local generation
  [ -n "$mode" ] || {
    if [ "$DRY_RUN" -eq 1 ]; then mode=preview; else mode=apply; fi
  }
  [ "$DRY_RUN" -eq 0 ] || mode=preview
  [ "$mode" = preview ] || [ "$mode" = apply ] || return 2

  case "$id" in
    xcode-derived|swiftpm|gradle|vscode|jetbrains)
      run_path_cleaner "$id" "$mode"
      ;;
    simulator)
      if [ "$mode" = preview ]; then preview_command xcrun simctl delete unavailable; else xcrun simctl delete unavailable; fi
      ;;
    brew)
      if [ "$mode" = preview ]; then brew cleanup -n; else brew cleanup; fi
      ;;
    npm)
      if [ "$mode" = preview ]; then preview_command npm cache clean --force; else npm cache clean --force; fi
      ;;
    pnpm)
      if [ "$mode" = preview ]; then preview_command pnpm store prune; else pnpm store prune; fi
      ;;
    yarn)
      generation="$(yarn_generation)" || return 1
      if [ "$generation" = classic ]; then
        if [ "$mode" = preview ]; then preview_command yarn cache clean; else yarn cache clean; fi
      else
        if [ "$mode" = preview ]; then preview_command yarn cache clean --mirror; else yarn cache clean --mirror; fi
      fi
      ;;
    pip)
      if [ "$mode" = preview ]; then preview_command python3 -m pip cache purge; else python3 -m pip cache purge; fi
      ;;
    uv)
      if [ "$mode" = preview ]; then preview_command uv cache clean; else uv cache clean; fi
      ;;
    cocoapods)
      if [ "$mode" = preview ]; then preview_command pod cache clean --all; else pod cache clean --all; fi
      ;;
    go)
      if [ "$mode" = preview ]; then preview_command go clean -cache -testcache; else go clean -cache -testcache; fi
      ;;
    docker-build)
      if [ "$mode" = preview ]; then preview_command docker builder prune -f; else docker builder prune -f; fi
      ;;
    docker-images)
      if [ "$mode" = preview ]; then preview_command docker image prune -f; else docker image prune -f; fi
      ;;
    docker-containers)
      if [ "$mode" = preview ]; then preview_command docker container prune -f; else docker container prune -f; fi
      ;;
    *) return 2 ;;
  esac
}

build_menu() {
  local index=0
  local size
  register_cleaners
  while [ "$index" -lt "${#CLEANER_IDS[@]}" ]; do
    if [ "${CLEANER_KINDS[$index]}" = path ]; then
      size="$(format_kib "${CLEANER_KIB[$index]}")"
    else
      size='动态计算'
    fi
    printf '%s\t%s\t%s\n' "${CLEANER_IDS[$index]}" "${CLEANER_LABELS[$index]}" "$size"
    index=$((index + 1))
  done
}

selected_path_kib() {
  local total=0
  local id
  local path

  while IFS= read -r id || [ -n "$id" ]; do
    case "$id" in
      xcode-derived) total=$((total + $(path_kib "$XCODE_DERIVED"))) ;;
      swiftpm)
        for path in "$SWIFTPM_CACHE" "$SWIFTPM_USER_CACHE"; do
          total=$((total + $(path_kib "$path")))
        done
        ;;
      gradle) total=$((total + $(path_kib "$GRADLE_CACHE"))) ;;
      vscode)
        for path in "$VSCODE_CACHE" "$VSCODE_CACHED_DATA" "$VSCODE_GPU_CACHE" "$VSCODE_BUNDLE_CACHE"; do
          total=$((total + $(path_kib "$path")))
        done
        ;;
      jetbrains) total=$((total + $(path_kib "$JETBRAINS_CACHE"))) ;;
    esac
  done <<EOF
$SELECTED_IDS
EOF
  printf '%s\n' "$total"
}

cleaner_label() {
  local id="$1"
  local row
  local row_id
  local label_and_size
  local label
  local tab

  tab="$(printf '\t')"
  while IFS= read -r row || [ -n "$row" ]; do
    row_id=${row%%"$tab"*}
    if [ "$row_id" = "$id" ]; then
      label_and_size=${row#*"$tab"}
      label=${label_and_size%%"$tab"*}
      printf '%s\n' "$label"
      return 0
    fi
  done <<EOF
$MENU_SNAPSHOT
EOF
  return 1
}

choose_cleaners() {
  local selected_rows
  local status
  local tab

  SELECTION_CANCELLED=0
  MENU_SNAPSHOT="$(build_menu)" || return $?
  selected_rows="$(printf '%s\n' "$MENU_SNAPSHOT" | gum choose --no-limit --header '选择要清理的开发缓存')"
  status=$?
  if [ "$status" -eq 130 ] || [ -z "$selected_rows" ]; then
    SELECTED_IDS=''
    SELECTION_CANCELLED=1
    return 0
  fi
  [ "$status" -eq 0 ] || return "$status"

  tab="$(printf '\t')"
  SELECTED_IDS="$(printf '%s\n' "$selected_rows" | awk -F "$tab" 'NF { print $1 }')"
}

print_selection() {
  local id
  local label
  local total

  total="$(selected_path_kib)"
  printf '已选择清理项：\n'
  while IFS= read -r id || [ -n "$id" ]; do
    label="$(cleaner_label "$id")" || return 1
    printf '%s\n' "- $label"
  done <<EOF
$SELECTED_IDS
EOF
  printf '已知总计: %s\n' "$(format_kib "$total")"
}

remove_docker_cleaners() {
  local remaining=''
  local id
  local docker_count=0

  while IFS= read -r id || [ -n "$id" ]; do
    case "$id" in
      docker-build|docker-images|docker-containers) docker_count=$((docker_count + 1)) ;;
      *)
        if [ -n "$remaining" ]; then remaining="$remaining
"; fi
        remaining="${remaining}${id}"
        ;;
    esac
  done <<EOF
$SELECTED_IDS
EOF
  SELECTED_IDS="$remaining"
  SKIP_COUNT=$((SKIP_COUNT + docker_count))
  printf '已跳过 Docker 清理项: %s\n' "$docker_count"
}

selected_docker_count() {
  local id
  local count=0
  while IFS= read -r id || [ -n "$id" ]; do
    case "$id" in docker-build|docker-images|docker-containers) count=$((count + 1)) ;; esac
  done <<EOF
$SELECTED_IDS
EOF
  printf '%s\n' "$count"
}

confirm_selection() {
  local docker_count

  CONFIRMATION_CANCELLED=0
  if ! gum confirm '执行以上清理？'; then
    CONFIRMATION_CANCELLED=1
    return 0
  fi

  docker_count="$(selected_docker_count)"
  if [ "$docker_count" -gt 0 ] && ! gum confirm 'Docker 清理会永久删除已停止容器、悬空镜像或构建缓存，继续？'; then
    remove_docker_cleaners
  fi
}

execute_selected() {
  local id
  local mode=apply
  local stderr_file
  local status
  local label
  local stderr_summary

  [ -n "$SELECTED_IDS" ] || return 0
  [ "$DRY_RUN" -eq 0 ] || mode=preview
  while IFS= read -r id || [ -n "$id" ]; do
    stderr_file="$CLEANUP_TMPDIR/$id.stderr"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '[预览] %s\n' "$(cleaner_label "$id")"
    fi
    run_cleaner "$id" "$mode" 2>"$stderr_file"
    status=$?
    if [ "$status" -eq 0 ]; then
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      label="$(cleaner_label "$id" 2>/dev/null)" || label="$id"
      stderr_summary=''
      if [ -s "$stderr_file" ]; then
        stderr_summary="$(awk 'NF { print; exit }' "$stderr_file")"
      fi
      if [ -n "$stderr_summary" ]; then
        printf '失败: %s (%s)，退出码 %s；错误: %s\n' "$label" "$id" "$status" "$stderr_summary" >&2
      else
        printf '失败: %s (%s)，退出码 %s\n' "$label" "$id" "$status" >&2
      fi
    fi
  done <<EOF
$SELECTED_IDS
EOF
}

print_summary() {
  local before_kib="$1"
  local after_kib="$2"
  local released_kib=$((before_kib - after_kib))

  [ "$released_kib" -ge 0 ] || released_kib=0
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '预览完成\n'
    return 0
  fi
  printf '清理完成\n'
  printf '成功: %s  跳过: %s  失败: %s\n' "$SUCCESS_COUNT" "$SKIP_COUNT" "$FAIL_COUNT"
  printf '可确认释放: %s\n' "$(format_kib "$released_kib")"
}

remove_cleanup_tmpdir() {
  if [ -n "${CLEANUP_TMPDIR:-}" ] && [ -d "$CLEANUP_TMPDIR" ]; then
    rm -f -- "$CLEANUP_TMPDIR"/*.stderr 2>/dev/null || :
    rmdir -- "$CLEANUP_TMPDIR" 2>/dev/null || :
  fi
}

print_usage() {
  cat <<'USAGE'
用法: dev-clean.sh [--dry-run] [--help]

面向 macOS 开发者的交互式缓存清理工具。
  -n, --dry-run  预览候选操作，不删除任何内容
  -h, --help     显示帮助
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=1 ;;
      -h|--help) print_usage; return 10 ;;
      *) printf '错误: 未知选项 %s\n' "$1" >&2; return 2 ;;
    esac
    shift
  done
  return 0
}

preflight() {
  if [ "$(uname -s)" != "Darwin" ]; then
    printf '错误: dev-clean 仅支持 macOS。\n' >&2
    return 1
  fi
  if ! command -v gum >/dev/null 2>&1; then
    printf '错误: 缺少 gum。请先运行: brew install gum\n' >&2
    return 1
  fi
}

main() {
  local before_kib
  local after_kib
  parse_args "$@"; status=$?
  [ "$status" -eq 10 ] && return 0
  [ "$status" -ne 0 ] && return "$status"
  preflight || return 1

  choose_cleaners || return $?
  if [ "$SELECTION_CANCELLED" -eq 1 ]; then
    printf '未选择清理项，已取消。\n'
    return 0
  fi

  print_selection || return 1
  if [ "$DRY_RUN" -eq 0 ]; then
    confirm_selection || return $?
    if [ "$CONFIRMATION_CANCELLED" -eq 1 ]; then
      printf '已取消清理。\n'
      return 0
    fi
  fi

  before_kib="$(selected_path_kib)"
  CLEANUP_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/dev-clean.XXXXXX")" || return 1
  trap remove_cleanup_tmpdir EXIT
  execute_selected
  after_kib="$(selected_path_kib)"
  print_summary "$before_kib" "$after_kib"
  [ "$FAIL_COUNT" -eq 0 ] || return 1
}

if [ "${DEV_CLEAN_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
