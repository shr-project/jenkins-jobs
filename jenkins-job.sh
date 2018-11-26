#!/usr/bin/env bash

BUILD_SCRIPT_VERSION="1.8.45"
BUILD_SCRIPT_NAME=`basename ${0}`

BUILD_BRANCH="yoe/mut"
# These are used by in following functions, declare them here so that
# they are defined even when we're only sourcing this script
BUILD_TIME_STR="TIME: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} %e %S %U %P %c %w %R %F %M %x %C"

BUILD_TIMESTAMP_START=`date -u +%s`
BUILD_TIMESTAMP_OLD=${BUILD_TIMESTAMP_START}

pushd `dirname $0` > /dev/null
BUILD_WORKSPACE=`pwd -P`
popd > /dev/null

BUILD_DIR="yoe"
BUILD_TOPDIR="${BUILD_WORKSPACE}/${BUILD_DIR}"
BUILD_TIME_LOG=${BUILD_TOPDIR}/time.txt

LOG_RSYNC_DIR="jenkins@logs.nslu2-linux.org:htdocs/buildlogs/oe/world/warrior"
LOG_HTTP_ROOT="http://logs.nslu2-linux.org/buildlogs/oe/world/warrior/"

BUILD_QA_ISSUES="already-stripped libdir textrel build-deps file-rdeps version-going-backwards host-user-contaminated installed-vs-shipped unknown-configure-option symlink-to-sysroot invalid-pkgconfig pkgname ldflags compile-host-path qa_pseudo"

TMPFS="${BUILD_TOPDIR}/build/tmpfs"

function report_error {

    if [ ! -e ${HOME}/.oe-send-error ]
    then
        echo `git config --get user.name` > ${HOME}/.oe-send-error
        echo `git config --get user.email` >> ${HOME}/.oe-send-error
    fi

    eval `grep -e "send-error-report " \
          ${TMPFS}/log/cooker/${BUILD_MACHINE}/console-latest.log | \
          sed 's/^.*send-error-report/send-error-report -y/' | \
          sed 's/\[.*$//g'`
}

function print_timestamp {
    BUILD_TIMESTAMP=`date -u +%s`
    BUILD_TIMESTAMPH=`date -u +%Y%m%dT%TZ`

    local BUILD_TIMEDIFF=`expr ${BUILD_TIMESTAMP} - ${BUILD_TIMESTAMP_OLD}`
    local BUILD_TIMEDIFF_START=`expr ${BUILD_TIMESTAMP} - ${BUILD_TIMESTAMP_START}`
    BUILD_TIMESTAMP_OLD=${BUILD_TIMESTAMP}
    printf "TIME: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} ${1}: ${BUILD_TIMESTAMP}, +${BUILD_TIMEDIFF}, +${BUILD_TIMEDIFF_START}, ${BUILD_TIMESTAMPH}\n" | tee -a ${BUILD_TIME_LOG}
}

function parse_job_name {
    case ${JOB_NAME} in
        oe_world_*)
            BUILD_VERSION="world"
            ;;
        *)
            echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Unrecognized version in JOB_NAME: '${JOB_NAME}', it should start with oe_ and 'world'"
            exit 1
            ;;
    esac

    case ${JOB_NAME} in
        *_qemuarm)
            BUILD_MACHINE="qemuarm"
            ;;
        *_qemuarm64)
            BUILD_MACHINE="qemuarm64"
            ;;
        *_qemux86)
            BUILD_MACHINE="qemux86"
            ;;
        *_qemux86-64)
            BUILD_MACHINE="qemux86-64"
            ;;
        *_workspace-*)
            # global jobs
            ;;
        *)
            echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Unrecognized machine in JOB_NAME: '${JOB_NAME}', it should end with '_qemuarm', '_qemuarm64', '_qemux86', '_qemux86-64'"
            exit 1
            ;;
    esac

    case ${JOB_NAME} in
        *_workspace-cleanup)
            BUILD_TYPE="cleanup"
            ;;
        *_workspace-compare-signatures)
            BUILD_TYPE="compare-signatures"
            ;;
        *_workspace-prepare)
            BUILD_TYPE="prepare"
            ;;
        *_workspace-parse-results)
            BUILD_TYPE="parse-results"
            ;;
        *_workspace-kill-stalled)
            BUILD_TYPE="kill-stalled"
            ;;
        *_workspace-rsync)
            BUILD_TYPE="rsync"
            ;;
        *_test-dependencies_*)
            BUILD_TYPE="test-dependencies"
            ;;
        *)
            BUILD_TYPE="build"
            ;;
    esac
}

function sanity_check_workspace {
    # BUILD_TOPDIR path should contain BUILD_VERSION, otherwise there is probably incorrect WORKSPACE in jenkins config
    if ! echo ${BUILD_TOPDIR} | grep -q "/oe/world/" ; then
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} BUILD_TOPDIR: '${BUILD_TOPDIR}' path should contain /oe/world/ directory, is workspace set correctly in jenkins config?"
        exit 1
    fi
    if ps aux | grep "[b]itbake"; then
        if [ "${BUILD_TYPE}" = "kill-stalled" ] ; then
            echo "WARN: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} There is some bitbake process already running from '${BUILD_TOPDIR}', maybe some stalled process from aborted job?"
        else
            echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} There is some bitbake process already running from '${BUILD_TOPDIR}', maybe some stalled process from aborted job?"
            exit 1
        fi
    fi
}

function kill_stalled_bitbake_processes {
    if ps aux | grep "bitbake/bin/[b]itbake" ; then
        local BITBAKE_PIDS=`ps aux | grep "bitbake/bin/[b]itbake" | awk '{print $2}' | xargs`
        [ -n "${BITBAKE_PIDS}" ] && kill ${BITBAKE_PIDS}
        sleep 10
        ps aux | grep "bitbake/bin/[b]itbake"
        local BITBAKE_PIDS=`ps aux | grep "bitbake/bin/[b]itbake" | awk '{print $2}' | xargs`
        [ -n "${BITBAKE_PIDS}" ] && kill -9 ${BITBAKE_PIDS}
        ps aux | grep "bitbake/bin/[b]itbake" || true
    fi
}

function run_build {
    declare -i RESULT=0

    cat <<EOF > ${BUILD_TOPDIR}/local.sh
export MACHINE=${BUILD_MACHINE}
export DOCKER_REPO="none"
EOF
    cd ${BUILD_TOPDIR}
    git pull
    . ./envsetup.sh

    yoe_setup

    show-git-log
    export LC_ALL=en_US.utf8
    LOGDIR=log.world.${MACHINE}.`date "+%Y%m%d_%H%M%S"`.log
    mkdir -p ${LOGDIR}
    [ -d ${BUILD_TOPDIR}/build/tmpfs ] && rm -rf ${BUILD_TOPDIR}/build/tmpfs/*;
    [ -d ${BUILD_TOPDIR}/build/tmpfs ] || mkdir -p ${BUILD_TOPDIR}/build/tmpfs
    mount | grep "build/tmpfs type tmpfs" && echo "Some tmpfs already has tmpfs mounted, skipping mount" || mount ${BUILD_TOPDIR}/build/tmpfs
    sanity-check
#    time bitbake -k virtual/kernel  2>&1 | tee -a ${LOGDIR}/bitbake.log || break;
#    if [ "${BUILD_MACHINE}" = "qemux86" -o "${BUILD_MACHINE}" = "qemux86-64" ] ; then
#        time bitbake -k chromium  2>&1 | tee -a ${LOGDIR}/bitbake.log || break;
#        time bitbake -k chromium-wayland  2>&1 | tee -a ${LOGDIR}/bitbake.log || break;
#    fi
    cd ${BUILD_TOPDIR}
    time bitbake -k world  2>&1 | tee -a ${LOGDIR}/bitbake.log || break;
    RESULT+=${PIPESTATUS[0]}
    cat ${BUILD_TOPDIR}/build/tmpfs/qa.log >> ${LOGDIR}/qa.log || echo "No QA issues";

    cp conf/local.conf ${LOGDIR}
    rsync -avir ${LOGDIR} ${LOG_RSYNC_DIR}
    cat ${LOGDIR}/qa.log && true
    report_error
    # wait for pseudo
    sleep 180
    umount ${BUILD_TOPDIR}/build/tmpfs || echo "Umounting tmpfs failed"
    rm -rf ${BUILD_TOPDIR}/build/tmpfs/*;

    exit ${RESULT}
}

function sanity-check {
    # check that tmpfs is mounted and has enough space
    if ! mount | grep -q "build/tmpfs type tmpfs"; then
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} tmpfs isn't mounted in ${BUILD_TOPDIR}/build/tmpfs"
        exit 1
    fi
    local available_tmpfs=`df -BG ${BUILD_TOPDIR}/build/tmpfs | grep build/tmpfs | awk '{print $4}' | sed 's/G$//g'`
    if [ ${available_tmpfs} -lt 15 ] ; then
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} tmpfs mounted in ${BUILD_TOPDIR}/build/tmpfs has less than 15G free"
        exit 1
    fi
    local tmpfs tmpfs_allocated_all=0
    for tmpfs in `mount | grep "tmpfs type tmpfs" | awk '{print $3}'`; do
        df -BG $tmpfs | grep $tmpfs;
        local tmpfs_allocated=`df -BG $tmpfs | grep $tmpfs | awk '{print $3}' | sed 's/G$//g'`
        tmpfs_allocated_all=`expr ${tmpfs_allocated_all} + ${tmpfs_allocated}`
    done
    # we have 2 tmpfs mounts with max size 80GB, but only 97GB of RAM, show error when more than 65G is already allocated
    # in them
    if [ "${tmpfs_allocated_all}" -gt 65 ] ; then
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} sum of allocated space in tmpfs mounts is more than 65G, clean some builds"
        exit 1
    fi
}

function run_cleanup {
    if [ -d ${BUILD_TOPDIR}/build ] ; then
        cd ${BUILD_TOPDIR}/build;
        ARCHS="core2-64,i586,armv5te,aarch64,qemuarm,qemuarm64,qemux86,qemux86_64"
        DU1=`du -hs sstate-cache`
        echo "$DU1"
        OPENSSL="find sstate-cache -name '*:openssl:*populate_sysroot*tgz'"
        ARCHIVES1=`sh -c "${OPENSSL}"`; echo "number of openssl archives: `echo "$ARCHIVES1" | wc -l`"; echo "$ARCHIVES1"
        ${BUILD_TOPDIR}/sources/openembedded-core/scripts/sstate-cache-management.sh -L --cache-dir=sstate-cache -y -d --extra-archs=${ARCHS// /,} || true
        DU2=`du -hs sstate-cache`
        echo "$DU2"
        ARCHIVES2=`sh -c "${OPENSSL}"`; echo "number of openssl archives: `echo "$ARCHIVES2" | wc -l`"; echo "$ARCHIVES2"

        mkdir -p old || true
        umount tmpfs || true
        mv -f ${BUILD_TOPDIR}/cache/bb_codeparser.dat* ${BUILD_TOPDIR}/bitbake.lock ${BUILD_TOPDIR}/pseudodone ${BUILD_TOPDIR}/build/tmpfs* old || true
        rm -rf old

        echo "BEFORE:"
        echo "number of openssl archives: `echo "$ARCHIVES1" | wc -l`"; echo "$ARCHIVES1"
        echo "AFTER:"
        echo "number of openssl archives: `echo "$ARCHIVES2" | wc -l`"; echo "$ARCHIVES2"
        echo "BEFORE: $DU1, AFTER: $DU2"
    fi
    echo "Cleanup finished"
}

function run_compare-signatures {
    declare -i RESULT=0

    cd ${BUILD_TOPDIR}
    export LC_ALL=en_US.utf8
    . ./envsetup.sh

    LOGDIR=log.signatures.`date "+%Y%m%d_%H%M%S"`.log
    mkdir -p ${LOGDIR}
    rm -rf ${BUILD_TOPDIR}/build/tmpfs/*;
    mount | grep "tmpfs type tmpfs" && echo "Some tmpfs already has tmpfs mounted, skipping mount" || mount ${BUILD_TOPDIR}/build/tmpfs

    sources/openembedded-core/scripts/sstate-diff-machines.sh --machines="qemux86copy qemux86 qemuarm" --targets=world --tmpdir=${BUILD_TOPDIR}/build/tmpfs/ --analyze 2>&1 | tee ${LOGDIR}/signatures.log
    RESULT+=${PIPESTATUS[0]}

    OUTPUT=`grep "INFO: Output written in: " ${LOGDIR}/signatures.log | sed 's/INFO: Output written in: //g'`
    ls ${OUTPUT}/signatures.*.*.log >/dev/null 2>/dev/null && cp ${OUTPUT}/signatures.*.*.log ${LOGDIR}/

    rsync -avir ${LOGDIR} ${LOG_RSYNC_DIR}

    [ -d sstate-diff ] || mkdir -p sstate-diff
    mv ${BUILD_TOPDIR}/build/tmpfs/sstate-diff/* sstate-diff
    report_error
    umount ${BUILD_TOPDIR}/build/tmpfs || echo "Umounting tmpfs failed"
    rm -rf ${BUILD_TOPDIR}/build/tmpfs/*;

    exit ${RESULT}
}

function run_prepare {
    cd ${BUILD_WORKSPACE}
    if [ ! -d ${BUILD_TOPDIR}/.git/ ] ; then
        git clone git://github.com/YoeDistro/yoe-distro -b ${BUILD_BRANCH} yoe
    fi
    git checkout -b ${BUILD_BRANCH} origin/${BUILD_BRANCH} || git checkout ${BUILD_BRANCH}
    yoe_setup
    yoe_update_all
    mkdir -p ${BUILD_TOPDIR}/build
    if [ ! -d ${BUILD_TOPDIR}/build/buildhistory/ ] ; then
        cd ${BUILD_TOPDIR}/build
        git clone git@github.com:kraj/jenkins-buildhistory.git buildhistory
        cd buildhistory;
        git checkout -b oe-world-${HOSTNAME} origin/oe-world-${HOSTNAME} || git checkout -b oe-world-${HOSTNAME}
        cd ${BUILD_WORKSPACE}
    fi
    cat <<EOF > ${BUILD_TOPDIR}/conf/local.conf

# We want musl and glibc to share the same tmpfs, so instead of appending default "-${TCLIBC}" we append "fs"
TCLIBCAPPEND = "fs"

TMPDIR .= "fs"
DL_DIR = "${BUILD_TOPDIR}/../downloads"
PARALLEL_MAKE = "-j 8"
BB_NUMBER_THREADS = "16"
INHERIT += "rm_work"

# For kernel-selftest with linux 4.18+
HOSTTOOLS += "clang llc"

# Reminder to change it later when we have public instance
PRSERV_HOST = "localhost:0"
BB_GENERATE_MIRROR_TARBALLS = "1"
BUILDHISTORY_DIR = "${BUILD_TOPDIR}/buildhistory"
BUILDHISTORY_COMMIT ?= "1"
BUILDHISTORY_COMMIT_AUTHOR ?= "Khem Raj <raj.khem@gmail.com>"
BUILDHISTORY_PUSH_REPO ?= "origin oe-world-${HOSTNAME}"
INHERIT += "reproducible_build_simple"

BB_DISKMON_DIRS = "\
    STOPTASKS,${TMPDIR},1G,100K \
    STOPTASKS,${DL_DIR},1G,100K \
    STOPTASKS,${SSTATE_DIR},1G,100K \
    STOPTASKS,/tmp,100M,100K \
    ABORT,${TMPDIR},100M,1K \
    ABORT,${DL_DIR},100M,1K \
    ABORT,${SSTATE_DIR},100M,1K \
    ABORT,/tmp,10M,1K"

#require world_fixes.inc

PREFERRED_PROVIDER_udev = "systemd"
PREFERRED_PROVIDER_virtual/fftw = "fftw"

# use gold
DISTRO_FEATURES_append = " ld-is-gold"

# use ptest
DISTRO_FEATURES_append = " ptest"

# use systemd
DISTRO_FEATURES_append = " systemd"
DISTRO_FEATURES_BACKFILL_CONSIDERED = "sysvinit"
VIRTUAL-RUNTIME_init_manager = "systemd"
VIRTUAL-RUNTIME_initscripts = ""

# use opengl
DISTRO_FEATURES_append = " opengl"

# use wayland to fix building weston and qtwayland
DISTRO_FEATURES_append = " wayland"

PREFERRED_PROVIDER_jpeg = "libjpeg-turbo"
PREFERRED_PROVIDER_jpeg-native = "libjpeg-turbo-native"
PREFERRED_PROVIDER_gpsd = "gpsd"

# don't pull libhybris unless explicitly asked for
PREFERRED_PROVIDER_virtual/libgl ?= "mesa"
PREFERRED_PROVIDER_virtual/libgles1 ?= "mesa"
PREFERRED_PROVIDER_virtual/libgles2 ?= "mesa"
PREFERRED_PROVIDER_virtual/egl ?= "mesa"

# to fix fsoaudiod, alsa-state conflict in shr-image-all
VIRTUAL-RUNTIME_alsa-state = ""
# to prevent alsa-state being pulled into -dev or -dbg images
RDEPENDS_\${PN}-dev_pn-alsa-state = ""
RDEPENDS_\${PN}-dbg_pn-alsa-state = ""

# to fix dependency on conflicting x11-common from packagegroup-core-x11
VIRTUAL-RUNTIME_xserver_common ?= "xserver-common"
RDEPENDS_\${PN}-dev_pn-x11-common = ""
RDEPENDS_\${PN}-dbg_pn-x11-common = ""

# to fix apm, fso-apm conflict in shr-image-all
VIRTUAL-RUNTIME_apm = "fso-apm"

# require conf/distro/include/qt5-versions.inc
# QT5_VERSION = "5.4.0+git%"

# for qtwebkit etc
# see https://bugzilla.yoctoproject.org/show_bug.cgi?id=5013
# DEPENDS_append_pn-qtbase = " mesa"
PACKAGECONFIG_append_pn-qtbase = " icu gl accessibility freetype fontconfig"

# qtwayland doesn't like egl and xcomposite-glx enabled at the same time
# http://lists.openembedded.org/pipermail/openembedded-devel/2016-December/110444.html
PACKAGECONFIG_remove_pn-qtwayland = "xcomposite-egl xcomposite-glx"

# for webkit-efl
PACKAGECONFIG_append_pn-harfbuzz = " icu"

INHERIT += "blacklist"
# PNBLACKLIST[samsung-rfs-mgr] = "needs newer libsamsung-ipc with negative D_P: Requested 'samsung-ipc-1.0 >= 0.2' but version of libsamsung-ipc is 0.1.0"
PNBLACKLIST[android-system] = "depends on lxc from meta-virtualiazation which isn't included in my world builds"
PNBLACKLIST[bigbuckbunny-1080p] = "big and doesn't really need to be tested so much"
PNBLACKLIST[bigbuckbunny-480p] = "big and doesn't really need to be tested so much"
PNBLACKLIST[bigbuckbunny-720p] = "big and doesn't really need to be tested so much"
PNBLACKLIST[bigbuckbunny-720p] = "big and doesn't really need to be tested so much"
PNBLACKLIST[tearsofsteel-1080p] = "big and doesn't really need to be tested so much"
PNBLACKLIST[build-appliance-image] = "tries to include whole downloads directory in /home/builder/poky :/"

# enable reporting
# needs http://patchwork.openembedded.org/patch/68735/
ERR_REPORT_SERVER = "errors.yoctoproject.org"
ERR_REPORT_PORT = "80"
ERR_REPORT_USERNAME = "Khem Raj"
ERR_REPORT_EMAIL = "raj.khem@gmail.com"
ERR_REPORT_UPLOAD_FAILURES = "1"
INHERIT += "report-error"

# needs patch with buildstats-summary.bbclass
INHERIT += "buildstats buildstats-summary"

# be more strict with QA warnings, turn them all to errors:
ERROR_QA_append = " ldflags useless-rpaths rpaths staticdev libdir xorg-driver-abi             textrel already-stripped incompatible-license files-invalid             installed-vs-shipped compile-host-path install-host-path             pn-overrides infodir build-deps             unknown-configure-option symlink-to-sysroot multilib             invalid-packageconfig host-user-contaminated uppercase-pn"
WARN_QA_remove = " ldflags useless-rpaths rpaths staticdev libdir xorg-driver-abi             textrel already-stripped incompatible-license files-invalid             installed-vs-shipped compile-host-path install-host-path             pn-overrides infodir build-deps             unknown-configure-option symlink-to-sysroot multilib             invalid-packageconfig host-user-contaminated uppercase-pn"

# use musl for qemux86 and qemux86copy
TCLIBC_qemux86 = "musl"
TCLIBC_qemux86copy = "musl"

# Commericial licenses
# chromium
LICENSE_FLAGS_WHITELIST_append = " commercial_ffmpeg commercial_x264 "
# vlc
LICENSE_FLAGS_WHITELIST_append = " commercial_mpeg2dec "
# mpd
LICENSE_FLAGS_WHITELIST_append = " commercial_mpg123 "
# libmad
LICENSE_FLAGS_WHITELIST_append = " commercial_libmad "
# gstreamer1.0-libav
LICENSE_FLAGS_WHITELIST_append = " commercial_gstreamer1.0-libav "
# gstreamer1.0-omx
LICENSE_FLAGS_WHITELIST_append = " commercial_gstreamer1.0-omx "
# omapfbplay
LICENSE_FLAGS_WHITELIST_append = " commercial_lame "
# libomxil
LICENSE_FLAGS_WHITELIST_append = " commercial_libomxil "
# xfce
LICENSE_FLAGS_WHITELIST_append = " commercial_packagegroup-xfce-multimedia commercial_xfce4-mpc-plugin"
LICENSE_FLAGS_WHITELIST_append = " commercial_xfmpc commercial_mpd "
LICENSE_FLAGS_WHITELIST_append = " commercial_mpv "
# epiphany
LICENSE_FLAGS_WHITELIST_append = " commercial_faad2 "
EOF
}

function run_test-dependencies {
    declare -i RESULT=0
    export MACHINE=${BUILD_MACHINE}
    cd ${BUILD_TOPDIR}
    . ./envsetup.sh

    yoe_setup
    export LC_ALL=en_US.utf8

    LOGDIR=log.dependencies.${MACHINE}.`date "+%Y%m%d_%H%M%S"`.log
    mkdir -p ${LOGDIR}

    rm -rf ${BUILD_TOPDIR}/build/tmpfs/*;
    [ -d ${BUILD_TOPDIR}/build/tmpfs ] || mkdir -p ${BUILD_TOPDIR}/build/tmpfs
    mount | grep "tmpfs type tmpfs" && echo "Some tmpfs already has tmpfs mounted, skipping mount" || mount build/tmpfs

    [ -f failed-recipes.${MACHINE} ] || bitbake-layers show-recipes | grep '^[^ ].*:' | grep -v '^=' | sed 's/:$//g' | sort -u > failed-recipes.${MACHINE}
    [ -f failed-recipes.${MACHINE} ] && RECIPES="--recipes=failed-recipes.${MACHINE}"
    pushd build
    # backup full buildhistory and replace it with link to tmpfs
    mv buildhistory buildhistory-all
    mkdir -p ${BUILD_TOPDIR}/build/tmpfs/buildhistory
    ln -s ${BUILD_TOPDIR}/build/tmpfs/buildhistory .

    rm -f ${BUILD_TOPDIR}/build/tmpfs/qa.log
    time ${BUILD_TOPDIR}/sources/openembedded-core/scripts/test-dependencies.sh --tmpdir=${BUILD_TOPDIR}/build/tmpfs $RECIPES 2>&1 | tee -a ${LOGDIR}/test-dependencies.log
    RESULT+=${PIPESTATUS[0]}

    # restore full buildhistory
    rm -rf buildhistory
    mv buildhistory-all buildhistory

    popd
    cat ${BUILD_TOPDIR}/build/tmpfs/qa.log >> ${LOGDIR}/qa.log 2>/dev/null || echo "No QA issues";

    OUTPUT=`grep "INFO: Output written in: " ${LOGDIR}/test-dependencies.log | sed 's/INFO: Output written in: //g'`

    # we want to preserve only partial artifacts
    [ -d ${LOGDIR}/1_all ] || mkdir  -p ${LOGDIR}/1_all
    [ -d ${LOGDIR}/2_max/failed ] || mkdir -p ${LOGDIR}/2_max/failed
    [ -d ${LOGDIR}/3_min/failed ] || mkdir -p ${LOGDIR}/3_min/failed

    for f in dependency-changes.error.log dependency-changes.warn.log \
             failed-recipes.${MACHINE} failed-recipes.log 1_all/complete.log \
             1_all/failed-tasks.log 1_all/failed-recipes.log \
             2_max/failed-tasks.log 2_max/failed-recipes.log \
             3_min/failed-tasks.log 3_min/failed-recipes.log; do
        [ -f ${OUTPUT}/${f} ] && cp -l ${OUTPUT}/${f} ${LOGDIR}/${f}
    done

    ls ${OUTPUT}/2_max/failed/*.log >/dev/null 2>/dev/null && cp -l ${OUTPUT}/2_max/failed/*.log ${LOGDIR}/2_max/failed
    ls ${OUTPUT}/3_min/failed/*.log >/dev/null 2>/dev/null && cp -l ${OUTPUT}/3_min/failed/*.log ${LOGDIR}/3_min/failed

    cp conf/local.conf ${LOGDIR}
    rsync -avir ${LOGDIR} ${LOG_RSYNC_DIR}
    [ -s ${LOGDIR}/qa.log ] && cat ${LOGDIR}/qa.log

    report_error

    # wait for pseudo
    sleep 180
    umount build/tmpfs || echo "Umounting tmpfs failed"
    rm -rf build/tmpfs/*;

    exit ${RESULT}
}

function run_rsync {
    cd ${BUILD_TOPDIR}/..
    rsync -avir --no-links --exclude '*.done' --exclude git2 --exclude hg \
          --exclude svn --exclude bzr downloads/ \
          jenkins@milla.nas-admin.org:~/htdocs/oe-sources
}
function run_parse-results {
    cd ${BUILD_TOPDIR}
    if [ -z "${BUILD_LOG_WORLD_DIRS}" ] ; then
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} BUILD_LOG_WORLD_DIRS is empty, it should contain 3 log.world.qemu*.20*.log directories for qemuarm, qemuarm64, qemux86, qemux86-64 logs (in this order), then log.signatures.20*. Or 'LATEST' to take 4 newest ones."
        exit 1
    fi
    # first we need to "import" qemux86 and qemux86-64 reports from kwaj
    rsync -avir --delete ../kwaj/yoe/log.world.qemux86*.20* .

    if [ "${BUILD_LOG_WORLD_DIRS}" = "LATEST" ] ; then
        BUILD_LOG_WORLD_DIRS=""
        for M in qemuarm qemuarm64 qemux86 qemux86-64; do
            BUILD_LOG_WORLD_DIRS="${BUILD_LOG_WORLD_DIRS} `ls -d log.world.${M}.20*.log/ | sort | tail -n 1`"
        done
        BUILD_LOG_WORLD_DIRS="${BUILD_LOG_WORLD_DIRS} `ls -d log.signatures.20*.log/ | sort | tail -n 1`"
    fi
    LOG=log.report.`date "+%Y%m%d_%H%M%S"`.log
    show-failed-tasks ${BUILD_LOG_WORLD_DIRS} 2>&1 | tee $LOG
    rsync -avir ${LOG} ${LOG_RSYNC_DIR}
}

function show-pnblacklists {
    cd ${BUILD_TOPDIR}
    echo "PNBLACKLISTs:";
    for i in openembedded-core/ meta-*; do
        cd sources/$i;
        echo "$i:";
        git grep '^PNBLACKLIST\[.*=' . | tee;
        cd ../..;
    done | grep -v bec.conf | grep -v documentation.conf;
    grep ^PNBLACKLIST conf/local.conf
}

function show-qa-issues {
    echo "QA issues by type:"
    for t in ${BUILD_QA_ISSUES}; do
        count=`cat $qemuarm/qa.log $qemuarm64/qa.log $qemux86/qa.log $qemux86_64/qa.log | sort -u | grep "\[$t\]" | wc -l`;
        printf "count: $count\tissue: $t\n";
        cat $qemuarm/qa.log $qemuarm64/qa.log $qemux86/qa.log $qemux86_64/qa.log | sort -u | grep "\[$t\]" | sed "s#${BUILD_TOPDIR}/build/tmpfs/#/tmp/#g";
        echo; echo;
    done
}

function show-failed-tasks {
    if [ $# -ne 5 ] ; then
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} show-failed-tasks needs 4 params: dir-qemuarm dir-qemuarm64 dir-qemux86 dir-qemux86_64 dir-signatures"
        exit 1
    fi

    qemuarm=$1
    qemuarm64=$2
    qemux86=$3
    qemux86_64=$4
    test_signatures=$5

    machines="qemuarm qemuarm64 qemux86 qemux86_64"

    for M in $machines; do
        log=$(eval echo "\$${M}")/bitbake.log
        MM=${M/_/-}
        echo $log
        if ! grep "^MACHINE           *= \"${MM}\"" ${log}; then
            echo "ERROR: log $log, isn't for MACHINE ${M}"
            exit 1
        fi
    done

    DATE=`echo ${qemux86_64} | sed 's/^log.world.qemux86-64.\(....\)\(..\)\(..\)_.......log.*$/\1-\2-\3/g'`

    TMPDIR=`mktemp -d`
    for M in $machines; do
        log=$(eval echo "\$${M}")/bitbake.log
        grep "^  \(\|\(virtual:[^:]*:\)\)${BUILD_TOPDIR}/" ${log} | sed "s#^  ##g;s#${BUILD_TOPDIR}/##g;" > $TMPDIR/$M
    done

    cat $TMPDIR/* | sort -u > $TMPDIR/all

    cat $TMPDIR/all | while read F; do
        #  echo "^${F}"
        if grep -q "^${F}" $TMPDIR/qemuarm && grep -q "^${F}" $TMPDIR/qemuarm64 && grep -q "^${F}" $TMPDIR/qemux86 && grep -q "^${F}" $TMPDIR/qemux86_64 ; then
            echo "    * $F" >> $TMPDIR/common
        elif grep -q "^${F}" $TMPDIR/qemux86 && grep -q "^${F}" $TMPDIR/qemux86_64 ; then
            echo "    * $F" >> $TMPDIR/common-x86
        elif grep -q "^${F}" $TMPDIR/qemuarm; then
            echo "    * $F" >> $TMPDIR/common-qemuarm
        elif grep -q "^${F}" $TMPDIR/qemuarm64; then
            echo "    * $F" >> $TMPDIR/common-qemuarm64
        elif grep -q "^${F}" $TMPDIR/qemux86; then
            echo "    * $F" >> $TMPDIR/common-qemux86
        elif grep -q "^${F}" $TMPDIR/qemux86_64; then
            echo "    * $F" >> $TMPDIR/common-qemux86_64
        fi
    done

    printf "\n==================== REPORT START ================== \n"

    printf "\nhttp://www.openembedded.org/wiki/Bitbake_World_Status\n"

    printf "\n== Number of issues - stats ==\n"
    printf "{| class='wikitable'\n"
    printf "!|Date\t\t     !!colspan='4'|Failed tasks\t\t\t    !!|Signatures\t\t  !!colspan='`echo "${BUILD_QA_ISSUES}" | wc -w`'|QA !!Comment\n"
    printf "|-\n"
    printf "||\t\t"
    for M in $machines; do
        printf "||$M\t"
    done
    printf "||all \t"
    for I in ${BUILD_QA_ISSUES}; do
        printf "||$I\t"
    done
    printf "||\t\n|-\n||${DATE}\t"
    for M in $machines; do
        COUNT=`cat $TMPDIR/${M} | wc -l`
        printf "||${COUNT}\t"
    done
    COUNT=`cat ${test_signatures}/signatures.log | grep "^ERROR:.* issues were found in" | sed 's/^ERROR: \(.*\) issues were found in.*$/\1/g'`
    [ -z "${COUNT}" ] && COUNT="0"
    printf "||${COUNT}\t"

    for I in ${BUILD_QA_ISSUES}; do
        COUNT=`show-qa-issues | grep "count:.*issue: ${I}" | sed "s/.*count: //g; s/ *issue: ${I} *$//g; s/\n//g"`
        printf "||${COUNT}\t"
    done
    printf "||\t\n|}\n"

    printf "\n== Failed tasks ${DATE} ==\n"
    printf "\nINFO: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Complete log available at ${LOG_HTTP_ROOT}${LOG}\n"
    printf "\n=== common (`cat $TMPDIR/common 2>/dev/null | wc -l`) ===\n"; cat $TMPDIR/common 2>/dev/null
    printf "\n=== common-x86 (`cat $TMPDIR/common-x86 2>/dev/null | wc -l`) ===\n"; cat $TMPDIR/common-x86 2>/dev/null
    for M in $machines; do
        printf "\n=== $M (`cat $TMPDIR/common-$M 2>/dev/null | wc -l`) ===\n"; cat $TMPDIR/common-$M 2>/dev/null
    done

    issues_all=0
    for M in $machines; do
        issues=`cat $TMPDIR/${M} | wc -l`
        issues_all=`expr ${issues_all} + ${issues}`
    done

    printf "\n=== Number of failed tasks (${issues_all}) ===\n"
    printf '{| class='wikitable'\n'
    for M in $machines; do
        log=${LOG_HTTP_ROOT}$(eval echo "\$${M}")
        log_file=$(eval echo "\$${M}")bitbake.log
        link=`grep http://errors.yocto $log_file | sed 's@.*http://@http://@g'`
        printf "|-\n|| $M \t|| `cat $TMPDIR/${M} | wc -l`\t || $log || $link\n"
    done
    printf "|}\n"

    rm -rf $TMPDIR

    printf "\n=== PNBLACKLISTs (`show-pnblacklists | grep ':PNBLACKLIST\[' | wc -l`) ===\n"

    printf "\n=== QA issues (`show-qa-issues | grep ".*:.*\[.*\]$" | wc -l`) ===\n"
    printf '{| class='wikitable'\n'
    printf "!| Count\t	||Issue\n"
    show-qa-issues | grep "^count: " | sort -h | sed 's/count: /|-\n||/g; s/issue: /||/g'
    printf "|}\n"

    echo; echo;
    show-failed-signatures ${test_signatures} ${LOG_HTTP_ROOT}

    echo; echo;
    show-pnblacklists

    echo; echo;
    show-qa-issues

    echo
    echo "This git log matches with the metadata as seen by qemuarm build."
    echo "In some cases qemux86 and qemux86-64 builds are built with slightly"
    echo "different metadata, you can see the exact version near the top of each"
    echo "log.world.qemu* files linked from the report"
    show-git-log

    printf "\n==================== REPORT STOP ================== \n"
}

function show-git-log() {
    BRANCH=HEAD
    pushd ${PWD}
    for i in bitbake openembedded-core meta-openembedded meta-qt5 meta-browser; do
        printf "\n== Tested changes (not included in master yet) - $i ==\n"
        cd sources/$i;
        COUNT=`git log --oneline origin/master..${BRANCH} | wc -l`
        echo "latest upstream commit: "
        git log --oneline --reverse -`expr ${COUNT} + 1` ${BRANCH} | head -n 1
        echo "not included in master yet: "
        git log --oneline --reverse -${COUNT} ${BRANCH}
        cd ../..;
    done
    popd
}

function show-failed-signatures() {
    COUNT=`cat ${1}/signatures.log | grep "^ERROR:.* issues were found in" | sed 's/^ERROR: \(.*\) issues were found in.*$/\1/g'`
    [ -z "${COUNT}" ] && COUNT="0"
    printf "\n=== Incorrect PACKAGE_ARCH or sstate signatures (${COUNT}) ===\n"
    printf "\nComplete log: $2$1\n"
    if grep -q ERROR: $1/signatures.log; then
        grep "^ERROR:.* issues were found in" $1/signatures.log | sed 's/^/    * /g'
        echo
        grep "^ERROR:.* errors found in" $1/signatures.log | sed 's#/home.*signatures.qemu#signatures.qemu#g' | sed 's/^/    * /g'
        echo
        grep "^ERROR:" $1/signatures.log | sed 's/^/    * /g'
    else
        printf "\nNo issues detected\n"
    fi
}

print_timestamp start
parse_job_name
sanity_check_workspace

echo "INFO: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Running: '${BUILD_TYPE}', machine: '${BUILD_MACHINE}', version: '${BUILD_VERSION}'"

# restrict it to 20GB to prevent triggering OOM killer on our jenkins server (which can kill some other
# process instead of the build itself)
ulimit -v 20971520
ulimit -m 20971520

case ${BUILD_TYPE} in
    cleanup)
        run_cleanup
        ;;
    compare-signatures)
        run_compare-signatures
        ;;
    prepare)
        run_prepare
        ;;
    rsync)
        run_rsync
        ;;
    test-dependencies)
        run_test-dependencies
        ;;
    build)
        run_build
        ;;
    kill-stalled)
        kill_stalled_bitbake_processes
        ;;
    parse-results)
        run_parse-results
        ;;
    *)
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Unrecognized build type: '${BUILD_TYPE}', script doesn't know how to execute such job"
        exit 1
        ;;
esac
