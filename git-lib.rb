#!/usr/bin/env ruby
require 'optparse'
require 'fileutils'

##########################################
# Helpers

def getconfig(conf)
    output=`git config --get #{conf}`.strip
    output if $?.success?
end

def setconfig(conf, val, global)
    globalstr = global && "--global " || ""
    system("git config #{globalstr} --replace-all #{conf} #{val}")
end

def call(cmd)
    output=`#{cmd}`
    result=$?.success?
    return output.strip, result
end

def run(cmd)
    IO.popen(cmd) do |stdout|
        stdout.each do |line|
            puts line
        end
    end
    return $?.success?
end

def probe_repository(url)
    %x(git ls-remote #{url} 2>/dev/null)
    $?.success?
end

def ensure_clean()
    %x(git diff-index HEAD --exit-code --quiet 2>&1)
    abort "Working tree has modifications.  Cannot pull." unless $?.success?
    %x(git diff-index --cached HEAD --exit-code --quiet 2>&1) 
    abort "Index has modifications. Cannot pull." unless $?.success?
end

def produce_merge_commit(head_rev, fetch_rev, commit_message)
    if !head_rev.empty? && head_rev != fetch_rev then
        headp = "-p #{head_rev}"
    else
        headp = ""
    end

    tree = %x(git write-tree).strip
    abort "git write-tree failed" unless $?.success?
    
    commit = %x(git commit-tree #{tree} #{headp} -p #{fetch_rev} -m '#{commit_message}')
    abort "git commit failed" unless $?.success?

    %x(git reset #{commit})
    abort "git reset failed" unless $?.success?
end

########################################
# Options

gitdir, _ = call("git rev-parse --show-toplevel")
pwd = Dir.pwd
Dir.chdir(gitdir)

options = {}

option_parser = OptionParser.new do |opts|
  opts.banner = 
"
Usage: git-lib push <lib> [<refspec>] [--account=<account>] [--url=<url>]
       git-lib pull <lib> [<refspec>] [--account=<account>] [--url=<url>] [--abort] [--continue]
       git-lib account add <account-name> <service-url> [--default] [--local]

account add
    Creates a git lib account.

    <account-name>: The name of the account 
    <service-url>: An erb pattern that describes the service url.
                   May use %{account} and %{lib} as variables.
                   As a convencience, the strings 'github' and 'bitbucket' are
                   replaced with their known urls.

                   Example: git@github.com:%{account}/%{lib}.git

push 
    Pushes lib to existing repository.

    <lib>: The path to the lib relative to pwd
    <refspec>: The branch to push to. Defaults to master.

pull
    Pulls lib from repository.

    <lib>: The path to the lib relative to pwd
    <refspec>: The branch to pull from. Defaults to master.


Other options:
"
    opts.on("--account [ACCOUNT]", "The repository account used. If omitted, the default account is used.") do |val|
        options[:account] = val
    end

    opts.on("--url [URL]", "The remote url. Inferred from account if not specified.") do |val|
        options[:url] = val
    end

    opts.on("--abort", "(pull only) Aborts a git lib pull in case of merge conflict.") do
        options[:abort] = true
    end

    opts.on("--continue", "(pull only) Used to continue after resolving merge conflicts during a lib pull.") do
        options[:continue] = true
    end

    opts.on("--default", "(create-account only) Makes the account the default one") do
        options[:default] = true
    end

    opts.on("--local", "(create-account only) Creates the account in the local git repository") do
        options[:local] = true
    end

    opts.on_tail("-h", "--help", "Show this message.") do
        puts opts
        exit
    end
end
option_parser.parse!

gitsubtree = 'git split-lib'

def get_account(options)
    options[:account] || getconfig("lib.default")
end

def get_url(lib, options)
    url = options[:url]

    if not url then
        account = get_account(options)
        abort "No account or url specified" unless account

        url_pattern = getconfig("lib.#{account}.url")
        abort "No such account #{account}" unless url_pattern

        url = url_pattern % {account: account, lib: lib}
    end

    return url
end

def get_lib(gitdir, pwd, options)
    abort "Missing lib name" unless ARGV.length >= 2

    lib = ARGV[1]
    lib = lib.chomp '/' # Remove trailing slash if present

    reldir = pwd[gitdir.length + 1..-1] || '.'
    prefix = reldir != '.' && File.join(reldir, lib) || lib

    libname = File.split(lib)[1]

    return libname, prefix
end

def get_refspec(options)
    ARGV.length >= 3 && ARGV[2] || "master"
end

########################################
# Commands
#

service_urls = {
    "github" => "git@github.com:%{account}/%{lib}.git",
    "bitbucket" => "git@bitbucket.org:%{account}/%{lib}.git",
}

commands = {

    "account" => lambda do
        abort "Missing account command" unless ARGV.length >= 2
        abort "Missing account name" unless ARGV.length >= 3
        abort "Missing service url" unless ARGV.length >= 4

        account_command = ARGV[1]

        if account_command == "add" then
            account_name = ARGV[2]
            service_url = ARGV[3]

            global = !options[:local]

            service_url = service_urls[service_url] || service_url

            setconfig("lib.#{account_name}.url", service_url, global)
            if options[:default] then
                setconfig("lib.default", account_name, global)
            end
        else
            abort "Unknown account_command"
        end
    end,

    "split" => lambda do
        libname, prefix = get_lib(gitdir, pwd, options)

        url = get_url(libname, options)
        abort "No url or account specified" unless url

        refspec = get_refspec(options)

        %x(git fetch #{url} #{refspec})
        split_sha, success = call "#{gitsubtree} --prefix #{prefix} --with fetch_head"
        puts split_sha
    end,

    "push" => lambda do
        libname, prefix = get_lib(gitdir, pwd, options)
        abort "No such directory '#{libname}'" unless Dir.exists? prefix

        url = get_url(libname, options)
        refspec = get_refspec(options)

        puts "Probing remote repository..."

        # Fetch remote branch
        %x(git fetch #{url} #{refspec} 2>& 1)
        fetch_success = $?.success?
        with = fetch_success && "--with fetch_head" || ""

        # If the repository doesn't exist, you must create it yourself
        if !fetch_success && !probe_repository(url)
            abort "Remote #{url} does not exist, please create ond try again"
        end

        puts "Splitting lib..."
        split_sha, success = call "#{gitsubtree} --prefix #{prefix} #{with}"
        run "git push #{url} #{split_sha}:refs/heads/#{refspec}" if success
    end,

    "pull" => lambda do
        git_dir = %x(git rev-parse --git-dir).strip
        lib_pull_file = "#{git_dir}/LIB_PULL"

        if (options[:abort] || options[:continue])
            abort "Not currently in a lib pull" unless File.exists? lib_pull_file
            head_rev, fetch_rev, libname = File.read(lib_pull_file).split(' ')

            if (options[:abort])
                %x(git reset --hard #{head_rev})
            elsif (options[:continue])
                commit_message = "Merged lib \"#{libname}\""
            end
        else
            libname, prefix = get_lib(gitdir, pwd, options)
            url = get_url(libname, options)
            refspec = get_refspec(options)

            ensure_clean()

            puts "Fetching remote lib..."
            %x(git fetch #{url} #{refspec})
            abort "Could not fetch from repository: #{url}" unless $?.success?

            fetch_rev = %x(git rev-parse --revs-only fetch_head).split(' ')[0].strip
            head_rev = %x(git rev-parse head).strip
            File.open(lib_pull_file, "w") do |f|
                f.write "#{head_rev} #{fetch_rev}"
            end

            if !Dir.exists? prefix
                puts "Adding lib..."

                %x(git read-tree --prefix="#{prefix}" fetch_head)
                abort "git read-tree failed" unless $?.success?

                %x(git checkout -- "#{prefix}")
                abort "git checkout tree failed" unless $?.success?

                commit_message = "Add lib \"#{libname}\""
            else
                puts "Splitting lib..."
                split_sha, success = call "#{gitsubtree} --prefix #{prefix} --with fetch_head"
                abort "Split failed" unless success

                puts "Merging lib..."

                if !%x(git rev-list #{split_sha}..fetch_head).empty?
                    %x(git merge -s ours -m 'Rejoin lib "#{libname}"' #{split_sha})

                    commit_message = "Merged lib \"#{libname}\""
                    output = %x(git merge -Xsubtree=#{prefix} --message='#{commit_message}' -q --no-commit fetch_head 2>&1)
                    abort 'Merge failed; Fix conflicts and then issue "git lib pull --continue"' unless $?.success?
                else
                    puts "Everything up-to-date"
                end
            end
        end

        if commit_message
            produce_merge_commit(head_rev, fetch_rev, commit_message)
        end

        FileUtils.rm(lib_pull_file)
    end,
}


########################################
# Main
    
if ARGV.length < 1 then
    puts option_parser
else
    commandname = ARGV[0]
    command = commands[commandname]
    abort "Unknown command '#{commandname}'" unless command
    command.call()
end
