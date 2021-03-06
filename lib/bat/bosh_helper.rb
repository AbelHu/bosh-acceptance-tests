require 'httpclient'
require 'json'
require 'net/ssh'
require 'zlib'
require 'archive/tar/minitar'
require 'tempfile'
require 'common/exec'

module Bat
  module BoshHelper
    include Archive::Tar

    def bosh(*args, &blk)
      @bosh_runner.bosh(*args, &blk)
    end

    def bosh_safe(*args, &blk)
      @bosh_runner.bosh_safe(*args, &blk)
    end

    def ssh_options
      {
        private_key: @env.vcap_private_key,
        password: @env.vcap_password
      }
    end

    def manual_networking?
      @env.bat_networking == 'manual'
    end

    def aws?
      @env.bat_infrastructure == 'aws'
    end

    def openstack?
      @env.bat_infrastructure == 'openstack'
    end

    def warden?
      @env.bat_infrastructure == 'warden'
    end

    def compiled_package_cache?
      info = @bosh_api.info
      info['features'] && info['features']['compiled_package_cache']
    end

    def dns?
      info = @bosh_api.info
      info['features'] && info['features']['dns']['status']
    end

    def bosh_tld
      info = @bosh_api.info
      info['features']['dns']['extras']['domain_name'] if dns?
    end

    def persistent_disk(host, user, options = {})
      get_disks(host, user, options).each do |disk|
        values = disk.last
        if values[:mountpoint] == '/var/vcap/store'
          return values[:blocks]
        end
      end
      raise 'Could not find persistent disk size'
    end

    def ssh(host, user, command, options = {})
      options = options.dup
      output = nil
      @logger.info("--> ssh: #{user}@#{host} #{command.inspect}")

      private_key = options.delete(:private_key)
      options[:user_known_hosts_file] = %w[/dev/null]
      options[:keys] = [private_key] unless private_key.nil?

      if options[:keys].nil? && options[:password].nil?
        raise 'Need to set ssh :password, :keys, or :private_key'
      end

      @logger.info("--> ssh options: #{options.inspect}")
      Net::SSH.start(host, user, options) do |ssh|
        output = ssh.exec!(command).to_s
      end

      @logger.info("--> ssh output: #{output.inspect}")
      output
    end

    def ssh_sudo(host, user, command, options)
      if options[:password].nil?
        raise 'Need to set sudo :password'
      end
      ssh(host, user, "echo #{options[:password]} | sudo -p '' -S #{command}", options)
    end

    def tarfile
      Dir.glob('*.tgz').first
    end

    def tar_contents(tgz, entries = false)
      list = []
      tar = Zlib::GzipReader.open(tgz)
      Minitar.open(tar).each do |entry|
        is_file = entry.file?
        entry = entry.name unless entries
        list << entry if is_file
      end
      list
    end

    def wait_for_vm(name)
      @logger.info("Start waiting for vm #{name}")
      vm = nil
      5.times do
        vm = get_vm(name)
        break if vm
      end
      @logger.info("Finished waiting for vm #{name} vm=#{vm.inspect}")
      vm
    end

    def wait_for_vm_state(name, state)
      puts "Start waiting for vm #{name} to have state #{state}"
      vm_in_state = nil
      5.times do
        vm = get_vm(name)
        if vm && vm[:state] =~ /#{state}/
          vm_in_state = vm
          break
        end
      end
      puts "Finished waiting for vm #{name} to have sate=#{state} vm=#{vm_in_state.inspect}"
      vm_in_state
    end

    private

    def get_vm(name)
      get_vms.find { |v| v[:vm] =~ /#{name} \(.*\)/ }
    end

    def get_vms
      output = @bosh_runner.bosh('vms --details').output
      table = output.lines.grep(/\|/)

      table = table.map { |line| line.split('|').map(&:strip).reject(&:empty?) }
      headers = table.shift || []
      headers.map! do |header|
        header.downcase.tr('/ ', '_').to_sym
      end
      output = []
      table.each do |row|
        output << Hash[headers.zip(row)]
      end
      output
    end

    def get_disks(host, user, options)
      disks = {}
      df_cmd = 'df -x tmpfs -x devtmpfs -x debugfs -l | tail -n +2'

      df_output = ssh(host, user, df_cmd, options)
      df_output.split("\n").each do |line|
        fields = line.split(/\s+/)
        disks[fields[0]] = {
          blocks: fields[1],
          used: fields[2],
          available: fields[3],
          percent: fields[4],
          mountpoint: fields[5],
        }
      end

      disks
    end
  end
end
