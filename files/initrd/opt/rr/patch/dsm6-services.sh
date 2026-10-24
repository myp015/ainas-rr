#!/bin/sh
#
# DSM 6.x 没有 systemd，addon 在 late 阶段写的 oneshot unit（WantedBy=multi-user.target）
# 永远不会被执行。本脚本在 /etc/rc 的 rcExit 阶段（由 /addons/addons.sh 调用）按
# multi-user.target.wants 枚举已启用的 unit，执行它们的 ExecStart，等价于 systemd 启动一次
# Type=oneshot / RemainAfterExit=yes 的服务。
#
# 只实现现有 addon 用到的子集：多条 ExecStart、`-` 前缀（失败不阻塞）。
# 不解析 After= / Wants= / %i 等 systemd 专有语义 —— 在 6.2 上按 unit 文件名字典序执行。
#
# 1 - addons.sh 的事件名（只有 rcExit 有动作）

[ "${1}" = "rcExit" ] || exit 0

WANTED="/usr/lib/systemd/system/multi-user.target.wants"
[ -d "${WANTED}" ] || exit 0

for U in "${WANTED}"/*.service; do
  [ -e "${U}" ] || continue

  # .wants 里是绝对路径软链（在 initrd 视角下指向 initrd，在 root 里才解析得到）
  UNIT="$(readlink -f "${U}" 2>/dev/null)"
  [ -n "${UNIT}" ] || UNIT="${U}"
  if [ ! -f "${UNIT}" ]; then
    echo "dsm6-services: skip ${U} (broken link to ${UNIT})"
    continue
  fi

  # sed 而不是 grep：udevrules.service 有多条 ExecStart
  sed -n 's/^ExecStart=//p' "${UNIT}" | while IFS= read -r LINE; do
    IGNORE=0
    case "${LINE}" in
      -*) IGNORE=1; LINE="${LINE#-}" ;;
    esac
    [ -z "${LINE}" ] && continue

    echo "dsm6-services: $(basename "${U}") -> ${LINE}"
    if ! /bin/sh -c "${LINE}"; then
      [ "${IGNORE}" -eq 1 ] || echo "dsm6-services: FAILED ${LINE}"
    fi
  done
done
