#!/bin/bash
#
# git-split-lib.sh: used to split subtree repositories
#
# Stripped-back and modified version of Avery Pennarun's git subtree
#
if [ $# -eq 0 ]; then
    set -- -h
fi

OPTS_SPEC="\
git split-lib --prefix=<prefix> <commit>
--
h,help        show the help
q             quiet
d             show debug message
P,prefix=     the name of the subdir to split out
W,with=       try to join the split with this revision
"
eval "$(echo "$OPTS_SPEC" | git rev-parse --parseopt -- "$@" || echo exit $?)"

PATH=$PATH:$(git --exec-path)
. git-sh-setup

require_work_tree

quiet=
debug=
with=
default="--default HEAD"

debug()
{
	if [ -n "$debug" ]; then
		echo "$@" >&2
	fi
}

say()
{
	if [ -z "$quiet" ]; then
		echo "$@" >&2
	fi
}

assert()
{
	if "$@"; then
		:
	else
		die "assertion failed: " "$@"
	fi
}

#echo "Options: $*"

while [ $# -gt 0 ]; do
	opt="$1"
	shift
	case "$opt" in
		-q) quiet=1 ;;
		-d) debug=1 ;;
		-P) prefix="$1"; shift ;;
		-W) with="$1"; shift ;;
		--) break ;;
		*) die "Unexpected option: $opt" ;;
	esac
done

if [ -z "$prefix" ]; then
	die "You must provide the --prefix option."
fi

dir="$(dirname "$prefix/.")"

revs=$(git rev-parse $default --revs-only "$@") || exit $?
dirs="$(git rev-parse --no-revs --no-flags "$@")" || exit $?
if [ -n "$dirs" ]; then
	die "Error: Use --prefix instead of bare filenames."
fi

debug "quiet: {$quiet}"
debug "revs: {$revs}"
debug "dir: {$dir}"
debug "opts: {$*}"
debug

cache_setup()
{
	cachedir="$GIT_DIR/git-lib-cache/$prefix"
	if [ ! -d "$cachedir" ]; then
		mkdir -p "$cachedir" || die "Can't create new cachedir: $cachedir"
		debug "Using cachedir: $cachedir" >&2
	fi
}

cache_get()
{
	for oldrev in $*; do
		if [ -r "$cachedir/$oldrev" ]; then
			read newrev <"$cachedir/$oldrev"
			t="$(git cat-file -t $newrev)"
			if [ $? ]; then
				echo $newrev
			fi
		fi
	done
}

cache_set()
{
	oldrev="$1"
	newrev="$2"
	echo "$newrev" >"$cachedir/$oldrev"
}

copy_commit()
{
	# We're going to set some environment vars here, so
	# do it in a subshell to get rid of them safely later
	debug copy_commit "{$1}" "{$2}" "{$3}"
	git log -1 --pretty=format:'%an%n%ae%n%ad%n%cn%n%ce%n%cd%n%s%n%n%b' "$1" |
	(
		read GIT_AUTHOR_NAME
		read GIT_AUTHOR_EMAIL
		read GIT_AUTHOR_DATE
		read GIT_COMMITTER_NAME
		read GIT_COMMITTER_EMAIL
		read GIT_COMMITTER_DATE
		export  GIT_AUTHOR_NAME \
			GIT_AUTHOR_EMAIL \
			GIT_AUTHOR_DATE \
			GIT_COMMITTER_NAME \
			GIT_COMMITTER_EMAIL \
			GIT_COMMITTER_DATE
		(echo -n "$annotate"; cat ) |
		git commit-tree "$2" $3  # reads the rest of stdin
	) || die "Can't copy commit $1"
}

toptree_for_commit()
{
	commit="$1"
	git log -1 --pretty=format:'%T' "$commit" -- || exit $?
}

subtree_for_commit()
{
	commit="$1"
	dir="$2"
	git ls-tree "$commit" -- "$dir" |
	while read mode type tree name; do
		assert [ "$name" = "$dir" ]
		assert [ "$type" = "tree" -o "$type" = "commit" ]
		[ "$type" = "commit" ] && continue  # ignore submodules
		echo $tree
		break
	done
}

copy_or_skip()
{
	rev="$1"
	tree="$2"
	newparents="$3"
	assert [ -n "$tree" ]

	identical=
	nonidentical=
	p=
	gotparents=
	for parent in $newparents; do
		ptree=$(toptree_for_commit $parent) || exit $?
		[ -z "$ptree" ] && continue
		if [ "$ptree" = "$tree" ]; then
			# an identical parent could be used in place of this rev.
			identical="$parent"
		else
			nonidentical="$parent"
		fi
		
		# sometimes both old parents map to the same newparent;
		# eliminate duplicates
		is_new=1
		for gp in $gotparents; do
			if [ "$gp" = "$parent" ]; then
				is_new=
				break
			fi
		done
		if [ -n "$is_new" ]; then
			gotparents="$gotparents $parent"
			p="$p -p $parent"
		fi
	done
	
	if [ -n "$identical" ]; then
		echo $identical
	else
		copy_commit $rev $tree "$p" || exit $?
	fi
}

cmd_split()
{
	debug "Splitting $dir..."
	cache_setup || exit $?

	grl='git rev-list --topo-order --reverse --parents $revs'

	# Add --with objects into cache
	if [ -n "$with" ]; then
		grl='git rev-list --topo-order --reverse --parents $with'
		eval "$grl" |
		while read rev parents; do
			cache_set $rev $rev
		done

		# Optimisation: Only look at objects past merge base
		merge_base="$(git merge-base $revs $with)"
		if [ $? == 0 ]; then
			grl='git rev-list --topo-order --reverse --parents --ancestry-path $merge_base..$revs'
		fi
	fi

	eval "$grl" |
	while read rev parents; do
		debug "Processing commit: $rev"
		exists=$(cache_get $rev)
		if [ -n "$exists" ]; then
			debug "  prior: $exists"
			continue
		fi
		debug "  parents: $parents"
		newparents=$(cache_get $parents)
		debug "  newparents: $newparents"
		
		tree=$(subtree_for_commit $rev "$dir")
		debug "  tree is: $tree"

		# ugly.  is there no better way to tell if this is a subtree
		# vs. a mainline commit?  Does it matter?
		if [ -z $tree ]; then
			if [ -n "$newparents" ]; then
				cache_set $rev $rev
			fi
			continue
		fi

		newrev=$(copy_or_skip "$rev" "$tree" "$newparents") || exit $?
		debug "  newrev is: $newrev"
		cache_set $rev $newrev
		cache_set latest_new $newrev
		cache_set latest_old $rev
	done || exit $?
	latest_new=$(cache_get latest_new)
	if [ -z "$latest_new" ]; then
		die "No new revisions were found"
	fi
	
	echo $latest_new
	exit 0
}

cmd_split