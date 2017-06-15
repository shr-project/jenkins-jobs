#!/bin/bash

BUILD_SCRIPT_VERSION="1.8.23"
BUILD_SCRIPT_NAME=`basename ${0}`

# These are used by in following functions, declare them here so that
# they are defined even when we're only sourcing this script
BUILD_TIME_STR="TIME: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} %e %S %U %P %c %w %R %F %M %x %C"

BUILD_TIMESTAMP_START=`date -u +%s`
BUILD_TIMESTAMP_OLD=${BUILD_TIMESTAMP_START}

pushd `dirname $0` > /dev/null
BUILD_WORKSPACE=`pwd -P`
popd > /dev/null

BUILD_DIR="shr-core"
BUILD_TOPDIR="${BUILD_WORKSPACE}/${BUILD_DIR}"
BUILD_TIME_LOG=${BUILD_TOPDIR}/time.txt

LOG_RSYNC_DIR="jenkins@logs.nslu2-linux.org:htdocs/buildlogs/oe/world/rocko"
LOG_HTTP_ROOT="http://logs.nslu2-linux.org/buildlogs/oe/world/rocko/"

BUILD_QA_ISSUES="already-stripped libdir textrel build-deps file-rdeps version-going-backwards host-user-contaminated installed-vs-shipped unknown-configure-option symlink-to-sysroot invalid-pkgconfig pkgname ldflags compile-host-path"

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
            echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Unrecognized machine in JOB_NAME: '${JOB_NAME}', it should end with '_qemuarm', '_qemux86', '_qemux86-64'"
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
    if ps aux | grep "${BUILD_TOPDIR}/bitbake/bin/[b]itbake"; then
        if [ "${BUILD_TYPE}" = "kill-stalled" ] ; then
            echo "WARN: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} There is some bitbake process already running from '${BUILD_TOPDIR}', maybe some stalled process from aborted job?"
        else
            echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} There is some bitbake process already running from '${BUILD_TOPDIR}', maybe some stalled process from aborted job?"
            exit 1
        fi
    fi
}

function kill_stalled_bitbake_processes {
    if ps aux | grep "${BUILD_TOPDIR}/bitbake/bin/[b]itbake" ; then
        local BITBAKE_PIDS=`ps aux | grep "${BUILD_TOPDIR}/bitbake/bin/[b]itbake" | awk '{print $2}' | xargs`
        [ -n "${BITBAKE_PIDS}" ] && kill ${BITBAKE_PIDS}
        sleep 10
        ps aux | grep "${BUILD_TOPDIR}/bitbake/bin/[b]itbake"
        local BITBAKE_PIDS=`ps aux | grep "${BUILD_TOPDIR}/bitbake/bin/[b]itbake" | awk '{print $2}' | xargs`
        [ -n "${BITBAKE_PIDS}" ] && kill -9 ${BITBAKE_PIDS}
        ps aux | grep "${BUILD_TOPDIR}/bitbake/bin/[b]itbake" || true
    fi
}

function run_build {
    declare -i RESULT=0

    make update 2>&1
    cd ${BUILD_TOPDIR}
    export LC_ALL=en_US.utf8
    . ./setup-env
    export MACHINE=${BUILD_MACHINE}
    LOGDIR=log.world.${MACHINE}.`date "+%Y%m%d_%H%M%S"`.log
    mkdir ${LOGDIR}
    [ -d tmp-glibc ] && rm -rf tmp-glibc/*;
    [ -d tmp-glibc ] || mkdir tmp-glibc
    mount | grep "${BUILD_TOPDIR}/tmp-glibc type tmpfs" && echo "Some tmp-glibc already has tmpfs mounted, skipping mount" || mount tmp-glibc
    sanity-check
    time bitbake -k virtual/kernel  2>&1 | tee -a ${LOGDIR}/bitbake.log || break;
    if [ "${BUILD_MACHINE}" = "qemux86" -o "${BUILD_MACHINE}" = "qemux86-64" ] ; then
        time bitbake -k chromium  2>&1 | tee -a ${LOGDIR}/bitbake.log || break;
        time bitbake -k chromium-wayland  2>&1 | tee -a ${LOGDIR}/bitbake.log || break;
    fi
    time bitbake -k world  2>&1 | tee -a ${LOGDIR}/bitbake.log || break;
    RESULT+=${PIPESTATUS[0]}
    cat tmp-glibc/qa.log >> ${LOGDIR}/qa.log || echo "No QA issues";

    cp conf/world* ${LOGDIR}
    rsync -avir ${LOGDIR} ${LOG_RSYNC_DIR}
    cat ${LOGDIR}/qa.log && true

    cat << EOF > sstate-sysroot-cruft-whitelist.txt
[^/]*/home/builder
[^/]*/usr/src/kernel/.*
[^/]*/usr/lib/gdk-pixbuf-2.0/.*/loaders.cache
[^/]*/etc/sgml/sgml-docbook.cat
[^/]*/usr/src/kernel/patches
[^/]*/etc/sgml/sgml-docbook.cat
[^/]*/usr/lib/python3.3/__pycache__
[^/]*/usr/lib/python3.3/[^/]*/__pycache__
[^/]*/usr/lib/python3.3/[^/]*/[^/]*/__pycache__
[^/]*/usr/share/dbus
[^/]*/usr/share/dbus/dbus-bus-introspect.xml
[^/]*/usr/share/dbus/session.conf
[^/]*/usr/bin/crossscripts/guile-config
[^/]*/usr/lib/python2.7/config/libpython2.7.so
[^/]*/var
[^/]*/usr/bin/i586-oe-linux-g77
[^/]*/usr/bin/x86_64-oe-linux-g77
[^/]*/usr/bin/arm-oe-linux-gnueabi-g77
[^/]*/usr/lib/php/\.channels.*
[^/]*/usr/lib/php/\.registry.*
[^/]*/usr/lib/php/\.depdb.*
[^/]*/usr/lib/php/\.filemap
[^/]*/usr/lib/php/\.lock
[^/]*/usr/lib/gdk-pixbuf-2.0/.*/loaders.cache
[^/]*/usr/include/ruby-1.9.1/i386-linux
[^/]*/usr/include/ruby-1.9.1/i386-linux/ruby
[^/]*/usr/include/ruby-1.9.1/i386-linux/ruby/config.h
[^/]*/usr/include/ruby-1.9.1/ruby/win32.h
[^/]*/usr/lib/ruby/i386-linux
[^/]*/usr/lib/ruby/i386-linux/fake.rb
[^/]*/usr/lib/ruby/i386-linux/libruby.so.1.9.1
[^/]*/usr/lib/ruby/i386-linux/libruby-static.a
[^/]*/usr/lib/ruby/i386-linux/rbconfig.rb
[^/]*/usr/lib/qt4/plugins
[^/]*/usr/lib/qt4/plugins/webkit
[^/]*/usr/lib/qt5/plugins/webkit
EOF

    mkdir ${LOGDIR}/sysroot-cruft/
    openembedded-core/scripts/sstate-sysroot-cruft.sh --tmpdir=tmp-glibc --whitelist=sstate-sysroot-cruft-whitelist.txt 2>&1 | tee ${LOGDIR}/sysroot-cruft/sstate-sysroot-cruft.log
    RESULT+=${PIPESTATUS[0]}

    OUTPUT2=`grep "INFO: Output written in: " ${LOGDIR}/sysroot-cruft/sstate-sysroot-cruft.log | sed 's/INFO: Output written in: //g'`
    ls   ${OUTPUT2}/diff* ${OUTPUT2}/used.whitelist.txt ${OUTPUT2}/duplicates.txt >/dev/null 2>/dev/null && \
      cp ${OUTPUT2}/diff* ${OUTPUT2}/used.whitelist.txt ${OUTPUT2}/duplicates.txt ${LOGDIR}/sysroot-cruft/

    # wait for pseudo
    sleep 180
    umount tmp-glibc || echo "Umounting tmp-glibc failed"
    rm -rf tmp-glibc/*;

    exit ${RESULT}
}

function sanity-check {
    # check that tmpfs is mounted and has enough space
    if ! mount | grep -q "${BUILD_TOPDIR}/tmp-glibc type tmpfs"; then
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} tmpfs isn't mounted in ${BUILD_TOPDIR}/tmp-glibc"
        exit 1
    fi
    local available_tmpfs=`df -BG ${BUILD_TOPDIR}/tmp-glibc | grep ${BUILD_TOPDIR}/tmp-glibc | awk '{print $4}' | sed 's/G$//g'`
    if [ "${available_tmpfs}" -lt 15 ] ; then
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} tmpfs mounted in ${BUILD_TOPDIR}/tmp-glibc has less than 15G free"
        exit 1
    fi
    local tmpfs tmpfs_allocated_all=0
    for tmpfs in `mount | grep "tmp-glibc type tmpfs" | awk '{print $3}'`; do
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
    if [ -d ${BUILD_TOPDIR} ] ; then
        cd ${BUILD_TOPDIR};
        du -hs sstate-cache
        echo -n "number of openssl archives: " && find sstate-cache -name \*openssl\*populate_sysroot\*tgz | grep -v python-pyopenssl | grep -v python-native | wc -l
        openembedded-core/scripts/sstate-cache-management.sh --extra-archs=core2-64,i586,armv5te,qemuarm,qemux86,qemux86_64 -L --cache-dir=sstate-cache -d -y || true
        echo -n "number of openssl archives: " && find sstate-cache -name \*openssl\*populate_sysroot\*tgz | grep -v python-pyopenssl | grep -v python-native | wc -l
        find sstate-cache -name \*openssl\*populate_sysroot\*tgz | grep -v python-pyopenssl | grep -v python-native
        du -hs sstate-cache
        mkdir old || true
        umount tmp-glibc || true
        mv -f cache/bb_codeparser.dat* bitbake.lock pseudodone tmp-glibc* old || true
        rm -rf old
    fi
    echo "Cleanup finished"
}

function run_compare-signatures {
    declare -i RESULT=0

    cd ${BUILD_TOPDIR}
    export LC_ALL=en_US.utf8
    . ./setup-env

    LOGDIR=log.signatures.`date "+%Y%m%d_%H%M%S"`.log
    mkdir ${LOGDIR}
    rm -rf tmp-glibc/*;
    mount | grep "tmp-glibc type tmpfs" && echo "Some tmp-glibc already has tmpfs mounted, skipping mount" || mount tmp-glibc

    openembedded-core/scripts/sstate-diff-machines.sh --machines="qemux86copy qemux86 qemuarm" --targets=world --tmpdir=tmp-glibc/ --analyze 2>&1 | tee ${LOGDIR}/signatures.log
    RESULT+=${PIPESTATUS[0]}

    OUTPUT=`grep "INFO: Output written in: " ${LOGDIR}/signatures.log | sed 's/INFO: Output written in: //g'`
    ls ${OUTPUT}/signatures.*.*.log >/dev/null 2>/dev/null && cp ${OUTPUT}/signatures.*.*.log ${LOGDIR}/

    rsync -avir ${LOGDIR} ${LOG_RSYNC_DIR}

    [ -d sstate-diff ] || mkdir sstate-diff
    mv tmp-glibc/sstate-diff/* sstate-diff

    umount tmp-glibc || echo "Umounting tmp-glibc failed"
    rm -rf tmp-glibc/*;

    exit ${RESULT}
}

function run_prepare {
    [ -f Makefile ] && echo "Makefile exists (ok)" || wget http://shr.bearstech.com/Makefile
    sed -i 's#BRANCH_COMMON = .*#BRANCH_COMMON = jansa/master-all#g' Makefile

    make update-common

    echo "UPDATE_CONFFILES_ENABLED = 1" > config.mk
    echo "RESET_ENABLED = 1" >> config.mk
    [ -d ${BUILD_TOPDIR} ] && echo "${BUILD_DIR} already checked out (ok)" || make setup-shr-core 2>&1
    make update-conffiles 2>&1

    cp common/conf/local.conf ${BUILD_TOPDIR}/conf/local.conf
    sed -i 's/#PARALLEL_MAKE.*/PARALLEL_MAKE = "-j 22"/'          ${BUILD_TOPDIR}/conf/local.conf
    sed -i 's/#BB_NUMBER_THREADS.*/BB_NUMBER_THREADS = "3"/'     ${BUILD_TOPDIR}/conf/local.conf
    sed -i 's/# INHERIT += "rm_work"/INHERIT += "rm_work"/'      ${BUILD_TOPDIR}/conf/local.conf

    # Reminder to change it later when we have public instance
    sed -i 's/PRSERV_HOST = "localhost:0"/PRSERV_HOST = "localhost:0"/' ${BUILD_TOPDIR}/conf/local.conf

    echo 'BB_GENERATE_MIRROR_TARBALLS = "1"'                  >> ${BUILD_TOPDIR}/conf/local.conf
    if [ ! -d ${BUILD_TOPDIR}/buildhistory/ ] ; then
        cd ${BUILD_TOPDIR}/
        git clone git@github.com:shr-project/jenkins-buildhistory.git buildhistory
        cd buildhistory;
        git checkout -b oe-world origin/oe-world || git checkout -b oe-world
        cd ../..
    fi

    echo 'BUILDHISTORY_DIR = "${TOPDIR}/buildhistory"'                           >> ${BUILD_TOPDIR}/conf/local.conf
    echo 'BUILDHISTORY_COMMIT ?= "1"'                                            >> ${BUILD_TOPDIR}/conf/local.conf
    echo 'BUILDHISTORY_COMMIT_AUTHOR ?= "Martin Jansa <Martin.Jansa@gmail.com>"' >> ${BUILD_TOPDIR}/conf/local.conf
    echo 'BUILDHISTORY_PUSH_REPO ?= "origin oe-world"'          >> ${BUILD_TOPDIR}/conf/local.conf
    sed 's/^DISTRO/#DISTRO/g' -i ${BUILD_TOPDIR}/setup-local

    echo 'require conf/distro/include/no-static-libs.inc' >> ${BUILD_TOPDIR}/conf/local.conf
    cat >> ${BUILD_TOPDIR}/conf/local.conf << EOF
# Backport following 9 changes from Yocto 2.4 Rocko and enable reproducible binaries
# j=1; for i in 139554 139558 139556 139555 139557 139559 139599 139600 139999; do wget https://patchwork.openembedded.org/patch/$i/mbox/ -O pw-am-$j-$i.patch; j=`expr $j + 1`; done
BUILD_REPRODUCIBLE_BINARIES = "1"
REPRODUCIBLE_TIMESTAMP_ROOTFS = "1493072213"
REPRODUCIBLE_TIMESTAMP_IMAGE_PRELINK = "1493072213"
EOF

    echo 'require world_fixes.inc' >> ${BUILD_TOPDIR}/conf/local.conf
    cat > ${BUILD_TOPDIR}/conf/world_fixes.inc << EOF
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
PREFERRED_PROVIDER_e-wm-sysactions = "e-wm"
ESYSACTIONS = "e-wm-sysactions"

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
# now set with gles2 in meta-webos-ports/meta-luneui/recipes-qt/qt5/qtbase_git.bbappend
# PACKAGECONFIG_append_pn-qtbase = " icu gl accessibility"
PACKAGECONFIG_append_pn-qtbase = " freetype fontconfig"

# qtwayland doesn't like egl and xcomposite-glx enabled at the same time
# http://lists.openembedded.org/pipermail/openembedded-devel/2016-December/110444.html
PACKAGECONFIG_remove_pn-qtwayland = "xcomposite-egl xcomposite-glx"

# for webkit-efl
PACKAGECONFIG_append_pn-harfbuzz = " icu"

inherit blacklist
# PNBLACKLIST[samsung-rfs-mgr] = "needs newer libsamsung-ipc with negative D_P: Requested 'samsung-ipc-1.0 >= 0.2' but version of libsamsung-ipc is 0.1.0"
PNBLACKLIST[android-system] = "depends on lxc from meta-virtualiazation which isn't included in my world builds"
PNBLACKLIST[bigbuckbunny-1080p] = "big and doesn't really need to be tested so much"
PNBLACKLIST[bigbuckbunny-480p] = "big and doesn't really need to be tested so much"
PNBLACKLIST[bigbuckbunny-720p] = "big and doesn't really need to be tested so much"
PNBLACKLIST[bigbuckbunny-720p] = "big and doesn't really need to be tested so much"
PNBLACKLIST[tearsofsteel-1080p] = "big and doesn't really need to be tested so much"
PNBLACKLIST[build-appliance-image] = "tries to include whole downloads directory in /home/builder/poky :/"

PNBLACKLIST[linux-yocto-tiny-kexecboot] = "does weird sh!t breaking other kernels and modules - broken for years"
PNBLACKLIST[linux-yocto-tiny] = "does weird sh!t breaking other kernels and modules - broken for years"

# enable reporting
# needs http://patchwork.openembedded.org/patch/68735/
ERR_REPORT_SERVER = "errors.yoctoproject.org"
ERR_REPORT_PORT = "80"
ERR_REPORT_USERNAME = "Martin Jansa"
ERR_REPORT_EMAIL = "Martin.Jansa@gmail.com"
ERR_REPORT_UPLOAD_FAILURES = "1"
INHERIT += "report-error"

# needs patch with buildstats-summary.bbclass
INHERIT += "buildstats buildstats-summary"

# enable thumb for broader test coverage (oe-core autobuilder doesn't have thumb enabled)
PREFERRED_ARM_INSTRUCTION_SET              ?= "thumb"
ARM_INSTRUCTION_SET = "\${PREFERRED_ARM_INSTRUCTION_SET}"
EOF
}

function run_test-dependencies {
    declare -i RESULT=0

    make update 2>&1
    cd ${BUILD_TOPDIR}
    export LC_ALL=en_US.utf8
    . ./setup-env

    export MACHINE=${BUILD_MACHINE}
    LOGDIR=log.dependencies.${MACHINE}.`date "+%Y%m%d_%H%M%S"`.log
    mkdir ${LOGDIR}

    rm -rf tmp-glibc/*;
    [ -d tmp-glibc ] || mkdir tmp-glibc
    mount | grep "${BUILD_TOPDIR}/tmp-glibc type tmpfs" && echo "Some tmp-glibc already has tmpfs mounted, skipping mount" || mount tmp-glibc

    [ -f failed-recipes.${MACHINE} ] || bitbake-layers show-recipes | grep '^[^ ].*:' | grep -v '^=' | sed 's/:$//g' | sort -u > failed-recipes.${MACHINE}
    [ -f failed-recipes.${MACHINE} ] && RECIPES="--recipes=failed-recipes.${MACHINE}"

    # backup full buildhistory and replace it with link to tmpfs
    mv buildhistory buildhistory-all
    mkdir tmp-glibc/buildhistory
    ln -s tmp-glibc/buildhistory .

    rm -f tmp-glibc/qa.log

    time openembedded-core/scripts/test-dependencies.sh --tmpdir=tmp-glibc $RECIPES 2>&1 | tee -a ${LOGDIR}/test-dependencies.log
    RESULT+=${PIPESTATUS[0]}

    # restore full buildhistory
    rm -rf buildhistory
    mv buildhistory-all buildhistory

    cat tmp-glibc/qa.log >> ${LOGDIR}/qa.log 2>/dev/null || echo "No QA issues";

    OUTPUT=`grep "INFO: Output written in: " ${LOGDIR}/test-dependencies.log | sed 's/INFO: Output written in: //g'`

    # we want to preserve only partial artifacts
    [ -d ${LOGDIR}/1_all ] || mkdir -p ${LOGDIR}/1_all
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

    cp conf/world* ${LOGDIR}
    rsync -avir ${LOGDIR} ${LOG_RSYNC_DIR}
    [ -s ${LOGDIR}/qa.log ] && cat ${LOGDIR}/qa.log

    # wait for pseudo
    sleep 180
    umount tmp-glibc || echo "Umounting tmp-glibc failed"
    rm -rf tmp-glibc/*;

    exit ${RESULT}
}

function run_rsync {
    cd ${BUILD_TOPDIR}/..
    rsync -avir --no-links --exclude '*.done' --exclude git2 --exclude hg \
                           --exclude svn --exclude bzr downloads/      jenkins@milla.nao:~/htdocs/oe-sources
}
function run_parse-results {
    cd ${BUILD_TOPDIR}
    if [ -z "${BUILD_LOG_WORLD_DIRS}" ] ; then
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} BUILD_LOG_WORLD_DIRS is empty, it should contain 3 log.world.qemu*.20*.log directories for qemuarm, qemux86, qemux86-64 logs (in this order), then log.signatures.20*. Or 'LATEST' to take 4 newest ones."
        exit 1
    fi
    # first we need to "import" qemux86 and qemux86-64 reports from kwaj
    rsync -avir --delete ../kwaj/shr-core/log.world.qemux86*.20* .

    if [ "${BUILD_LOG_WORLD_DIRS}" = "LATEST" ] ; then
        BUILD_LOG_WORLD_DIRS=""
        for M in qemuarm qemux86 qemux86-64; do
            BUILD_LOG_WORLD_DIRS="${BUILD_LOG_WORLD_DIRS} `ls -d log.world.${M}.20*.log/ | sort | tail -n 1`"
        done
        BUILD_LOG_WORLD_DIRS="${BUILD_LOG_WORLD_DIRS} `ls -d log.signatures.20*.log/ | sort | tail -n 1`"
    fi
    LOG=log.report.`date "+%Y%m%d_%H%M%S"`.log
    show-failed-tasks ${BUILD_LOG_WORLD_DIRS} 2>&1 | tee $LOG
    rsync -avir ${LOG} ${LOG_RSYNC_DIR}
}

function show-pnblacklists {
    echo "PNBLACKLISTs:";
    for i in openembedded-core/ meta-*; do
        cd $i;
        echo "$i:";
        git grep '^PNBLACKLIST\[.*=' . | tee;
        cd ..;
    done | grep -v shr.conf | grep -v documentation.conf | grep -v luneos-recipe-blacklist-world.inc | grep -v luneos-recipe-blacklist.inc;
    grep ^PNBLACKLIST conf/world_*
}

function show-qa-issues {
    echo "QA issues by type:"
    for t in ${BUILD_QA_ISSUES}; do
        count=`cat $qemuarm/qa.log $qemux86/qa.log $qemux86_64/qa.log | sort -u | grep "\[$t\]" | wc -l`;
        printf "count: $count\tissue: $t\n";
        cat $qemuarm/qa.log $qemux86/qa.log $qemux86_64/qa.log | sort -u | grep "\[$t\]" | sed "s#${BUILD_TOPDIR}/tmp-glibc/#/tmp/#g";
        echo; echo;
    done
}

function show-failed-tasks {
    if [ $# -ne 4 ] ; then
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} show-failed-tasks needs 4 params: dir-qemuarm dir-qemux86 dir-qemux86_64 dir-signatures"
        exit 1
    fi

    qemuarm=$1
    qemux86=$2
    qemux86_64=$3
    test_signatures=$4

    machines="qemuarm qemux86 qemux86_64"

    for M in $machines; do
        log=$(eval echo "\$${M}")/bitbake.log
        MM=${M/_/-}
        echo $log
        if ! grep "^MACHINE           = \"${MM}\"" ${log}; then
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
        if grep -q "^${F}" $TMPDIR/qemuarm && grep -q "^${F}" $TMPDIR/qemux86 && grep -q "^${F}" $TMPDIR/qemux86_64 ; then
            echo "    * $F" >> $TMPDIR/common
        elif grep -q "^${F}" $TMPDIR/qemux86 && grep -q "^${F}" $TMPDIR/qemux86_64 ; then
            echo "    * $F" >> $TMPDIR/common-x86
        elif grep -q "^${F}" $TMPDIR/qemuarm; then
            echo "    * $F" >> $TMPDIR/common-qemuarm
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
    printf "!|Date\t\t     !!colspan='3'|Failed tasks\t\t\t    !!|Signatures\t\t  !!colspan='`echo "${BUILD_QA_ISSUES}" | wc -w`'|QA !!Comment\n"
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

    for i in bitbake openembedded-core meta-openembedded meta-qt5 meta-browser meta-webos-ports meta-smartphone; do
        printf "\n== Tested changes (not included in master yet) - $i ==\n"
        cd $i;
        git remote update up >/dev/null 2>/dev/null
        COUNT=`git log --oneline up/master..jansa/master | wc -l`
        echo "latest upstream commit: "
        git log --oneline --reverse -`expr ${COUNT} + 1` jansa/master | head -n 1
        echo "not included in master yet: "
        git log --oneline --reverse -${COUNT} jansa/master
        cd ..;
    done
    printf "\n==================== REPORT STOP ================== \n"
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
