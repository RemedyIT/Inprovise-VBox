# VBox script class for InproviseVBox
#
# Author::    Martin Corino
# License::   Distributes under the same license as Ruby

require 'digest/md5'

module Inprovise

  class VBox < Inprovise::Script

    class Config

      attr_writer :script, :name, :image, :autostart, :install_opts
      attr_accessor :autostart, :format, :diskbus, :memory, :cpus, :os, :network, :netname

      def initialize(cfg, node)
        @script = cfg[:script]
        @name = cfg[:name]
        @image = cfg[:image]
        @format = cfg[:format]
        @diskbus = cfg[:diskbus]
        @memory = cfg[:memory] || 1024
        @cpus = cfg[:cpus] || 1
        @os = cfg[:os]
        @network = cfg[:network] || :hostnet
        @netname = cfg[:netname]
        @autostart = cfg[:autostart] == true
        @install_opts = cfg[:install_opts]
        @node = node
      end

      def name
        @name || "#{@script}_#{Digest::MD5.hexdigest(@node.name+Time.now.to_s)}"
      end

      def image
        @image || ''
      end

      def install_opts
        @install_opts || ''
      end

    end

    class DSL < Inprovise::Script::DSL

      def configure(cfg = {}, &block)
        @script.configure(cfg, &block)
      end

    end

    attr_reader :config

    def initialize(name)
      super(name)
      @config = nil
      @config_action = nil
    end

    def configure(cfg, &block)
      @config = cfg.merge({ :script => name })
      @config_action = block if block_given?
      # make sure the configure action is the first thing triggered on any command
      # (:validate actions are *always* called first for :apply and :revert)
      # on :apply and :validate next should be the standard vbox installation procedure
      # on :revert the standard vbox uninstall procedure should be last
      command(:validate).insert(0, vbox_verify_action)
      command(:validate).insert(0, vbox_configure_action)
      command(:apply).insert(0, vbox_install_action)
      command(:revert) << vbox_uninstall_action
      # add standard actions
      action('vbox-shutdown') do |vboxname|
        sudo("virsh shutdown #{vboxname}")
      end
      action('vbox-kill') do |vboxname|
        sudo("virsh destroy #{vboxname}")
      end
      action('vbox-start') do |vboxname|
        sudo("virsh start #{vboxname}")
      end
      action('vbox-verify') do |vboxname, autostart=false|
        vbox_info = sudo("virsh dominfo #{vboxname}").gsub("\n", ' ')
        vbox_info =~ /name:\s+#{vbox.name}\s.*state:\s+running/i &&
          (!autostart || vbox_info =~ /autostart:\s+enable/i)
      end
      action('vbox-delete') do |vboxname|
        sudo("virsh undefine #{vboxname}")
      end
      self
    end

    # redefine to make sure user definitions always follow configure action and precede standard  revert action
    def revert(&definition)
      last = command(:revert).pop
      command(:revert) << definition
      command(:revert) << last if last
    end

    def vbox_configure_action
      vbox_script = self
      cfg_block = @config_action
      lambda do
        # get config declared in VBox script
        cfg = vbox_script.config
        # merge user defined settings
        cfg.merge(vbox.to_h) if vbox
        # replace VBox config options with Config object
        config.vbox = Inprovise::VBox::Config.new(cfg, node)
        # call user defined callback configure action if any
        cfg_block.call(config.vbox) if cfg_block
      end
    end

    def vbox_verify_action
      lambda do
        trigger 'vbox-verify', vbox.name, (command == :apply && vbox.autostart)
      end
    end

    def vbox_install_action
      lambda do
        # 1. verify config
        raise ArgumentError, "Cannot access VBox image #{vbox.image}" unless remote(vbox.image).file?
        # 2. execute virt-install
        cmdline = 'virt-install --connect qemu:///system --hvm --virt-type kvm --import '
        cmdline << "--name #{vbox.name} --memory #{vbox.memory} --vcpus #{vbox.cpus} "
        cmdline << "--os-variant #{vbox.os}" if vbox.os
        cmdline << case vbox.network
                   when :hostnet
                     "--network network=#{vbox.netname || 'default'} "
                   when :bridge
                     "--network bridge=#{vbox.netname || 'virbr0' } "
                   end
        cmdline << '--graphics spice '
        cmdline << "--disk path=#{vbox.image},device=disk,boot_order=1"
        cmdline << ",bus=#{vbox.diskbus}" if vbox.diskbus
        cmdline << ",format=#{vbox.format}" if vbox.format
        cmdline << ' --disk device=cdrom,boot_order=2,bus=ide'
        cmdline << " #{vbox.install_opts}" if vbox.install_opts
        sudo(cmdline)
      end
    end

    def vbox_uninstall_action
      lambda do
        trigger 'vbox-shutdown', vbox.name
        30.times do
          sleep(1)
          break unless trigger 'vbox-verify', vbox.name
        end
        if trigger('vbox-verify', vbox.name)
          trigger('vbox-kill', vbox.name)
          sleep(1)
        end
        trigger('vbox-undefine', vbox.name) unless trigger('vbox-verify', vbox.name)
      end
    end

  end

end

Inprovise::DSL.dsl_define do
  def vbox(name, &definition)
    Inprovise.log.local("Adding VBox script #{name}") if Inprovise.verbosity > 1
    Inprovise.add_script(Inprovise::VBox.new(name)) do |script|
      Inprovise::VBox::DSL.new(script).instance_eval(&definition)
    end
  end
end
