git-lib
=======

What is it?
-----------

git-lib is an alternative to git-submodule. It targets the following usecase:

* A single organisation with that wants to share code libraries between its projects
* Many small, independent code libraries
* Development of these libraries mostly takes place in the context of the superproject

With git-lib, you can split out and push a subdirectory to a separate repository (called a lib). This lib can then be pulled into other repositories. After this, changes can be shared between projects using git lib much as you would expect, with merge conflicts handled naturally.

git-lib is powered by a modified version of Avery Pennarun's [git-subtree](https://github.com/apenwarr/git-subtree).

Workflow
--------

* Create a git-lib account that tells git-lib what url to use for your libs
* Using your hosting service create a repository for each lib that you want to share
* Issue `git lib push <lib>` in a repository that contains a reusable lib
* In another repository, issue `git lib pull <lib>` for that lib

Requirements
------------

* git 1.7 or higher
* Ruby 1.9 or higher
* Only tested on OS X, I have no idea if it will work on anything else

Installation
------------

Clone the repository and run `sudo ./install [--symlink]`

Example
-------

	# Set up a new global git-lib account for the organisation "myorg"
	git lib account add myorg github

    # Or you can explicitly spell out a url pattern
    # %{account} and %{lib} are available as variables
    git lib account add myorg git@github.org:myorg/%{lib}.git

    # Next, log into "myorg" on github and create a lib called "shared-code"

	# Push a fresh lib out to the newly create repository
    cd ~/repos/my-awesome-repo
	git lib push libs/shared-code

	# Or you can cd to the subdirectory first
	cd libs
	git lib push shared-code

	# Get that lib into a different repo - the location doesn't have to match
    cd ~/repos/a-repo-that-wants-shared-code
	git lib pull external-libs/shared-code

	# Push some changes upstream
	git lib push external-libs/shared-code

	# Fetching changes from other project
    cd ~/repos/my-awesome-repo
	git lib pull libs/shared-code

	# You can pass a branch name, otherwise "master" is assumed
	git lib push libs/shared-code my-branch

	# Mark conflicts as resolved
	git lib pull --continue

	# Abort conflict resolution
	git lib pull --abort
