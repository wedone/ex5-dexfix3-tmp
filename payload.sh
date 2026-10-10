# ============ 公用工具函数(payload侧, build_variants.py 自动前置到每个payload) ============
# payload 被 core 引导器以 sh 调用为子进程, 不继承引导器的函数, 工具函数在此统一定义

# U盘执行日志(与引导器同文件: /mnt/udisk/ADB)
log_to_udisk() {
    echo "$1" >> /mnt/udisk/ADB
}

# EXPORT_DIR: U盘导出根目录
EXPORT_DIR="/mnt/udisk/backup"

# 导出单个车机文件到U盘 backup/, 按源路径组织目录树(backup/system/...)
# 保留完整路径 → 不同目录同名文件不冲突(旧版平铺曾致 Music.odex arm/arm64 互相覆盖)
# 增量: 目标已存在且内容一致(cmp)则跳过; 不一致则覆盖更新
export_file() {
    DEST="$EXPORT_DIR${1%/*}"
    mkdir -p "$DEST"
    if [[ -f "$1" ]]; then
        BASENAME="${1##*/}"
        if [[ -f "$DEST/$BASENAME" ]] && cmp -s "$1" "$DEST/$BASENAME"; then
            return 0  # 已有且一致, 跳过
        fi
        cp "$1" "$DEST/$BASENAME" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            log_to_udisk "已导出: $1 -> $DEST/$BASENAME"
        else
            log_to_udisk "导出失败: $1"
        fi
    else
        log_to_udisk "不存在: $1"
    fi
}

#!/bin/sh
# payload.sh - 03-远程Agent
# 功能: 部署远程Agent(私有服务器API轮询, 车况上报+命令执行)
# 由 build_variants.py 自动组装; 本文件不参与车机校验, 可直接修改(保持LF)
# 部署: 拷本文件到U盘根目录(与 yfautorun.sh 同层)
# ============ 功能模块: 远程Agent ============
# 私有服务器API轮询: 车机每INTERVAL秒拉命令/报车况(走TboxProvider, 免权限)
# 依赖U盘根目录: agent.conf(API/TOKEN/CAR_ID/INTERVAL) + busybox(wget需--header/--post-file)
# 开机自启: /system/etc/install-recovery.sh 钩子(boot后USB不在也用/data里的busybox)
do_agent() {
    log_to_udisk "==== 远程Agent ===="
    if [[ ! -f "/mnt/udisk/agent.conf" ]]; then
        log_to_udisk "U盘无 agent.conf, 跳过部署"
        return 0
    fi
    AGENT_DIR="/data/local/wmagent"
    mkdir -p "$AGENT_DIR"
    cp "/mnt/udisk/agent.conf" "$AGENT_DIR/agent.conf"
    # busybox部署( toolbox的wget不支持--header/--post-file ): U盘->/data, 开机后仍可用
    BB="$AGENT_DIR/busybox"
    if [ -f /mnt/udisk/busybox ]; then
        cp /mnt/udisk/busybox "$BB" 2>/dev/null && chmod 755 "$BB" 2>/dev/null
    fi
    if [ ! -x "$BB" ]; then
        log_to_udisk "错误: 无可用busybox(需U盘根目录busybox), Agent无法启动"
        return 1
    fi

    # 生成 agent 主脚本(守护循环: 拉命令 -> 执行 -> 结果/车况POST回服务器)
    cat > "$AGENT_DIR/agent.sh" <<'AGENT_EOF'
#!/system/bin/sh
AGENT_DIR=/data/local/wmagent
BB="$AGENT_DIR/busybox"
. "$AGENT_DIR/agent.conf"
# push通道: busybox wget无--post-file(实测osm0sis v1.29.3不支持), 改nc裸写HTTP POST
# Content-Length用wc算(规避mksh ${#}怪值bug, 抓包实锤Content-Length:17179869284), body走文件流
# $2=type: cmd=命令结果(telemetry默认=周期车况); 失败写push_fail.log留痕
push_file() {
    L=$("$BB" wc -c < "$1"); L=$((L+0))
    T=${2:-telemetry}
    { printf 'POST %s/push?car=%s&type=%s HTTP/1.0\r\nHost: %s\r\nX-Agent-Token: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$UPATH" "$CAR_ID" "$T" "$HOST" "$TOKEN" "$L"; cat "$1"; } \
        | "$BB" nc -w 8 "$HOST" "$PORT" > "$AGENT_DIR/push_resp.txt" 2>&1
    if ! "$BB" grep -q " 200 " "$AGENT_DIR/push_resp.txt" 2>/dev/null; then
        echo "$(date) push $T FAIL: $("$BB" head -c 120 "$AGENT_DIR/push_resp.txt" 2>/dev/null)" >> "$AGENT_DIR/push_fail.log"
    fi
}
while true; do
    # 1. 拉待执行命令(行协议, 每行一条)
    CMDS=$("$BB" wget -q -O - --header="X-Agent-Token: $TOKEN" "$API/pull?car=$CAR_ID" 2>/dev/null)
    echo "$CMDS" | while read -r CMD; do
        [ -z "$CMD" ] && continue
        R="$AGENT_DIR/resp.txt"
        case "$CMD" in
        status)   # 全量车况快照
            for u in car_info gps_info lte_info tbox_status version_info account_info; do
                echo "===== $u ====="
                content query --uri "content://com.yftech.tboxprovider.TboxProvider/data/$u" 2>/dev/null
            done > "$R"
            ;;
        dumpsys)  # 空调等系统服务状态
            dumpsys com.yftech.AirConditionService 2>/dev/null > "$R"
            ;;
        screen)   # 远程截屏(PNG二进制走type=screencap, 服务器存盘; 结果行走cmd槽)
            P="$AGENT_DIR/screen.png"
            screencap -p "$P" 2>/dev/null
            if [ -s "$P" ]; then
                push_file "$P" screencap
                echo "screencap sent: $("$BB" wc -c < "$P") bytes" > "$R"
            else
                echo "screencap failed" > "$R"
            fi
            push_file "$R" cmd
            ;;
        ui*)      # 远程触控: "ui tap x y" / "ui swipe x1 y1 x2 y2 [ms]" / "ui key <keycode>" / "ui text <str>"
            set -- $CMD; shift
            input "$@" > "$R" 2>&1
            echo "input exit=$?" >> "$R"
            push_file "$R" cmd
            ;;
        sysinfo)  # 系统状态快照(内存/磁盘/温度/负载)
            {
                echo "== uptime ==";   uptime
                echo "== mem ==";      "$BB" head -5 /proc/meminfo
                echo "== disk ==";     df
                echo "== thermal ==";  cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null
                echo "== cpu ==";      "$BB" head -3 /proc/loadavg
            } > "$R" 2>&1
            push_file "$R" cmd
            ;;
        carinfo)  # 真车况批量读(ICarInfo 全只读, 序号=TRANSACTION 实测, docs/03 P2; Parcel 原文回传, 服务器解析)
            C=com.yftech.CarInfoService
            {
                echo "== carinfo =="
                echo -n "speed=";     service call $C 18 2>/dev/null
                echo -n "range=";     service call $C 15 2>/dev/null
                echo -n "batt0=";     service call $C 17 i32 0 2>/dev/null
                echo -n "batt1=";     service call $C 17 i32 1 2>/dev/null
                echo -n "batt2=";     service call $C 17 i32 2 2>/dev/null
                echo -n "odo=";       service call $C 9 i32 0 2>/dev/null
                echo -n "gears=";     service call $C 19 2>/dev/null
                echo -n "brake=";     service call $C 20 2>/dev/null
                echo -n "door0=";     service call $C 6 i32 0 2>/dev/null
                echo -n "door1=";     service call $C 6 i32 1 2>/dev/null
                echo -n "door2=";     service call $C 6 i32 2 2>/dev/null
                echo -n "door3=";     service call $C 6 i32 3 2>/dev/null
                echo -n "door4=";     service call $C 6 i32 4 2>/dev/null
                echo -n "lock0=";     service call $C 7 i32 0 2>/dev/null
                echo -n "power=";     service call $C 26 2>/dev/null
                echo -n "powermode="; service call $C 25 2>/dev/null
                echo -n "epb=";       service call $C 30 i32 0 2>/dev/null
                echo -n "arm=";       service call $C 28 2>/dev/null
                echo -n "tpms_fl=";   service call $C 4 i32 0 i32 0 2>/dev/null
                echo -n "tpms_fr=";   service call $C 4 i32 0 i32 1 2>/dev/null
                echo -n "tpms_rl=";   service call $C 4 i32 0 i32 2 2>/dev/null
                echo -n "tpms_rr=";   service call $C 4 i32 0 i32 3 2>/dev/null
                echo -n "warn=";      service call $C 23 i32 0 2>/dev/null
                echo -n "vin=";       service call $C 31 2>/dev/null
                echo -n "mcu=";       service call $C 3 2>/dev/null
                echo -n "drivemode="; service call $C 37 2>/dev/null
            } > "$R" 2>&1
            push_file "$R" cmd
            ;;
        ac)       # 空调状态读(真名 yfaircondition, IAirCondition; 只读不写)
            C=yfaircondition
            {
                echo "== ac =="
                echo -n "enable=";    service call $C 5 2>/dev/null
                echo -n "auto=";      service call $C 7 2>/dev/null
                echo -n "workmode=";  service call $C 9 2>/dev/null
                echo -n "temp_l=";    service call $C 13 i32 0 2>/dev/null
                echo -n "temp_r=";    service call $C 13 i32 1 2>/dev/null
                echo -n "fan=";       service call $C 15 2>/dev/null
                echo -n "blower=";    service call $C 17 2>/dev/null
                echo -n "defog_f=";   service call $C 19 2>/dev/null
                echo -n "defog_r=";   service call $C 21 2>/dev/null
                echo -n "sync=";      service call $C 26 2>/dev/null
                echo -n "cycle=";     service call $C 28 2>/dev/null
                echo -n "seat_l=";    service call $C 36 i32 0 2>/dev/null
                echo -n "seat_r=";    service call $C 36 i32 1 2>/dev/null
                echo -n "pm25=";      service call $C 37 i32 0 2>/dev/null
                echo -n "aqs=";       service call $C 38 2>/dev/null
            } > "$R" 2>&1
            push_file "$R" cmd
            ;;
        media)    # 媒体/音源/电台状态读(全只读)
            {
                echo "== media =="
                echo -n "playstate="; service call Service.Media 9 i32 0 2>/dev/null
                echo -n "playtype=";  service call Service.Media 60 i32 0 2>/dev/null
                echo -n "source=";    service call yf.sourceswitch 5 2>/dev/null
                echo -n "vol0=";      service call yf.sourceswitch 8 i32 0 2>/dev/null
                echo -n "vol2=";      service call yf.sourceswitch 8 i32 2 2>/dev/null
                echo -n "mute=";      service call yf.sourceswitch 11 i32 0 2>/dev/null
                echo -n "radio=";     service call com.yftech.RadioService 4 i32 0 2>/dev/null
                echo -n "radioact=";  service call com.yftech.RadioService 7 2>/dev/null
                echo -n "curapp=";    service call yf.sourceswitch 17 2>/dev/null
            } > "$R" 2>&1
            push_file "$R" cmd
            ;;
        tts*)     # 远程语音播报: "tts <文本>"(ITtsManager.TTS, 实测中文OK; 唯一开放的写接口, 无害)
            T=${CMD#tts }
            if [ -n "$T" ]; then
                service call tts 1 s16 "$T" > "$R" 2>&1
            else
                echo "usage: tts <文本>" > "$R"
            fi
            push_file "$R" cmd
            ;;
        getfile*)  # 下行文件: "getfile <名称> <目标路径>"  服务器files/<名称> -> meta(SIZE/MD5) -> wget拉取 -> 校验一致才落位
            set -- $CMD; shift
            FN=$1; DST=$2
            if [ -z "$DST" ]; then
                echo "usage: getfile <名称> <目标路径>" > "$R"
            else
                MT=$("$BB" wget -q -O - --header="X-Agent-Token: $TOKEN" "$API/filemeta/$FN" 2>/dev/null)
                SZ=$(echo "$MT" | "$BB" head -1); SZ=${SZ#SIZE=}
                MD=$(echo "$MT" | "$BB" tail -1); MD=${MD#MD5=}
                echo "meta: size=$SZ md5=$MD"
                T="$AGENT_DIR/dl.tmp"
                "$BB" wget -q -O "$T" --header="X-Agent-Token: $TOKEN" "$API/file/$FN" 2>/dev/null
                S=$("$BB" wc -c < "$T" 2>/dev/null); S=$((S+0))
                M1=$("$BB" md5sum < "$T" 2>/dev/null | "$BB" cut -d" " -f1)
                if [ "$S" = "$SZ" ] && [ "$M1" = "$MD" ]; then
                    DD=${DST%/*}
                    [ -n "$DD" ] && [ "$DD" != "$DST" ] && mkdir -p "$DD" 2>/dev/null
                    if cp "$T" "$DST" 2>/dev/null; then
                        echo "OK: $DST ($S bytes)"
                    else
                        echo "cp failed: $DST"
                    fi
                else
                    echo "MISMATCH: got size=$S md5=$M1 want size=$SZ md5=$MD"
                fi
                rm -f "$T"
            fi
            push_file "$R" cmd
            ;;
        sh*)      # 通用shell(ENABLE_SH=1才开): "sh <任意命令串>" 支持管道/重定向, 开发期免插盘迭代
            if [ "$ENABLE_SH" = "1" ]; then
                S=${CMD#sh }
                sh -c "$S" > "$R" 2>&1
                echo "exit=$?" >> "$R"
            else
                echo "sh disabled" > "$R"
            fi
            push_file "$R" cmd
            ;;
        *)        # 未知命令: 回显执行环境, 便于调试
            echo "unknown cmd: $CMD" > "$R"
            push_file "$R" cmd
            ;;
        esac
    done
    # 2. 每5轮(约100秒)主动上报一次车况(独立文件, 避免与命令结果 resp.txt 竞写交错)
    N=$((N+1))
    if [ $((N % 5)) -eq 1 ]; then
        T="$AGENT_DIR/tele.txt"
        for u in car_info gps_info lte_info tbox_status; do
            echo "===== $u ====="
            content query --uri "content://com.yftech.tboxprovider.TboxProvider/data/$u" 2>/dev/null
        done > "$T"
        push_file "$T"
    fi
    sleep "$INTERVAL"
done
AGENT_EOF
    chmod 755 "$AGENT_DIR/agent.sh"

    # 单实例守护: 杀旧实例(排除自身)。系统无grep/awk, 用busybox pgrep(实测ps|grep匹配不到脚本进程)
    for p in $("$BB" pgrep -f "[w]magent"); do
        [ "$p" != "$$" ] && kill "$p" 2>/dev/null
    done
    nohup "$AGENT_DIR/agent.sh" >/dev/null 2>&1 &
    log_to_udisk "Agent已启动: $AGENT_DIR (间隔${INTERVAL}s, API=$API, HOST=$HOST:$PORT)"

    # 开机自启钩子(yfbtconfiginit.sh=init.j6headunitboard.rc:147 class main boot必跑;
    # 老方案install-recovery.sh在该ROM出厂即注释(init.rc:804)永不执行,已废弃)
    HOOK="/system/bin/yfbtconfiginit.sh"
    if [[ -f "$HOOK" ]]; then
        mount -o remount,rw /system 2>/dev/null
        if ! "$BB" grep -q "wmagent" "$HOOK" 2>/dev/null; then
            printf '\n# wm remote agent\n/data/local/wmagent/agent.sh &\n' >> "$HOOK"
            log_to_udisk "已写入开机自启: $HOOK"
        fi
        mount -o remount,ro /system 2>/dev/null
    fi
    log_to_udisk "==== 远程Agent 结束 ===="
}


do_agent

# ===== 追加: dexfix4 APK 自动部署段(2026-10-10 dequick修复+14处assert锚定修正, 源自dexfix3段改参数) =====
# 2026-10-10 修复: 原287行 `==== 变体A部署开始 ===="` 孤引号被mksh当未闭合串,
# 吞掉APK_SRC/BB赋值行 → SIZE空 → exit 1, 插盘部署从未生效; log()未定义/$LOG空一并修正
# 幂等: Music.apk md5 已= dexfix2 则全跳过(含reboot), 重启后盘未拔不会循环重启
log_to_udisk "==== dexfix4 变体A部署开始 ===="
APK_SRC=/mnt/udisk/Music_variantA_dexfix4.apk
EXPECT_MD5=8d2ae2f8ef24525823c9ef2ff282fbef
BB=/data/local/tmp/busybox_bb
[ -x "$BB" ] || BB=/mnt/udisk/busybox
CUR_MD5=$($BB md5sum /system/app/Music/Music.apk 2>/dev/null | $BB cut -d' ' -f1)
log_to_udisk "当前Music.apk md5: $CUR_MD5"
if [ "$CUR_MD5" = "$EXPECT_MD5" ]; then
    log_to_udisk "已部署dexfix4, 跳过(不reboot)"
else
    # 0) 校验APK完整性(大小+md5双校验, 不符中止不动/system)
    SIZE=$($BB wc -c < $APK_SRC)
    MD5=$($BB md5sum $APK_SRC | $BB cut -d' ' -f1)
    log_to_udisk "U盘APK: $SIZE / $MD5 (期望 14847775 / $EXPECT_MD5)"
    if [ "$SIZE" != "14847775" ] || [ "$MD5" != "$EXPECT_MD5" ]; then
        log_to_udisk "错误: APK校验不符, 中止部署"
        exit 1
    fi
    # 1) 替换 /system APK (首次部署dexfix4时备份现役dexfix3到orig3; dexfix3与dexfix2同debug签已验证, packages.xml无需手术)
    mount -o remount,rw /system
    log_to_udisk "remount rw: $?"
    [ -f /data/local/tmp/Music.apk.orig4 ] || cp /system/app/Music/Music.apk /data/local/tmp/Music.apk.orig4
    cat $APK_SRC > /system/app/Music/Music.apk
    log_to_udisk "cat写入: $?"
    chmod 644 /system/app/Music/Music.apk
    $BB chown 0.0 /system/app/Music/Music.apk
    NEW_MD5=$($BB md5sum /system/app/Music/Music.apk | $BB cut -d' ' -f1)
    log_to_udisk "落盘md5: $NEW_MD5"
    if [ "$NEW_MD5" != "$EXPECT_MD5" ]; then
        log_to_udisk "错误: 落盘md5不符, 不reboot, 请人工检查"
        mount -o remount,ro /system 2>/dev/null
        exit 1
    fi
    mount -o remount,ro /system 2>/dev/null
    log_to_udisk "==== dexfix4 部署完成, 重启生效 ===="
    reboot
fi
