#!/bin/sh
#
# DSM 6.x 没有 systemd：addon 在 late 阶段把 unit 写进 DSM 根
# （/usr/lib/systemd/system/ 与 multi-user.target.wants/），这些 unit 在 6.x 上永远不会被执行。
#
# 本脚本分两个阶段：
#   阶段一（late，安装时，仍运行在 ramdisk）：
#     把自身装进 DSM 根 /usr/rr/addons/，并在 /usr/share/init/ 写一个 upstart job，
#     让 DSM 6.x 每次启动时在 runlevel 1 执行阶段二。
#     （6.x 的 upstart 任务是 /usr/share/init/*.conf 里的 start on runlevel 1）
#   阶段二（boot，DSM 6.x 根文件系统）：
#     枚举 /usr/lib/systemd/system/multi-user.target.wants/*.service，按 unit 里的
#     Environment= / ExecStart= 执行一次 Type=oneshot / Type=forking 的服务。
#
# 只实现现有 addon 用到的子集：多行 ExecStart、`-` 前缀（失败不阻塞）、Environment=、
# Type=simple/notify/dbus 放后台。不解析 After= / Wants= / %i —— 6.x 上按 unit 文件名字典序执行。
#
# 1 - 阶段：late（安装进 DSM 根）| boot（执行 unit）；其它值直接返回

WANTED="/usr/lib/systemd/system/multi-user.target.wants"
UPSTART_DIR="/usr/share/init"
JOB_FILE="rr-addons.conf"
RR_ADDON_DIR="/usr/rr/addons"

# 阶段一：把本脚本与 upstart job 写进 DSM 根（ramdisk 视角下 DSM 根在 /tmpRoot）
install_bridge() {
  _root="${TMP_ROOT:-/tmpRoot}"

  # 没有任何 addon 写 unit 就不装桥接，避免在 6.x 上多一个空任务
  if [ ! -d "${_root}${WANTED}" ]; then
    echo "dsm6-services: ${_root}${WANTED} not found, skip bridge"
    return 0
  fi

  mkdir -p "${_root}${RR_ADDON_DIR}" "${_root}${UPSTART_DIR}" || return 1
  cp -f "${0}" "${_root}${RR_ADDON_DIR}/dsm6-services.sh" || return 1
  chmod a+x "${_root}${RR_ADDON_DIR}/dsm6-services.sh" || return 1

  {
    echo 'description "RR addons services (DSM 6.x, no systemd)"'
    echo 'start on runlevel 1'
    echo 'task'
    echo 'console none'
    echo 'env PATH=/usr/syno/sbin:/usr/syno/bin:/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin'
    echo 'exec /usr/rr/addons/dsm6-services.sh boot'
  } >"${_root}${UPSTART_DIR}/${JOB_FILE}" || return 1
  echo "dsm6-services: installed ${UPSTART_DIR}/${JOB_FILE}"
}

# 阶段二：在 DSM 根里执行已启用 unit 的 ExecStart
run_units() {
  if [ ! -d "${WANTED}" ]; then
    echo "dsm6-services: ${WANTED} not found"
    return 0
  fi

  for _u in "${WANTED}"/*.service; do
    [ -e "${_u}" ] || continue

    # .wants 里是绝对路径软链，解析到真实 unit 文件
    _unit="$(readlink -f "${_u}" 2>/dev/null)"
    [ -n "${_unit}" ] || _unit="${_u}"
    if [ ! -f "${_unit}" ]; then
      echo "dsm6-services: skip $(basename "${_u}") (broken link to ${_unit})"
      continue
    fi

    _type="$(sed -n 's/^Type=//p' "${_unit}" | head -n1)"
    _envs="$(sed -n 's/^Environment=//p' "${_unit}" | tr '\n' ' ')"

    # sed 而不是 grep：unit 可以有多条 ExecStart（如 udevrules.service）
    sed -n 's/^ExecStart=//p' "${_unit}" | while IFS= read -r _line; do
      _ignore=0
      case "${_line}" in
        -*) _ignore=1; _line="${_line#-}" ;;
      esac
      [ -z "${_line}" ] && continue

      echo "dsm6-services: $(basename "${_u}") [${_type:-simple}] -> ${_line}"
      case "${_type}" in
        simple | notify | dbus)
          # 常驻进程：放后台，不阻塞 runlevel 1 的任务队列
          env ${_envs} /bin/sh -c "${_line}" </dev/null >/dev/null 2>&1 &
          ;;
        *)
          # oneshot / forking：同步执行（forking 的服务自己 daemon 化后返回）
          if ! env ${_envs} /bin/sh -c "${_line}" </dev/null; then
            [ "${_ignore}" -eq 1 ] || echo "dsm6-services: FAILED ${_line}"
          fi
          ;;
      esac
    done
  done
}

case "${1}" in
  late) install_bridge ;;
  boot) run_units ;;
  *) exit 0 ;;
esac
