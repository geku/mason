require "mason"
require "tmpdir"
require "yaml"
require "fileutils"
require "foreman/engine"

class Mason::Buildpack

  attr_reader :dir, :name, :url

  def initialize(dir)
    @dir = dir
    Dir.chdir(@dir) do
      @name = File.basename(@dir)
      @url  = %x{ git config remote.origin.url }.chomp
    end
  end

  def <=>(other)
    self.name <=> other.name
  end

  def detect(app)
    mkchtmpdir do
      output = %x{ #{script("detect")} "#{app}" }
      $?.exitstatus.zero? ? output.chomp : nil
    end
  end

  def compile(app, env_file=nil, cache=nil)
    cache_dir = cache || "#{app}/.git/cache"
    puts "  caching in #{cache_dir}"
    compile_dir = Dir.mktmpdir
    FileUtils.rm_rf compile_dir
    FileUtils.cp_r app, compile_dir, :preserve => true
    FileUtils.mkdir_p cache_dir
    Dir.chdir(compile_dir) do
      IO.popen(%{ #{script("compile")} "#{compile_dir}" "#{cache_dir}" }) do |io|
        until io.eof?
          data = io.gets
          data.gsub!(/^-----> /, "  + ")
          data.gsub!(/^       /, "      ")
          data.gsub!(/^\s+\!\s+$/, "")
          data.gsub!(/^\s+\!\s+/, "  ! ")
          data.gsub!(/^\s+$/, "")
          print data
        end
      end
      raise "compile failed" unless $?.exitstatus.zero?
    end
    release_config = YAML.load(`#{script('release')} "#{compile_dir}"`)

    write_procfile(compile_dir, release_config)
    write_start_script(compile_dir, release_config)

    compile_dir
  end

private

  def write_procfile(compile_dir, release_config)
    filename = File.join(compile_dir, "Procfile")
    process_types = release_config["default_process_types"] || {}

    if File.exists? filename
      Foreman::Procfile.new(filename).entries do |name, command|
        process_types[name] = command
      end
    end

    File.open(filename, "w") do |f|
      process_types.each do |name, command|
        f.puts "#{name}: #{command}"
      end
    end
  end

  def write_start_script(compile_dir, release_config)
    # If no .profile.d script exists we write one with the provided config_vars
    # TODO test with JAVA buildpack as it does not provide .profile.d script
    if Dir['.profile.d/*.sh'].size <= 0
      config_vars  = release_config["config_vars"] || {}
      unless config_vars.empty?
        File.open(File.join(compile_dir, ".profile.d/env.sh"), "w") do |f|
          f.puts config.map{|k, v| "export #{k}=#{v}"}.join("\n")
        end
      end
    end

    # Open Procfile to read processes and write start script for each
    procfile = File.join(compile_dir, "Procfile")
    Foreman::Procfile.new(procfile).entries do |name, command|
      next if ['rake', 'console'].include?(name)

      run_script_file = File.join(compile_dir, "bin/run-#{name}.sh")
      File.open(run_script_file, "w") do |f|
        f.puts <<END
#!/bin/bash
export HOME=/app

cd $HOME
export PORT=5000
source "$HOME"/.profile.d/*.sh

#{command}

END
      end
      FileUtils.chmod 0755, run_script_file
    end
    
  end

  def mkchtmpdir
    ret = nil
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        ret = yield(dir)
      end
    end
    ret
  end

  def script(name)
    File.join(dir, "bin", name)
  end
end

