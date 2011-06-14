#!/bin/bash
#
# pkgbuild.sh : deals with PKGBUILD, makepkg ...
# This file is part of Yaourt (http://archlinux.fr/yaourt-en)

loadlibrary alpm_query

# Global vars:
# SPLITPKG:	1 if current PKGBUILD describe multiple package

# source makepkg configuration
source_makepkg_conf ()
{
	# From makepkg, try to source the same way
	MAKEPKG_CONF=${MAKEPKG_CONF:-/etc/makepkg.conf}
	local _PKGDEST=${PKGDEST}
	local _SRCDEST=${SRCDEST}
	local _SRCPKGDEST=${SRCPKGDEST}
	[[ -r $MAKEPKG_CONF ]] && source "$MAKEPKG_CONF" || return 1
	[[ -r ~/.makepkg.conf ]] && source ~/.makepkg.conf
	# Preserve environment variable
	# else left empty (do not set to $PWD)
	PKGDEST=${_PKGDEST:-$PKGDEST}
	SRCDEST=${_SRCDEST:-$SRCDEST}
	# Use $EXPORTDIR if defined in {/etc/,~/.}yaourtrc
	export PKGDEST=${EXPORTDIR:-$PKGDEST}
	export SRCDEST=${EXPORTDIR:-$SRCDEST}
	# Since pacman 3.4, SRCPKGDEST for makepkg --[all]source
	SRCPKGDEST=${_SRCPKGDEST:-$SRCPKGDEST}
	SRCPKGDEST=${SRCPKGDEST:-$PKGDEST}
	export SRCPKGDEST=${EXPORTDIR:-$SRCPKGDEST}
}

# Read PKGBUILD
# PKGBUILD must be in current directory
# Usage:	read_pkgbuild ($update)
#	$update: 1: call devel_check & devel_update from makepkg
# Set PKGBUILD_VARS, exec "eval $PKGBUILD_VARS" to have PKGBUILD content.
read_pkgbuild ()
{
	local update=${1:-0}
	local vars=(pkgbase pkgname pkgver pkgrel arch pkgdesc provides url \
		groups license source install md5sums depends makedepends conflicts \
		replaces \
		_svntrunk _svnmod _cvsroot_cvsmod _hgroot _hgrepo \
		_darcsmod _darcstrunk _bzrtrunk _bzrmod _gitroot _gitname \
		)

	unset ${vars[*]}
	local ${vars[*]}
	local pkgbuild_tmp=$(mktemp --tmpdir=".")
	echo "yaourt_$$() {"                            > $pkgbuild_tmp
	cat PKGBUILD                                    >> $pkgbuild_tmp
	echo                                            >> $pkgbuild_tmp
	if (( update )); then
		echo "devel_check"                          >> $pkgbuild_tmp
		# HOLDVER=1 to disable the double check when
		# devel_update() source PKGBUILD
		echo "HOLDVER=1 devel_update"               >> $pkgbuild_tmp
	fi
	echo "declare -p ${vars[*]} 2>/dev/null >&3"    >> $pkgbuild_tmp
	echo "return 0"                                 >> $pkgbuild_tmp
	echo "}"                                        >> $pkgbuild_tmp
	echo "( yaourt_$$ ) || exit 1"                  >> $pkgbuild_tmp
	echo "exit 0"                                   >> $pkgbuild_tmp
	PKGBUILD_VARS="$(makepkg "${MAKEPKG_ARG[@]}" -p "$pkgbuild_tmp" 3>&1 1>/dev/null | tr '\n' ';')"
	rm "$pkgbuild_tmp"
	eval $PKGBUILD_VARS
	pkgbase=${pkgbase:-${pkgname[0]}}
	PKGBUILD_VARS="$(declare -p ${vars[*]} 2>/dev/null | tr '\n' ';')"
	if [[ ! "$pkgbase" ]]; then
		echo $(gettext 'Unable to read PKGBUILD')
		return 1
	fi
	(( ${#pkgname[@]} > 1 )) && SPLITPKG=1 || SPLITPKG=0
	(( SPLITPKG )) && {
		warning $(gettext 'This PKGBUILD describes a splitted package.')
		msg $(gettext 'Specific package options are unknown')
	}
	return 0
}

# Check PKGBUILD dependances 
# call read_pkgbuild() before
# Usage:	check_deps ($nodisplay)
#	$nodisplay: 1: don't display depends information
check_deps ()
{
	local nodisplay=${1:-0} dep
	eval $PKGBUILD_VARS
	PKGBUILD_DEPS=( $(pacman_parse -T "${depends[@]}" "${makedepends[@]}" ) )
	PKGBUILD_DEPS_INSTALLED=()
	for dep in "${depends[@]}" "${makedepends[@]}"
	do
		if ! in_array "$dep" "${PKGBUILD_DEPS[@]}"; then
			PKGBUILD_DEPS_INSTALLED+=("$dep")
		fi
	done
	(( nodisplay )) && return 0
	msg "$(_gettext '%s dependencies:' "$pkgbase")"
	for dep in "${PKGBUILD_DEPS_INSTALLED[@]}"; do
		echo -e " - $CBOLD$dep$C0 $(gettext '(already installed)')"
	done
	for dep in "${PKGBUILD_DEPS[@]}"; do
		isavailable $dep && echo -e " - $CBLUE$dep$C0 $(gettext '(package found)')" && continue
		echo -e " - $CYELLOW$dep$C0" $(gettext '(building from AUR)') 
	done
	echo
	return 0 
}

# Check if PKGBUILD conflicts with an installed package
# call read_pkgbuild() before
# Usage:	check_conflicts ($nodisplay)
#	$nodisplay: 1: don't display depends information
# If nodisplay, return 1 if conflicts and 0 if not
check_conflicts ()
{
	local nodisplay=${1:-0} cf
	eval $PKGBUILD_VARS
	local cfs=( $(pacman_parse -T "${conflicts[@]}") )
	PKGBUILD_CONFLICTS=()
	if (( ${#cfs[@]} != ${#conflicts[@]} )); then 
		for cf in "${conflicts[@]}"
		do
			if ! in_array "$cf" "${cfs[@]}"; then
				PKGBUILD_CONFLICTS+=("$cf")
			fi
		done
		# Workaround to disable self detection 
		# If package is installed and provides that 
		# which conflict with.
		local i=0
		for cf in "${PKGBUILD_CONFLICTS[@]}"; do
			pkgquery -Qqi "$cf" || unset PKGBUILD_CONFLICTS[$i]
			(( i++ ))
		done
		[[ "$PKGBUILD_CONFLICTS" ]] && (( nodisplay )) && return 1
	fi
	(( nodisplay )) && return 0
	if [[ "$PKGBUILD_CONFLICTS" ]]; then 
		msg "$(_gettext '%s conflicts:' "$pkgbase")"
		for cf in $(pkgquery -Qif "%n-%v" "${PKGBUILD_CONFLICTS[@]%[<=>]*}"); do
			echo -e " - $CBOLD$cf$C0"
		done
	fi
	echo
	return 0
}

# Check if PKGBUILD install a devel version
# call read_pkgbuild() before
check_devel ()
{
	eval $PKGBUILD_VARS
	if [[ -n "${_svntrunk}" && -n "${_svnmod}" ]] \
		|| [[ -n "${_cvsroot}" && -n "${_cvsmod}" ]] \
		|| [[ -n "${_hgroot}" && -n "${_hgrepo}" ]] \
		|| [[ -n "${_darcsmod}" && -n "${_darcstrunk}" ]] \
		|| [[ -n "${_bzrtrunk}" && -n "${_bzrmod}" ]] \
		|| [[ -n "${_gitroot}" && -n "${_gitname}" ]]; then
		return 0
	fi
	return 1
}

# Edit PKGBUILD and install files
# Usage:	edit_pkgbuild ($default_answer, $loop, $check_dep)
# 	$default_answer: 1 (default): Y 	2: N
# 	$loop: for PKGBUILD, 1: loop until answer 'no' 	0 (default) : no loop
# 	$check_dep: 1 (default): check for deps and conflicts
edit_pkgbuild ()
{
	local default_answer=${1:-1}
	local loop=${2:-0}
	local check_dep=${3:-1}
	(( ! EDITFILES )) && { 
		read_pkgbuild || return 1
		(( check_dep )) && { check_deps; check_conflicts; }
		return 0
	}
	local iter=1

	while (( iter )); do
		run_editor PKGBUILD $default_answer
		local ret=$?
		(( ret == 2 )) && return 1
		(( iter++>1 && ret )) && break
		(( ret )) || (( ! loop )) && iter=0
		read_pkgbuild || return 1
		(( check_dep )) && { check_deps; check_conflicts; }
	done
	
	eval $PKGBUILD_VARS
	local installfile
	for installfile in "${install[@]}"; do
		[[ "$installfile" ]] || continue
		run_editor "$installfile" $default_answer 
		(( $? == 2 )) && return 1
	done
	return 0
}

# Build package using makepkg
# Usage: build_package ()
# Return 0: on success
#		 1: on error
#		 2: if sysupgrade and no update available
build_package()
{
	eval $PKGBUILD_VARS
	msg "$(gettext 'Building and installing package')"

	local wdirDEVEL="$DEVELBUILDDIR/${pkgbase}"
	if [[ "$(readlink -f .)" != "$wdirDEVEL" ]] && check_devel;then
		#msg "Building last CVS/SVN/HG/GIT version"
		local use_devel_dir=0
		if [[ -d "$wdirDEVEL" && -w "$wdirDEVEL" ]]; then
			prompt2 "$(_gettext 'The sources of %s were kept last time. Use them ?' "$pkgbase") $(yes_no 1)"
			builduseragrees && use_devel_dir=1
		fi
		[[ ! -d "$wdirDEVEL" ]] && mkdir -p $wdirDEVEL 2> /dev/null && use_devel_dir=1
		if (( use_devel_dir )); then
			cp -a ./* "$wdirDEVEL/" && cd $wdirDEVEL || \
				warning $(_gettext 'Unable to write in %s directory. Using /tmp directory' "$wdirDEVEL")
		fi
		if (( SYSUPGRADE )) && (( DEVEL )) && (( ! FORCE )); then
			# re-read PKGBUILD to update version
			read_pkgbuild 1 || return 1
			eval $PKGBUILD_VARS
			if ! is_x_gt_y "$pkgver-$pkgrel" $(pkgversion $pkgbase); then
				msg $(_gettext '%s is already up to date.' "$pkgbase")
				return 2
			fi
		fi
	fi

	# install deps from abs (build or download) as depends
	if [[ $PKGBUILD_DEPS ]]; then
		msg $(_gettext 'Install or build missing dependencies for %s:' "$pkgbase")
		if ! SP_ARG="--asdeps" sync_packages "${PKGBUILD_DEPS[@]}"; then
			local _deps_left=( $(pacman_parse -T "${PKGBUILD_DEPS[@]}") )
			local _deps_installed=()
			for _deps in "${PKGBUILD_DEPS[@]}"; do
				in_array "$_deps" "${_deps_left[@]}" || _deps_installed+=("$_deps")
			done
			if [[ $_deps_installed ]]; then
				warning $(gettext 'Dependencies have been installed before the failure')
				su_pacman -Rs "${_deps_installed[@]%[<=>]*}"
			fi
			return 1
		fi
	fi
	
	# Build 
	if (( ! UID )); then
		warning $(gettext 'Building package as root is dangerous.\n Please run yaourt as a non-privileged user.')
		sleep 2
	fi
	PKGDEST="$YPKGDEST" makepkg "${MAKEPKG_ARG[@]}" -s -f -p ./PKGBUILD

	if (( $? )); then
		error $(_gettext 'Makepkg was unable to build %s.' "$pkgbase")
		return 1
	fi
	(( EXPORT && EXPORTSRC )) && [[ $SRCPKGDEST ]] && makepkg --allsource -p ./PKGBUILD
	return 0
}

# Install package after build
# Usage: install_package ()
install_package()
{
	local _file failed=0
	eval $PKGBUILD_VARS
	# Install, export, copy package after build 
	if (( EXPORT==2 )); then
		msg $(_gettext 'Exporting %s to %s directory' "$pkgbase" "${P[cachedir]}")
		launch_with_su cp -vf "$YPKGDEST/"* "${P[cachedir]}/" 
	elif (( EXPORT )) && [[ $PKGDEST ]]; then
		msg $(_gettext 'Exporting %s to %s directory' "$pkgbase" "$PKGDEST")
		cp -vfp "$YPKGDEST/"* "$PKGDEST/" 
	fi

	while true; do
		echo
		msg "$(_gettext "Continue installing %s ?" "$pkgbase") $(yes_no 1)"
		prompt $(gettext '[v]iew package contents   [c]heck package with namcap')
		local answer=$(builduserinput "YNVC" "Y")
		echo
		case "$answer" in
			V)	local i=0
				for _file in "$YPKGDEST"/*; do
					(( i++ )) && { prompt2 $(gettext 'Press any key to continue'); read -n 1; }
					$PACMAN -Qlp "$_file"
				done
				;;
			C)	if type -p namcap &>/dev/null ; then
					for _file in "$YPKGDEST"/*; do
						namcap "$_file"
					done
				else
					warning $(gettext 'namcap is not installed')
				fi
				echo
				;;
			N)	failed=1; break;;
			*)	break;;
		esac
	done
	local _arg=""
	((SYSUPGRADE && UP_NOCONFIRM)) && _arg+=" --noconfirm"
	(( ! failed )) && for _file in "$YPKGDEST"/*; do
		su_pacman -U $SP_ARG "${PACMAN_S_ARG[@]}" $_arg $_file || { failed=$?; break; }
	done
	if (( failed )); then 
		warning $(_gettext "Your packages are saved in %s" "$YAOURTTMPDIR")
		cp -i "$YPKGDEST"/* $YAOURTTMPDIR/ || warning $(_gettext 'Unable to copy packages to %s directory' "$YAOURTTMPDIR")
	fi

	return $failed
}

# Initialise build dir ($1)
init_build_dir()
{
	local wdir="$1"
	if [[ -d "$wdir" ]]; then
		rm -rf "$wdir" || { error $(_gettext 'Unable to delete directory %s. Please remove it using root privileges.' "$wdir"); return 1; }
	fi
	mkdir -p "$wdir" || { error $(_gettext 'Unable to create directory %s.' "$wdir"); return 1; }
	cd "$wdir"
}

custom_pkg ()
{
	(( CUSTOMIZEPKGINSTALLED )) && [[ -f "/etc/customizepkg.d/$1" ]] && return 0
	return 1
}

# Call build_package until success or abort
# on success, call install_package
# Usage: package_loop ($pkgname, $trust)
#   $pkgname: name of package
#	$trust: 1: default answer for editing: Y (for abs)
package_loop ()
{
	local pl_pkgname=$1
	local trust=${2:-0}
	local default_answer=1
	local ret=0 failed=0
	declare -a PKGBUILD_DEPS PKGBUILD_DEPS_INSTALLED \
	           PKGBUILD_CONFLICTS PKGBUILD_VARS
	# Customise PKGBUILD
	custom_pkg "$pl_pkgname" && customizepkg --modify

	local YPKGDEST=$(mktemp -d --tmpdir="$YAOURTTMPDIR" PKGDEST.XXX)
	(( trust )) && default_answer=2
	while true; do
		edit_pkgbuild $default_answer 1 || { failed=1; break; }
		prompt "$(_gettext 'Continue building %s ? ' "$pl_pkgname")$(yes_no 1)"
		builduseragrees || { failed=1; break; }
		build_package
		ret=$?
		case "$ret" in
			0|2) break ;;
			1)	prompt "$(_gettext 'Restart building %s ? ' "$pl_pkgname")$(yes_no 2)"
				builduseragrees "YN" "N" && { failed=1; break; }
				;;
			*) return 99 ;; # should never execute
		esac
	done
	(( ! ret )) && (( ! failed )) && { install_package || failed=1; }
	rm -r "$YPKGDEST"
	return $failed
}

# sanitize_pkgbuild(pkgbuild)
# Turn a PKGBUILD into a harmless script (at least try to)
sanitize_pkgbuild ()
{
	sed -n -e '/\$(\|`\|[><](\|[&|]\|;/d' \
		-e 's/^ *[a-zA-Z0-9_]\+=/declare &/' \
		-e '/^declare *[a-zA-Z0-9_]\+=(.*) *\(#.*\|$\)/{p;d}' \
		-e '/^declare *[a-zA-Z0-9_]\+=(.*$/,/.*) *\(#.*\|$\)/{p;d}' \
		-e '/^declare *[a-zA-Z0-9_]\+=.*\\$/,/.*[^\\]$/p' \
		-e '/^declare *[a-zA-Z0-9_]\+=.*[^\\]$/p' \
		-e '1,/^\r$/ { s/Last-Modified: \(.*\)\r/declare last_mod="\1"/p }' \
		-e '/ *build *( *)/q' \
		-e 'd' "$1"
}

# Source a PKGBUILD and return a declare var list:
# Call in a sub process:
# . <(source_pkgbuild file var1 var2)
source_pkgbuild ()
{
	local file="$1"; shift
	source <(sanitize_pkgbuild "$file") &> /dev/null && declare -p "$@" 2> /dev/null
}

# get_pkgbuild ($pkgs)
# Get each package source and decompress into pkg directory
get_pkgbuild ()
{
	local i pkgs repo pkg pkgbase pkgver arch deps cwd=$(pwd)
	pkgs=("$@")
	loadlibrary aur abs
	declare -A pkgs_downloaded
	for ((i=0; i<${#pkgs[@]}; i++)); do
		cd "$cwd"
		read repo pkg arch pkgver < <(pkgquery -1ASif '%r %n %a %v' "${pkgs[$i]}")
		[[ ! $pkg ]] && continue
		pkg=$(get_pkgbase $pkg $repo $pkgver)
		[[ ${pkgs_downloaded[$pkg]} ]] && continue
		pkgs_downloaded[${pkg}]=1
		if [[ -d $pkg ]]; then
			prompt2 "$(_gettext '%s directory already exist. Replace ?' "$pkg") $(yes_no 1)"
			useragrees || continue
		else
			mkdir "$pkg" 
		fi
		cd "$pkg" || continue
		msg "$(_gettext 'Download %s sources' "$pkg")"
		if [[ $repo = "aur" ]]; then
			aur_get_pkgbuild "$pkg"
		else
			abs_get_pkgbuild "$repo/$pkg" "${arch#-}"
		fi
		(($?)) && continue
		if ((DEPENDS)); then
			unset depends makedepends
			. <( source_pkgbuild PKGBUILD depends makedepends ) || continue
			deps=("${depends[@]}" "${makedepends[@]}")
			((DEPENDS>1)) || deps=($(pacman_parse -T "${deps[@]}"))
			[[ $deps ]] || continue
			pkgs+=($(pkgquery -Aif '%n' "${deps[@]}"))
		fi
	done
	cd "$cwd"
}

# If we have to deal with PKGBUILD and makepkg, source makepkg conf(s)
source_makepkg_conf 
# vim: set ts=4 sw=4 noet: 
