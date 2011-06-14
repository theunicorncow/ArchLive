#!/bin/bash
#
# pacman.sh: pacman interactions
# This file is part of Yaourt (http://archlinux.fr/yaourt-en)

# Global var: P for pacman configuration
declare -A P=()

parse_pacman_conf()
{
	# Default pacman configuration
	P=([dbpath]="/var/lib/pacman/"
	   [lockfile]="/var/lib/pacman//db.lck"
	   [cachedir]="/var/cache/pacman/pkg/")
	# Parse pacman options
	declare -a PKGS_IGNORED=() 
	eval $(pacman_parse --debug -T 2>/dev/null |
	  sed -n -e 's/"/\\"/g' \
             -e 's/debug: config: \([a-zA-Z]\+\): \(.*\)/P[\1]="${P[\1]}\2 "/p' \
             -e 's/debug: config: \([a-zA-Z]\+\)$/P[\1]=1/p' \
             -e "s/debug: option '\([a-zA-Z]\+\)' = \(.*\)/P[\1]=\"\2\"/p"
	)
	# Add ignored packages from command line options
	IGNOREPKG+=(${P[IgnorePkg]})
	PKGS_IGNORED=("${IGNOREPKG[@]}")
	IGNOREGRP+=(${P[IgnoreGroup]})
	[[ $IGNOREGRP ]] && PKGS_IGNORED+=($(pacman_parse -Sqg "${IGNOREGRP[@]}"))
	P[ignorepkg]="${PKGS_IGNORED[*]}"
	return 0
}

# Wait while pacman locks exists
pacman_queue()
{
	# from nesl247
	if [[ -f ${P[lockfile]} ]]; then
		msg $(gettext 'Pacman is currently in use, please wait.')
		while [[ -f ${P[lockfile]} ]]; do sleep 3; done
	fi
}

# launch pacman as root
su_pacman ()
{
	pacman_queue; launch_with_su $PACMAN "${PACMAN_C_ARG[@]}" "$@"
}

# Launch pacman and exit
pacman_cmd ()
{
	(( ! $1 )) && exec $PACMAN "${ARGSANS[@]}"
	prepare_orphan_list
	pacman_queue; launch_with_su $PACMAN "${ARGSANS[@]}"  
	local ret=$?
	(( ! ret )) && show_new_orphans
	exit $ret
}

# Refresh pacman database
pacman_refresh ()
{
	local _arg
	title $(gettext 'synchronizing package databases')
	(( $1 > 1 )) && _arg="-Syy" || _arg="-Sy"
	su_pacman $_arg || exit $?
}


is_package_ignored ()
{
	if [[ " ${P[ignorepkg]} " =~ " $1 " ]]; then
		(($2)) && echo -e "$1: $CRED "$(gettext '(ignoring package upgrade)')"$C0"
		return 0
	fi
	return 1
}

# is_x_gt_y ($ver1,$ver2)
is_x_gt_y()
{
	[[ $(vercmp "$1" "$2" 2> /dev/null) -gt 0 ]]
}

# vim: set ts=4 sw=4 noet: 
