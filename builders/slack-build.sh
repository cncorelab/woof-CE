#!/bin/sh
# Slackware chroot installer for making Woof-based puppy
# Copyright (C) James Budiono 2014
# License: GNU GPL Version 3 or later.
#
# env vars: DRY_RUN=1     - don't install, just print output of flattened pkglist

### end-user configuration
PKGLIST=${PKGLIST:-pkglist}
ARCH=${ARCH:-slackware} # or slackware64
VERSION=${VERSION:-14.1}
DISTRO_PREFIX=${DISTRO_PREFIX:-puppy}
DISTRO_VERSION=${DISTRO_VERSION:-700} # informative only

DEFAULT_REPOS=${REPO_URLS:-http://mirrors.slackware.com/slackware|$VERSION|slackware:extra|CHECKSUMS.md5}

INSTALLPKG=${INSTALLER:-installpkg}
REMOVEPKG=${INSTALLER:-removepkg}

# dirs
REPO_DIR=${REPO_DIR:-repo-$VERSION-$ARCH}
CHROOT_DIR=${CHROOT_DIR:-chroot-$VERSION-$ARCH}
BASE_CODE_PATH=${ROOTFS_BASE:-rootfs-skeleton}
# BASE_ARCH_PATH= # inherit - arch-specific base files, can be empty
EXTRAPKG_PATH=${EXTRAPKG_PATH:-rootfs-packages}

### system-configuration, don't change
LANG=C
REPO_PKGDB_URL="%repo_url%/${ARCH}-%version%/%repo%/%repo_pkgdb%"
LOCAL_PKGDB=pkgdb
ADMIN_DIR=/var/log/packages
TRACKER=/tmp/tracker.$$
FLATTEN=/tmp/flatten.$$

###
BUILD_CONFIG=${BUILD_CONFIG:-./build.conf}
[ -e $BUILD_CONFIG ] && . $BUILD_CONFIG

### helpers ###

trap 'cleanup; exit' INT HUP TERM 0
cleanup() {
	rm -f $TRACKER $FLATTEN
}

### prepare critical dirs
prepare_dirs() {
	rm -rf $CHROOT_DIR 
	mkdir -p $REPO_DIR $CHROOT_DIR
	for p in packages removed_packages removed_scripts scripts setup/tmp; do
		mkdir -p $CHROOT_DIR/var/log/$p
	done
	> $TRACKER
}

###
# $REPO_DIR, $LOCAL_PKGDB, $1-url, $2-version, $3-repos-to-use, $4-pkgdb
add_repo() {
	local MARKER localdb pkgdb_url apt_pkgdb apt_source
	for p in $(echo $3|tr ':' ' '); do
		MARKER="### $2-$p-$1 ###" 
		localdb=$2-$p-$4
		pkgdb_url="$(echo $REPO_PKGDB_URL | sed "s|%repo_url%|$1|; s|%version%|$2|; s|%repo%|$p|; s|%repo_pkgdb%|$4|;")"

		# download
		if ! [ -e $REPO_DIR/$localdb ] && echo Downloading database for "$p $1" ...; then
			if ! case "$1" in
				file://*) cp "${pkgdb_url#file://}" $REPO_DIR/$localdb ;;
				*) wget -q --no-check-certificate -c -O "$REPO_DIR/$localdb" "$pkgdb_url" ;;
			esac; then
				echo Bad database download for "$p $1", skipping ... 
				rm -f $REPO_DIR/$localdb # bad download, don't proceed
				continue
			fi
		fi

		if ! grep -F -m1 -q "$MARKER" $REPO_DIR/$LOCAL_PKGDB 2>/dev/null; then	
			echo Processing database for "$2 $p" ...
			echo "$MARKER" >> $REPO_DIR/$LOCAL_PKGDB
			# awk version is 10x faster than bash/ash/dash version, even with LANG=C
			# format: pkg|pkgver|pkgfile|pkgpath|pkgprio|pkgsection|pkgmd5|pkgdep
			>> $REPO_DIR/$LOCAL_PKGDB \
			< "$REPO_DIR/$localdb" \
			awk -v repo_url="${1}/$ARCH-$VERSION/$p" -v section=$p '
/\.t.z$/ {
	PKGMD5=$1; 
	sub(/\.\//,"",$2); PKGPATH=$2; 
	sub(/.*\//,"",$2); PKGFILE=$2; 
	b=split($2,a,"-")
	PKGBUILD=a[b--] # not used at the moment
	PKGARCH=a[b--]  # not used at the moment
	PKGVER=a[b--]
	PKG=a[1]; for (i=2; i<=b; i++) PKG=PKG "-" a[i]
	# doctored information since we dont have it
	PKGPRIO="normal"; PKGDEP=""; PKGSECTION=section;
	
	print PKG "|" PKGVER "|" PKGFILE "|" repo_url "/" PKGPATH "|" PKGPRIO "|" PKGSECTION "|" PKGMD5 "|" PKGDEP ;	
}
'
		fi
	done

	# remove duplicates, use the "later" version if duplicate packages are found
	< $REPO_DIR/$LOCAL_PKGDB > /tmp/t.$$ \
	awk -F"|" '{if (!a[$1]) b[n++]=$1; a[$1]=$0} END {for (i=0;i<n;i++) {print a[b[i]]}}'
	mv /tmp/t.$$ $REPO_DIR/$LOCAL_PKGDB
}

# $*-repos, format: url|version|sections|pkgdb
add_multiple_repos() {
	while [ "$1" ]; do
		add_repo $(echo "$1" | tr '|' ' ')
		shift
	done
}

###
# $1-pkg returns PKG PKGVER PKGFILE PKGPATH PKGPRIO PKGMD5 PKGSECTION PKGDEP
# format: pkg|pkgver|pkgfile|pkgpath|pkgprio|pkgsection|pkgmd5|pkgdep
get_pkg_info() {
	OIFS="$IFS"; IFS="|"
	set -- $(grep -m1 "^${1}|" $REPO_DIR/$LOCAL_PKGDB)
	IFS="$OIFS"
	PKG="$1" PKGVER="$2" PKGFILE="$3" PKGPATH="$4" PKGPRIO="$5" PKGSECTION="$6" PKGMD5="$7" PKGDEP="$8"
	#echo $PKG $PKGVER $PKGFILE $PKGPATH $PKGPRIO $PKGSECTION $PKGMD5 $PKGDEP
}

###
# $1-PKGFILE
is_already_installed() {
	test -e $CHROOT_DIR/$ADMIN_DIR/info/$PKGFILE
}

###
# $1-retry, $PKGFILE, $PKGPATH, $PKGMD5
download_pkg() {
	local retval=0 local
	[ "$1" ] && echo "Bad md5sum $PKGFILE, attempting to re-download ..."
	if ! [ -e "$REPO_DIR/$PKGFILE" ] && echo Downloading "$PKGFILE" ...; then
		case "$PKGPATH" in
			file://*) cp "${PKGPATH#file://}" $REPO_DIR/$PKGFILE ;;
			*) wget -q --no-check-certificate -O $REPO_DIR/$PKGFILE "$PKGPATH" ;;
		esac
	fi
	
	# check md5sum
	echo "$PKGMD5  $REPO_DIR/$PKGFILE" > /tmp/md5.$$
	md5sum -c /tmp/md5.$$ >/dev/null; retval=$? 
	rm -f /tmp/md5.$$
	[ $retval -ne 0 -a -z "$1" ] && rm -f "$REPO_DIR/$PKGFILE" && download_pkg retry && retval=0
	return $retval
}


######## commands handler ########

###
# $1-force PKGFILE PKG PKGVER PKGPRIO ARCH
install_pkg() {
	if ! is_already_installed $PKGFILE || [ "$1" = force ]; then
		echo Installing "$PKGFILE" ... 
		ROOT="$CHROOT_DIR" $INSTALLPKG "$REPO_DIR/$PKGFILE"
	fi
}
# $1-PKGFILE without tbz/txz
create_pkg_header() {
	local PKGNAME=${1%.t?z}
	> $CHROOT_DIR/$ADMIN_DIR/$PKGNAME \
	echo "PACKAGE NAME:     $PKGNAME
COMPRESSED PACKAGE SIZE:     unknown
UNCOMPRESSED PACKAGE SIZE:     unknown
PACKAGE LOCATION: ./$1
PACKAGE DESCRIPTION:
FILE LIST:
./" 
}

# $1-dir to install $2-name $3-category
install_from_dir() {
	local pkgname=${DISTRO_PREFIX}_$2-1-noarch-1 # actually not always no arch, but anyway
	! [ -d ${1} ] && echo $2 not found ... && return 1 # dir doesn't exist
	is_already_installed $pkgname && return 1

	create_pkg_header ${pkgname}.txz
	cp -av --remove-destination "${1}"/* $CHROOT_DIR | sed "s|.*${CHROOT_DIR}/||; s|'\$||" \
	>> "$CHROOT_DIR/$ADMIN_DIR/${pkgname}"
	[ -f "$CHROOT_DIR"/pinstall.sh ] && ( cd "$CHROOT_DIR"; sh pinstall.sh )
	rm -f $CHROOT_DIR/pinstall.sh
	return 0
}

###
# $@-pkg to remove
remove_pkg() {
	while [ "$1" ]; do
		ROOT="$CHROOT_DIR" $REMOVEPKG $1
		shift
	done
}

### so that apt-get is happy
# $1 dummy pkgname. Note dependencies of dummy packages are not pulled.
install_dummy() {
	while [ "$1" ]; do
		get_pkg_info "$1"; shift
		[ -z $PKG ] && continue
		is_already_installed $PKGFILE && continue
		echo Installing dummy for $PKG ...
		create_pkg_header $PKGFILE
	done
}

###
# $1-if "nousr", then don't use /usr
# note: busybox must be static and compiled with applet list
install_bb_links() {
	local pkgname=bblinks-1-noarch-1
	is_already_installed $pkgname && return
	local nousr=""
	case $1 in
		nousr|nouser) nousr=usr/ ;;
	esac
	
    create_pkg_header ${pkgname}.txz
	if [ -e $CHROOT_DIR/bin/busybox ] && $CHROOT_DIR/bin/busybox > /dev/null; then
		chroot $CHROOT_DIR /bin/busybox --list-full | while read -r p; do
			pp=${p#$nousr}
			[ -e $CHROOT_DIR/$pp ] && continue # don't override existing binaries
			echo $pp >> "$CHROOT_DIR/$ADMIN_DIR/$pkgname"
			case $pp in 
				usr*) ln -s ../../bin/busybox $CHROOT_DIR/$pp 2>/dev/null ;; 
				*)    ln -s ../bin/busybox $CHROOT_DIR/$pp 2>/dev/null ;; 
			esac
		done
	fi
}

###
# $1-output $2 onwards - squashfs_param
make_sfs() {
	local output="$1" dir=${1%/*}
	shift
	[ "$dir" ] && [ "$dir" != "$output" ] && mkdir -p $dir
	echo $DISTRO_VERSION > $CHROOT_DIR/etc/${DISTRO_PREFIX}-version
	mksquashfs $CHROOT_DIR "$output" -noappend "$@"
	padsfs "$output"
}
padsfs() {
	ORIGSIZE=$(stat -c %s "$1")
	BLOCKS256K=$(( ((ORIGSIZE/1024/256)+1) ))
	dd if=/dev/zero of="$1" bs=256K seek=$BLOCKS256K count=0
}

# $@-all, doc, gtkdoc, locales, cache
cutdown() {
	local options="$*"
	[ "$1" = "all" ] && options="doc gtkdoc locales cache"
	set -x
	for p in $options; do
		case $p in
			doc)     rm -rf $CHROOT_DIR/usr/share/doc 
					 mkdir $CHROOT_DIR/usr/share/doc ;;
			gtkdoc)  rm -rf $CHROOT_DIR/usr/share/gtk-doc 
					 mkdir $CHROOT_DIR/usr/share/gtk-doc ;;
			locales) rm -rf $CHROOT_DIR/usr/share/locale 
					 mkdir -p $CHROOT_DIR/usr/share/locale/en ;;
			cache)   find $CHROOT_DIR -name icon-theme.cache -delete ;;
		esac
	done
	set +x
}


######## pkglist parser ########

###
# $1-pkglist, output std
flatten_pkglist() {
	local pkglist="$1"
	while read -r pp; do
		p=${pp%%#*}; eval set -- $p; p="$1"
		[ -z $p ] && continue
		
		# commands
		case $p in
			%exit) break ;;
			%include)
				[ "$2" ] && flatten_pkglist "$2" ;;
			%bblinks|%makesfs|%remove|%addbase|%addpkg|%dummy|%cutdown)
				echo "$pp" ;;
			%repo)
				shift # $1-url $2-version $3-repos to use $4-pkgdb
				add_repo "$@" 1>&2 ;;
			%reinstall)
				shift # $1-pkgname ...
				while [ "$1" ]; do echo "$1" force; shift; done ;;
			*) # anything else
				if ! grep -m1 -q "^${p}$" $TRACKER; then
					get_pkg_info "$p"
					echo $p >> $TRACKER
					track_dependency
					echo $p
				fi ;;			
		esac
	done < $pkglist
	return 0
}
# dependency tracker
track_dependency() { :; } # default is no dependency tracking
list_dependency() {
	[ -z "$PKGDEP" ] && return
	local depfile=$(mktemp -p /tmp dep.XXXXXXXX)
	echo $PKGDEP | tr ',' '\n' | while read -r p; do
		[ -z $p ] && continue
		! grep -m1 -q "^${p}$" $TRACKER && echo $p
	done > $depfile
	[ -s $depfile ] && ( flatten_pkglist $depfile; )
	rm -f $depfile 
}

###
# $1-pkglist
process_pkglist() {
	# count
	local pkglist="$1" COUNT=$(wc -l < "$1") COUNTER=0
	
	# process
	while read -r p; do
		p=${p%%#*}; eval set -- $p; p="$1"
		[ -z $p ] && continue
		
		# commands
		COUNTER=$((COUNTER+1))		
		echo $COUNTER of $COUNT "$@"		
		case $p in
			%exit) break ;;
			%bblinks)
				shift # $1-nousr
				echo Installing busybox symlinks ...
				install_bb_links "$@" ;;
			%makesfs)
				shift # $1-output $@-squashfs params
				echo Creating $1 ...
				make_sfs "$@" ;;
			%remove)
				shift # $1-pkgname, pkgname, ...
				remove_pkg "$@" ;;
			%addbase)
				echo Installing base rootfs ...
				[ "$BASE_ARCH_PATH" ] && install_from_dir $BASE_ARCH_PATH base-arch core				
				install_from_dir $BASE_CODE_PATH base core ;;
			%addpkg)
				shift # $1-pkgname, pkgname ...
				while [ "$1" ]; do
					! [ -d $EXTRAPKG_PATH/$1 ] && shift && continue
					echo Installing extra package "$1"  ...
					install_from_dir $EXTRAPKG_PATH/$1 $1 optional
					shift
				done ;;
			%dummy)
				shift # $1-pkgname, pkgname ...
				install_dummy "$@" ;;
			%cutdown)
				shift # $@ various cutdown options
				cutdown "$@" ;;
			*)  # anything else
				get_pkg_info $p
				[ -z "$PKG" ] && echo Cannot find ${p}. && continue
				download_pkg || { echo Download $p failed. && exit 1; }
				install_pkg "$2" || { echo Installation of $p failed. && exit 1; }			
				;;
		esac		
	done < $pkglist
	return 0
}


### main
prepare_dirs
add_multiple_repos $DEFAULT_REPOS
echo Flattening $PKGLIST ...
flatten_pkglist $PKGLIST > $FLATTEN
if [ -z "$DRY_RUN" ]; then
	process_pkglist $FLATTEN
else
	cat $FLATTEN
fi
