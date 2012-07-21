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

gitsubtree = 'git subtree'
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

commands = {

    "push" => lambda do
        abort "No such directory '#{options[:libname]}'" unless Dir.exists? options[:prefix]
        
        # If the repository doesn't exist, it's created for you
        if !probe_repository(options[:url])
            puts "Repository doesn't exist, creating..."
            system("#{githost} create-repo #{options[:libname]} #{host_options(options)}")
        end

        superproject_name = File.split(gitdir)[1]
        annotation = "(*#{superproject_name})"
        message = "Pushed lib \"#{options[:libname]}\""
        sha, success = call "#{gitsubtree} split --message '#{message}' --annotate '#{annotation}' --rejoin --prefix #{options[:prefix]}"
        run "git push #{options[:url]} #{sha}:refs/heads/#{options[:refspec]}" unless not success
    end,

    "pull" => lambda do
        if !Dir.exists? options[:prefix] then
            abort "No such repository: '#{options[:url]}'" unless probe_repository(options[:url])

            message = "Add lib \"#{options[:libname]}\""
            run "#{gitsubtree} add --message '#{message}' --prefix #{options[:prefix]} #{options[:url]} #{options[:refspec]}"
        end

        message = "Merged lib \"#{options[:libname]}\""
        run "#{gitsubtree} pull --message '#{message}' --prefix #{options[:prefix]} #{options[:url]} #{options[:refspec]}"
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
