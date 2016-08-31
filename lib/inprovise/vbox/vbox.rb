# VBox script class for InproviseVBox
#
# Author::    Martin Corino
# License::   Distributes under the same license as Ruby

require 'digest/md5'

module Inprovise::VBox

  # add a common 'vbox' script defining all common actions
  Inprovise::DSL.script 'vbox' do
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
    action 'vbox-ifaddr' do |vboxname|
      result = []
      out = sudo("virsh domifaddr #{vboxname}").split("\n").last.strip
      unless /-+/ =~ out
        _, mac, _, net = out.split(' ')
        result << mac << net.split('/').first
      end
      result
    end
  end

  class VBoxScript < Inprovise::Script

    # config
    #     :name
    #     :image
    #     :format
    #     :diskbus
    #     :memory
    #     :cpus
    #     :os
    #     :network
    #     :netname
    #     :autostart
    #     :install_opts

    class DSL < Inprovise::Script::DSL

      def configure(cfg = {}, &block)
        @script.configure(cfg, &block)
      end

    end

    attr_reader :config, :config_action

    def initialize(name)
      super(name)
      @config = nil
      @config_action = nil
      @vm_script = nil
      @node_script = nil
    end

    def setup
      vbox_script = self
      # define the scripts that do the actual work as dependencies
      # 1. install the virtual machine
      @vm_script = Inprovise::DSL.script "#{name}#vbox_vm" do

        # first validation action must be handling config
        validate do
          # make sure to initialize configuration only once
          unless config.vbox && config.vbox.configured?
            # get config declared in parent VBox script if any
            cfg = vbox_script.config || {}
            # merge user defined settings from execution context
            cfg.merge!(vbox.to_h) if config.vbox
            # replace VBox config options with merged version
            config.vbox = vbox_script.init_config(cfg)
            # take care of defaults
            config.vbox.memory ||= 1024
            config.vbox.cpus ||= 1
            config.vbox.network ||= :hostnet
            # call user defined callback configure action if any
            self.instance_exec(config.vbox, &vbox_script.config_action) if vbox_script.config_action
            # generate name if still none set
            config.vbox.name ||= "#{vbox_script.name}_#{Digest::MD5.hexdigest(node.name+Time.now.to_s)}"
            config.vbox[:'configured?'] = true
          end
          true # this validation step always returns true
        end

        # next validation step is actual VM verification
        validate do
          # look for existing target with VM name on :apply unless node creation is suppressed
          if command == :apply && !vbox.no_node
            if tgt = Inprovise::Infrastructure.find(vbox.name)
              type = Inprovise::Infrastructure::Group === tgt ? 'group' : 'node'
              raise ArgumentError, "VBox #{vbox.name} clashes with existing #{type}"
            end
          end
          trigger 'vbox:vbox-verify', vbox.name, (command == :apply && vbox.autostart)
        end

        # apply : installation
        apply do
          # 1. verify config
          raise ArgumentError, "Cannot access VBox image #{vbox.image}" unless remote(vbox.image).file?
          # 2. execute virt-install
          log("Installing VBox #{vbox.name}".bold)
          cmdline = 'virt-install --connect qemu:///system --hvm --virt-type kvm --import --wait 0 '
          cmdline << '--autostart ' if vbox.autostart
          cmdline << "--name #{vbox.name} --memory #{vbox.memory} --vcpus #{vbox.cpus} "
          cmdline << "--os-variant #{vbox.os} " if vbox.os
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
          10.times do
            sleep(1)
            break if trigger 'vbox:vbox-verify', vbox.name, vbox.autostart
          end
        end

        # revert : uninstall
        revert do
          trigger 'vbox:vbox-shutdown', vbox.name
          30.times do
            sleep(1)
            break unless trigger 'vbox:vbox-verify', vbox.name
          end
          if trigger('vbox:vbox-verify', vbox.name)
            trigger('vbox:vbox-kill', vbox.name)
            sleep(1)
          end
          trigger('vbox:vbox-delete', vbox.name) unless trigger('vbox:vbox-verify', vbox.name)
        end
      end

      # 2. add an Inprovise node if the VM was installed successfully
      @node_script = Inprovise::DSL.script "#{name}#vbox_node" do

        # add a node object for the new VM unless suppressed
        apply do
          unless vbox.no_node
            # get MAC and IP for VM
            log.print("Determining IP address for VBox #{vbox.name}. Please wait ...|".bold)
            mac = addr = nil
            150.times do |n|
              sleep(2)
              log.print("\b" + %w{| / - \\}[(n+1) % 4].bold)
              mac, addr = trigger 'vbox:vbox-ifaddr', vbox.name
              if addr
                break
              end
            end
            log("\bdone".bold)
            raise RuntimeError, "Failed to determin IP address for VBox #{vbox.name}" unless addr
            log("VBox #{vbox.name} : mac=#{mac}, addr=#{addr}") if Inprovise.verbosity > 0
            vbox_opts = vbox.to_h
            vbox_opts.delete(:no_node)
            vbox_opts.delete(:no_sniff)
            node = Inprovise::Infrastructure::Node.new(vbox.name, {:host => addr, :user => vbox.user, :vbox => vbox_opts})
            Inprovise::Infrastructure.save
            unless vbox.no_sniff
              # retry on (comm) failure
              Inprovise::Sniffer.run_sniffers_for(node) rescue Inprovise::Sniffer.run_sniffers_for(node)
              Inprovise::Infrastructure.save
            end
            log("Added new node #{node.to_s}".bold)
          end
        end

        # remove the node object for the VM unless node creation suppressed
        revert do
          unless vbox.no_node
            tgt = Inprovise::Infrastructure.find(vbox.name)
            if tgt && Inprovise::Infrastructure::Node === tgt
              Inprovise::Infrastructure.deregister(vbox.name)
              Inprovise::Infrastructure.save
              log("Removed node #{tgt.to_s}".bold)
            else
              log("No existing node #{vbox.name} found!".yellow)
            end
          end
        end

      end

      # add dependencies in correct order
      # MUST proceed any user defined dependencies
      dependencies.insert(0, @vm_script.name, @node_script.name)

      self
    end

    def configure(cfg, &block)
      @config = cfg.merge({ :script => name })
      @config_action = block if block_given?
      self
    end

    def init_config(hash)
      hash.to_h.reduce(OpenStruct.new(hash)) do |os,(k,v)|
        os[k] = init_config(v) if Hash === v
        os
      end
    end

  end

end

Inprovise::DSL.dsl_define do
  def vbox(name, &definition)
    Inprovise.log.local("Adding VBox script #{name}") if Inprovise.verbosity > 1
    Inprovise.add_script(Inprovise::VBox::VBoxScript.new(name)) do |script|
      Inprovise::VBox::VBoxScript::DSL.new(script).instance_eval(&definition)
    end.setup
  end
end
