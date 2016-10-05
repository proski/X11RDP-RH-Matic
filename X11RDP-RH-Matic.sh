#! /bin/bash

trap user_interrupt_exit 2


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

# Sanity checks
if [ $UID -eq 0 ]; then
  echo_stderr "Don't run this script as root" 2>&1
  error_exit
fi

if [ ! -f SPECS/x11rdp.spec.in ]; then
  echo_stderr "Make sure this script is run in its directory" 2>&1
  error_exit
fi

# Dependencies for this utility
TOOL_DEPENDS="rpm-build rpmdevtools ca-certificates git wget"

# x11rdp dependencies
X11RDP_BUILD_DEPENDS=$(grep BuildRequires: SPECS/x11rdp.spec.in | awk '{ print $2 }' | tr '\n' ' ')

# Make sure the dependencies are installed
for f in $TOOL_DEPENDS $X11RDP_BUILD_DEPENDS; do
  echo -n "Checking for ${f}... "
  rpm -q --whatprovides $f || exit 1
done

# Set up rpm build tree
rpmdev-setuptree

WRKSRC=x11rdp
DISTFILE=${WRKSRC}.tar.gz

# Clone source code
echo -n 'Cloning source code... '
if [ ! -f ${SOURCE_DIR}/${DISTFILE} ]; then
  git clone --recursive ${GH_URL} --branch ${GH_BRANCH} ${WRKDIR}/${WRKSRC} >> $BUILD_LOG 2>&1 || error_exit
  tar cfz ${WRKDIR}/${DISTFILE} -C ${WRKDIR} ${WRKSRC} || error_exit
  cp -a ${WRKDIR}/${DISTFILE} ${SOURCE_DIR}/${DISTFILE} || error_exit
  echo 'done'
else
  echo 'already exists'
fi

jobs=$(($(nproc) + 1))
makeCommand="make -j $jobs"

# Generate rpm specfile from template
echo -n 'Generating RPM spec files... '
sed \
-e "s|%%X11RDPBASE%%|$X11RDPBASE|g" \
-e "s|make -j1|${makeCommand}|g" \
SPECS/x11rdp.spec.in > ${WRKDIR}/x11rdp.spec || error_exit
echo 'done'

# Build rpm package
echo 'Building RPMs started, please be patient... '
echo 'Do the following command to see build progress.'
echo "	$ tail -f $BUILD_LOG"
echo -n "Building x11rdp... "
x11rdp_dirty_build || error_exit
echo 'done'
echo "Built RPMs are located in $RPMS_DIR."

exit 0
