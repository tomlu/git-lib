#!ruby
require 'optparse'


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
options[:host], _ = call("git config --get module.host")
options[:username], _ = call("git config --get module.username")
options[:password], _ = call("git config --get module.password")
options[:refspec] = 'master'
options[:description] = ''

gitdir, _ = call("git rev-parse --show-toplevel")
options[:prefix] = Dir.pwd[gitdir.length + 1..-1] || '.'
prefix_specified = false
Dir.chdir(gitdir)

option_parser = OptionParser.new do |opts|
  opts.banner = 
"
Usage: git-module [options] command module-name
command: create|add|push|pull
"

    opts.on("--host [HOST]", "The repository host (eg. bitbucket). If omitted, read from git config module.host") do |val|
        options[:host] = val
    end
    
    opts.on("--username [USERNAME]", "The repository username. If omitted, read from git config module.username") do |val|
        options[:username] = val
    end

    opts.on("--password [PASSWORD]", "The repository password. If omitted, read from git config module.password") do |val|
        options[:password] = val
    end

    opts.on("--prefix [PREFIX]", "The path to the module. If omitted, pwd is used") do |val|
        options[:prefix] = val
        prefix_specified = true
    end

    opts.on("--description [DESCRIPTION]", "(create only): Adds a description to the repository") do |val|
        options[:description] = val
    end

    opts.on("--branch [REFSPEC]", "(push, pull only): Specifies the remote branch to sync with") do |val|
        options[:refspec] = val
    end

    opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
    end

end
option_parser.parse!

command_name = ARGV[0]
module_name = ARGV[1]

########################################
# Host support

hosts = {
    "bitbucket" => {
        :create => lambda do
            "curl --silent --request POST --user #{options[:username]}:#{options[:password]} https://api.bitbucket.org/1.0/repositories/ --data name=#{module_name} --data scm=git --data description #{options[:description]}"
        end,

        :url => lambda do
            "git@bitbucket.org:#{options[:username]}/#{module_name}.git"
        end,
    }
}

abort "module.host or --host must be specified" unless options[:host]
abort "module.username or --username must be specified" unless options[:username]
abort "module.password --password must be specified" unless options[:password]

host = hosts[options[:host]]
abort "Unknown host '#{options[:host]}'" unless host

url = host[:url].call()

########################################
# Commands
#

#subtree = File.dirname(__FILE__) + '/git-subtree2'
subtree = 'git subtree'

commands = {
    "create" => lambda do
        success = run host[:create].call()
        commands["push"].call() if success
    end,

    "add" => lambda do
        message = "Add module \"#{module_name}\""
        if not prefix_specified then
            options[:prefix] = options[:prefix] != '.' && File.join(options[:prefix], module_name) || module_name
        end
        run "#{subtree} add --message '#{message}' --prefix #{options[:prefix]} #{url} #{options[:refspec]}"
    end,

    "push" => lambda do
        superproject_name = File.split(gitdir)[1]
        annotation = "(*#{superproject_name})"
        message = "Pushed module \"#{module_name}\""
        sha, success = call "#{subtree} split --message '#{message}' --annotate '#{annotation}' --rejoin --prefix #{options[:prefix]}"
        run "git push #{url} #{sha}:refs/heads/#{options[:refspec]}" unless not success
    end,

    "pull" => lambda do
        message = "Merged module \"#{module_name}\""
        run "#{subtree} pull --message '#{message}' --prefix #{options[:prefix]} #{url} #{options[:refspec]}"
    end,
}


########################################
# Main
    
if ARGV.length != 2 then
    puts option_parser
else
    command = commands[command_name]
    abort "Unknown command '#{command_name}'" unless command
    command.call()
end
