git-lib
=======

What is it?
-----------

git-lib is an alternative to git-submodule. It targets the following usecase:

* A single organisation with that wants to share code libraries between its projects
* Many small, independent code libraries
* Developement of these libraries mostly takes place in the context of the superproject

With git-lib, you can split out and push a subdirectory to a separate repository (called a lib). This lib can then be pulled into other repositories. After this, changes can be shared between projects using git lib much as you would expect, with merge conflicts handled naturally.

git-lib is powered by git-host and a modified version of Avery Pennarun's git-subtree.

Documentation
-------------

First, install and configure git-host. It's helpful to set up your projects to run off a default account so you don't have to keep passing the git-host account, but that's up to you.

After this, it's as simple as using `git lib push` and `git lib pull` as often as you would like to share changes between the projects.

Requirements
------------

* git-host
* git 1.7 or higher
* Ruby 1.9 or higher
* Only tested on OS X, I have no idea if it will work on anything else

Installation
------------

Clone the repository and run `sudo ./install [--symlink]`

Examples
--------

	# Create a new lib
	git lib push libs/shared-code

	# Or you can cd first
	cd libs
	git lib push shared-code

	# In another repo, get that lib - the location doesn't have to match
	git lib pull external-libs/shared-code

	# Push some changes upstream
	git lib push external-libs/shared-code

	# Fetching changes from other project
	git lib pull libs/shared-code