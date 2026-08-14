#!/bin/bash
set -u

msg=$1
target_name=$2
atus_base_url=$3

WS="${GITHUB_WORKSPACE:-/tmp}"
GITEE_FAILED="${WS}/.gitee_push_failed"
BACK_SYNC_FAILED="${WS}/.gitee_back_sync_failed"
PENDING_INFO="${WS}/.pending_release_info"

rm -f "$GITEE_FAILED" "$BACK_SYNC_FAILED" "$PENDING_INFO"

cd "/home/runner/${target_name}" || { echo "[commit.sh][error] cd to /home/runner/${target_name} failed"; exit 1; }

git config core.sshCommand "ssh -o ConnectTimeout=15 -o ServerAliveCountMax=3 -o ServerAliveInterval=10"
git remote add gitee "git@gitee.com:SVGROUP/${target_name}.git" 2>/dev/null || true

if [ -f "no_push" ]; then
    echo "[commit.sh] no_push 文件存在,跳过提交(add/commit/github push)"
    skip_publish=1
fi

if [ -n "$(git status --porcelain)" ] && [ "${skip_publish:-0}" != "1" ]; then
    echo "[commit.sh] 工作区有变化,走完整发布流程"
    git switch master
    git add -A
    git commit -m "${msg}" --allow-empty

    timeout 60 git push origin master && echo "(github push ok)" || { echo '[commit.sh] 第一次增量 push 失败,尝试带 --force 覆盖(仅在切模式时触发一次)'; timeout 60 git push origin master --force || { echo "[commit.sh][error] github push 失败/超时,中止"; exit 1; }; }
    echo "---finish commit github ${target_name}---"

    release_hash=$(git rev-parse HEAD)
    build_ts=$(cat /home/runner/build_ts 2>/dev/null || date +%s)

    timeout 60 git push gitee master && echo "---finish commit gitee ${target_name}---" && gitee_push_ok=1 || gitee_push_ok=0
    if [ "${gitee_push_ok}" != "1" ]; then
        echo '[commit.sh] gitee 增量 push 失败/超时,尝试带 --force 覆盖'
        timeout 60 git push gitee master --force && echo "---finish commit gitee ${target_name} (forced)---" && gitee_push_ok=1 || gitee_push_ok=0
    fi
    if [ "${gitee_push_ok}" != "1" ]; then
        echo "[commit.sh] gitee push 全部失败/超时,记 marker,等 back-sync 兜底"
        echo "1" > "$GITEE_FAILED"
        printf 'release_hash=%s\nbuild_ts=%s\n' "${release_hash}" "${build_ts}" > "$PENDING_INFO"
    fi
else
    echo "[commit.sh] 工作区干净(无变化),跳过 add/commit/github push,直接进入 back-sync 兜底"
fi

timeout 60 git fetch gitee master 2>/dev/null || true
timeout 60 git fetch origin master

gh_head=$(git rev-parse origin/master)
gitee_head=$(git rev-parse gitee/master 2>/dev/null || echo "missing")

gh_short=$(echo "$gh_head" | cut -c1-12)
gitee_short=$(echo "$gitee_head" | cut -c1-12)

if [ "$gh_head" = "$gitee_head" ]; then
    echo "[back-sync] gitee already in sync (${gh_short}), nothing to do"
    rm -f "$GITEE_FAILED" "$PENDING_INFO"
else
    echo '[back-sync] gitee (back-sync) forcing push'
    if timeout 60 git push gitee "origin/master:master" --force; then
        echo "[back-sync] gitee back-sync OK, now at ${gh_short}"
        rm -f "$GITEE_FAILED" "$PENDING_INFO"
    else
        echo "[back-sync][error] gitee back-sync 失败/超时,本次 CI 失败"
        echo "1" > "$BACK_SYNC_FAILED"
        exit 1
    fi
fi

cd "/home/runner/${target_name}" || exit 1
rh=$(git rev-parse HEAD)
ts=$(cat /home/runner/build_ts 2>/dev/null || date +%s)
echo "[commit.sh] new_version 上报: t=${target_name} v=${ts} h=${rh}"
curl -sS -X POST "${atus_base_url}/sv/auth/api/new_version" \
    -H "Content-Type: application/json" \
    -d "{\"t\":\"${target_name}\",\"v\":${ts},\"m\":\"${msg}\",\"h\":\"${rh}\"}" || true
echo ""
curl -sS "${atus_base_url}/sv/auth/api/force_now?t=${target_name}" || true
echo ""
