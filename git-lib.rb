#!/usr/local/bin/ruby
require 'optparse'

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
Usage: git-lib [options] command lib-name

Command description:
  push      Pushes a new library. Creates if it doesn't exist.
  pull      Pulls from a library. Creates if it doesn't exist.

"

    opts.on("--account [ACCOUNT]", "The repository account used for git-host. If omitted, the default account is used.") do |val|
        options[:account] = val
    end

    opts.on("--prefix [PREFIX]", "The path to the lib. If omitted, pwd/<lib-name> is used.") do |val|
        options[:prefix] = val2bpivotaltracker
        prefix_specified = true
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
        ensure_clean()

        puts "Fetching remote lib..."
        %x(git fetch #{options[:url]} #{options[:refspec]})
        abort "Could not fetch from repository: #{options[:url]}" unless $?.success?

        fetch_rev = %x(git rev-parse --revs-only fetch_head).split(' ')[0].strip
        head_rev = %x(git rev-parse head).strip
        if !head_rev.empty? && head_rev != fetch_rev then
            headp = "-p #{head_rev}"
        else
            headp = ""
        end

        if !Dir.exists? options[:prefix]
            puts "Adding lib..."

            %x(git read-tree --prefix="#{options[:prefix]}" fetch_head)
            abort "git read-tree failed" unless $?.success?

            %x(git checkout -- "#{options[:prefix]}")
            abort "git checkout tree failed" unless $?.success?

            commit_message = "Add lib \"#{options[:libname]}\""
        else
            puts "Rejoining lib..."
            split_sha, success = call "#{gitsubtree} --prefix #{options[:prefix]} --with fetch_head"
            abort "Split failed" unless success

            puts "Merging lib..."

            if !%x(git rev-list #{split_sha}..fetch_head).empty?
                %x(git merge -s ours -m 'Rejoin lib "#{options[:libname]}"' #{split_sha})

                commit_message = "Merged lib \"#{options[:libname]}\""
                output = %x(git merge -Xsubtree=#{options[:prefix]} --message='#{commit_message}' -q --no-commit fetch_head 2>&1)
                abort "Merge failed:\n#{output}" unless $?.success?
            else
                puts "Everything up-to-date"
            end
        end

        if commit_message
            tree = %x(git write-tree).strip
            abort "git write-tree failed" unless $?.success?
            
            commit = %x(git commit-tree #{tree} #{headp} -p #{fetch_rev} -m '#{commit_message}')
            abort "git commit failed" unless $?.success?

            %x(git reset #{commit})
        end
    end,
}


########################################
# Main
    
if ARGV.length != 2 then
    puts option_parser
else
    commandname = ARGV[0]
    options[:libname] = ARGV[1]

    options[:url] = %x(#{githost} url-for #{options[:libname]} #{host_options(options)}).strip
    exit(1) unless $?.success?

    if not options[:prefix] then
        reldir = pwd[gitdir.length + 1..-1] || '.'
        options[:prefix] = reldir != '.' && File.join(reldir, options[:libname]) || options[:libname]
    end

    command = commands[commandname]
    abort "Unknown command '#{commandname}'" unless command

    command.call()
end
