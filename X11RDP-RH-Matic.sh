#! /bin/bash

trap user_interrupt_exit 2

if [ $UID -eq 0 ] ; then
	# write to stderr 1>&2
	echo "${0}:  Never run this utility as root." 1>&2
	echo 1>&2
	echo "This utility builds RPMs. Building RPM's as root is seriously dangerous." 1>&2
	exit 1
fi

# Check if an rpm package is installed.
# If not, exit with an error message.
check_rpm_installed()
{
	rpm -q --whatprovides $1 || exit 1
}

LINE="----------------------------------------------------------------------"

PATH=/bin:/sbin:/usr/bin:/usr/sbin

# xrdp repository
GH_ACCOUNT=proski
GH_PROJECT=xrdp
GH_BRANCH=devel
GH_URL=https://github.com/${GH_ACCOUNT}/${GH_PROJECT}.git

TAG=$(date '+%F__%T' | sed 's/\W/_/g')
WRKDIR=$(pwd)/build.$TAG
BUILD_LOG=${WRKDIR}/build.log
RPMS_DIR=$(rpm --eval %{_rpmdir}/%{_arch})
BUILD_DIR=$(rpm --eval %{_builddir})
SOURCE_DIR=$(rpm --eval %{_sourcedir})
X11RDPBASE=$(pwd)/x11rdp.$TAG

mkdir -p $WRKDIR

# variables for this utility
META_DEPENDS="rpm-build rpmdevtools"
FETCH_DEPENDS="ca-certificates git wget"
EXTRA_SOURCE="xrdp.init xrdp.sysconfig xrdp.logrotate xrdp-pam-auth.patch buildx_patch.diff x11_file_list.patch sesman.ini.master.patch sesman.ini.devel.patch"

# flags
PARALLELMAKE=true   # increase make jobs
GIT_USE_HTTPS=true  # Use firewall-friendly https:// instead of git:// to fetch git submodules

# x11rdp
X11RDP_BUILD_DEPENDS=$(<SPECS/x11rdp.spec.in grep BuildRequires: | awk '{ print $2 }' | tr '\n' ' ')

echo_stderr()
{
	echo $@ 1>&2
}

error_exit()
{
	echo_stderr; echo_stderr
	echo_stderr "Oops, something going wrong around line: $BASH_LINENO"
	echo_stderr "See logs to get further information:"
	echo_stderr "	$BUILD_LOG"
	echo_stderr "Exitting..."
	exit 1
}

user_interrupt_exit()
{
	echo_stderr; echo_stderr
	echo_stderr "Script stopped due to user interrupt, exitting..."
	exit 1
}

install_depends()
{
	for f in $@; do
		echo -n "Checking for ${f}... "
		check_rpm_installed $f
	done
}

calculate_version_num()
{
	if [ -e ${WRKDIR}/${WRKWRC} ]; then
		tar zxf ${SOURCE_DIR}/${DISTFILE} -C ${WRKDIR} || error_exit
	fi
}

generate_spec()
{
	calculate_version_num
	calc_cpu_cores
	echo -n 'Generating RPM spec files... '

	sed -i.bak \
	-e "s|%%X11RDPBASE%%|$X11RDPBASE|g" \
	-e "s|make -j1|${makeCommand}|g" \
	${WRKDIR}/x11rdp.spec || error_exit

	echo 'done'
}

clone()
{
	WRKSRC=x11rdp
	DISTFILE=${WRKSRC}.tar.gz
	echo -n 'Cloning source code... '

	if [ ! -f ${SOURCE_DIR}/${DISTFILE} ]; then
		if $GIT_USE_HTTPS; then
			git clone ${GH_URL} --branch ${GH_BRANCH} ${WRKDIR}/${WRKSRC} >> $BUILD_LOG 2>&1 || error_exit
			sed -i -e 's|git://|https://|' ${WRKDIR}/${WRKSRC}/.gitmodules ${WRKDIR}/${WRKSRC}/.git/config
			(cd ${WRKDIR}/${WRKSRC} && git submodule update --init --recursive)  >> $BUILD_LOG 2>&1
		else
			git clone --recursive ${GH_URL} --branch ${GH_BRANCH} ${WRKDIR}/${WRKSRC} >> $BUILD_LOG 2>&1 || error_exit
		fi
		tar cfz ${WRKDIR}/${DISTFILE} -C ${WRKDIR} ${WRKSRC} || error_exit
		cp -a ${WRKDIR}/${DISTFILE} ${SOURCE_DIR}/${DISTFILE} || error_exit

		echo 'done'
	else
		echo 'already exists'
	fi
}

x11rdp_dirty_build()
{
	# clean X11RDPBASE
	if [ -d $X11RDPBASE ]; then
		echo "FATAL: $X11RDPBASE exists already" >&2
		exit 1
	fi

	# extract xrdp source
	tar zxf ${SOURCE_DIR}/${DISTFILE} -C $WRKDIR || error_exit

	# build x11rdp once into $X11RDPBASE
	(
	cd ${WRKDIR}/${WRKSRC}/xorg/X11R7.6 && \
	patch --forward -p2 < ${SOURCE_DIR}/buildx_patch.diff >> $BUILD_LOG 2>&1 ||: && \
	patch --forward -p2 < ${SOURCE_DIR}/x11_file_list.patch >> $BUILD_LOG 2>&1 ||: && \
	sed -i.bak \
		-e 's/if ! mkdir $PREFIX_DIR/if ! mkdir -p $PREFIX_DIR/' \
		-e 's/wget -cq/wget -cq --retry-connrefused --waitretry=10/' \
		-e "s/make -j 1/make -j $jobs/g" \
		-e 's|^download_url=http://server1.xrdp.org/xrdp/X11R7.6|download_url=https://xrdp.vmeta.jp/pub/xrdp/X11R7.6|' \
		buildx.sh >> $BUILD_LOG 2>&1 && \
	./buildx.sh $X11RDPBASE >> $BUILD_LOG 2>&1
	) || error_exit

	QA_RPATHS=$[0x0001|0x0002] rpmbuild -ba ${WRKDIR}/x11rdp.spec >> $BUILD_LOG 2>&1 || error_exit

	# cleanup installed files during the build
	if [ -d $X11RDPBASE ]; then
		find $X11RDPBASE -delete
	fi
}

rpmdev_setuptree()
{
	echo -n 'Setting up rpmbuild tree... '
	rpmdev-setuptree && \
	echo 'done'
}

build_rpm()
{
	echo 'Building RPMs started, please be patient... '
	echo 'Do the following command to see build progress.'
	echo "	$ tail -f $BUILD_LOG"
	for f in $EXTRA_SOURCE; do
		cp SOURCES/${f} $SOURCE_DIR
	done

	echo -n "Building x11rdp... "
	x11rdp_dirty_build || error_exit
	echo 'done'

	echo "Built RPMs are located in $RPMS_DIR."
}

parse_commandline_args()
{
	# If first switch = --help, display the help/usage message then exit.
	if [ "$1" = "--help" ]
	then
		clear
		echo "usage: $0 OPTIONS
OPTIONS
-------
  --help             : show this help.
  --https            : Use firewall-friendly https:// instead of git:// to fetch git submodules
  --nocpuoptimize    : do not change X11rdp build script to utilize more than 1 of your CPU cores."
		rmdir ${WRKDIR}
		exit 0
	fi

	while [ $# -gt 0 ]; do
		case "$1" in
		--https)
			GIT_USE_HTTPS=true
			;;

		--nocpuoptimize)
			PARALLELMAKE=false
			;;
		esac
		shift
	done
}

calc_cpu_cores()
{
	jobs=$(($(nproc) + 1))
	if $PARALLELMAKE; then
		makeCommand="make -j $jobs"
	else
		makeCommand="make -j 1"
	fi
}

install_targets_depends()
{
	install_depends $X11RDP_BUILD_DEPENDS
}

first_of_all()
{
	if [ ! -f SPECS/x11rdp.spec.in ]; then
		echo_stderr "Make sure this script is run in its directory" 2>&1
		error_exit
	fi
}

#
#  main routines
#

parse_commandline_args $@
first_of_all
install_depends $META_DEPENDS $FETCH_DEPENDS
rpmdev_setuptree
clone
generate_spec
install_targets_depends
build_rpm

exit 0
