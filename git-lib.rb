#!/usr/local/bin/ruby
require 'optparse'
require 'fileutils'

def getconfig(conf)
    output=`git config --get #{conf}`.strip
    output if $?.success?
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

########################################
# Options

options = {}
options[:account] = getconfig("host.default")
options[:refspec] = 'master'
options[:description] = ''

gitdir, _ = call("git rev-parse --show-toplevel")
pwd = Dir.pwd
Dir.chdir(gitdir)

option_parser = OptionParser.new do |opts|
  opts.banner = 
"
Usage: git-lib [options] command lib-name [ref]

Command description:
  push      Pushes a new library. Creates if it doesn't exist.
  pull      Pulls from a library. Creates if it doesn't exist.

"

    opts.on("--account [ACCOUNT]", "The repository account used for git-host. If omitted, the default account is used.") do |val|
        options[:account] = val
    end

    opts.on("--description [DESCRIPTION]", "(First push only): Adds a description to the repository.") do |val|
        options[:description] = val
    end

    opts.on("--branch [REFSPEC]", "Specifies the remote branch to sync with. Default is master.") do |val|
        options[:refspec] = val
    end

    opts.on("--url [URL]", "The remote url. Inferred from host if not specified.") do |val|
        options[:url] = val
    end

    opts.on("--password [PASSWORD]", "The password. Not needed if password is stored in account.") do |val|
        options[:password] = val
    end

    opts.on("--abort", "Used to abort a lib pull.") do
        options[:abort] = true
    end

    opts.on("--continue", "Used to continue after resolving merge conflicts during a lib pull.") do
        options[:continue] = true
    end

    opts.on_tail("-h", "--help", "Show this message.") do
        puts opts
        exit
    end
end
option_parser.parse!

########################################
# Commands
#

gitsubtree = 'git split-lib'
githost = 'git host'

def host_options(options)
    account = options[:account] && "--account #{options[:account]} " || ""
    desc = options[:description] && "--description \"#{options[:description]}\" " || ""
    password = options[:password] && "--password \"#{options[:password]}\" " || ""
    return account + desc
end

def probe_repository(url)
    %x(git ls-remote #{url} 2>/dev/null)
    $?.success?
end

def ensure_clean()
    %x(git diff-index HEAD --exit-code --quiet 2>&1)
    abort "Working tree has modifications.  Cannot pull." unless $?.success?
    %x(git diff-index --cached HEAD --exit-code --quiet 2>&1) 
    abort "Index has modifications.  Cannot pull." unless $?.success?
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

commands = {

    "split" => lambda do
        %x(git fetch #{options[:url]} #{options[:refspec]})
        split_sha, success = call "#{gitsubtree} --prefix #{options[:prefix]} --with fetch_head"
        puts split_sha
    end,

    "push" => lambda do
        abort "No such directory '#{options[:libname]}'" unless Dir.exists? options[:prefix]

        puts "Probing remote repository..."

        # Fetch remote branch
        %x(git fetch #{options[:url]} #{options[:refspec]} 2>& 1)
        fetch_success = $?.success?
        with = fetch_success && "--with fetch_head" || ""

        # If the repository doesn't exist, it's created for you
        if !fetch_success && !probe_repository(options[:url])
            puts "Repository doesn't exist, creating..."
            system("#{githost} create-repo #{options[:libname]} #{host_options(options)}")
        end

        puts "Splitting lib..."
        split_sha, success = call "#{gitsubtree} --prefix #{options[:prefix]} #{with}"
        run "git push #{options[:url]} #{split_sha}:refs/heads/#{options[:refspec]}" if success
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
            ensure_clean()
            libname = options[:libname]

            puts "Fetching remote lib..."
            %x(git fetch #{options[:url]} #{options[:refspec]})
            abort "Could not fetch from repository: #{options[:url]}" unless $?.success?

            fetch_rev = %x(git rev-parse --revs-only fetch_head).split(' ')[0].strip
            head_rev = %x(git rev-parse head).strip
            File.open(lib_pull_file, "w") do |f|
                f.write "#{head_rev} #{fetch_rev}"
            end

            if !Dir.exists? options[:prefix]
                puts "Adding lib..."

                %x(git read-tree --prefix="#{options[:prefix]}" fetch_head)
                abort "git read-tree failed" unless $?.success?

                %x(git checkout -- "#{options[:prefix]}")
                abort "git checkout tree failed" unless $?.success?

                commit_message = "Add lib \"#{libname}\""
            else
                puts "Splitting lib..."
                split_sha, success = call "#{gitsubtree} --prefix #{options[:prefix]} --with fetch_head"
                abort "Split failed" unless success

                puts "Merging lib..."

                if !%x(git rev-list #{split_sha}..fetch_head).empty?
                    %x(git merge -s ours -m 'Rejoin lib "#{options[:libname]}"' #{split_sha})

                    commit_message = "Merged lib \"#{libname}\""
                    output = %x(git merge -Xsubtree=#{options[:prefix]} --message='#{commit_message}' -q --no-commit fetch_head 2>&1)
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

    if !(options[:abort] || options[:continue])
        abort "Missing lib name" unless ARGV.length >= 2

        lib = ARGV[1]

        reldir = pwd[gitdir.length + 1..-1] || '.'
        prefix = reldir != '.' && File.join(reldir, lib) || lib

        options[:prefix] = prefix
        options[:libname] = File.split(lib)[1]
        options[:refspec] = ARGV[2] if ARGV.length >= 3

        options[:url] = %x(#{githost} url-for #{options[:libname]} #{host_options(options)}).strip
        exit(1) unless $?.success?
    end

    command = commands[commandname]
    abort "Unknown command '#{commandname}'" unless command

    command.call()
end
