# VBox script class for InproviseVBox
#
# Author::    Martin Corino
# License::   Distributes under the same license as Ruby

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
    action('vbox-verify') do |vboxname, running=false, autostart=false|
      vbox_info = sudo("virsh dominfo #{vboxname}").gsub("\n", ' ')
      vbox_info =~ /name:\s+#{vboxname}/i &&
        (!running || vbox_info =~ /state:\s+running/i) &&
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

    # configuration
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

    def initialize(name)
      super(name)
      @vm_script = nil
      @node_script = nil
    end

    def setup
      # verify mandatory configuration
      raise ArgumentError, "Missing required configuration for vbox script #{name}" unless Hash === configuration || OpenStruct === configuration
      # take care of defaults
      configuration[:memory] ||= 1024
      configuration[:cpus] ||= 1
      configuration[:network] ||= :hostnet
      # generate name if none set
      configuration[:name] ||= "#{name}_#{self.hash}_#{Time.now.to_f}"

      vbs = self
      # define the scripts that do the actual work as dependencies
      # 1. install the virtual machine
      @vm_script = Inprovise::DSL.script "#{name}#vbox_vm" do

        # verify VM
        validate do
          vmname = vbs.vbox_name(self)
          if trigger 'vbox:vbox-verify', vmname
            true  # vm with this name already running
          else
            # look for existing target with VM name on :apply unless node creation is suppressed
            if command == :apply && !vbs.vbox_no_node(self)
              if tgt = Inprovise::Infrastructure.find(vmname)
                type = Inprovise::Infrastructure::Group === tgt ? 'group' : 'node'
                raise ArgumentError, "VBox #{vmname} clashes with existing #{type}"
              end
            end
            false
          end
        end

        # apply : installation
        apply do
          vmname = vbs.vbox_name(self)
          vmimg = vbs.vbox_image(self)
          # 1. verify config
          raise ArgumentError, "Cannot access VBox image #{vmimg}" unless remote(vmimg).file?
          # 2. execute virt-install
          log("Installing VBox #{vmname}".bold)
          cmdline = 'virt-install --connect qemu:///system --hvm --virt-type kvm --import --wait 0 '
          cmdline << '--autostart ' if vbs.vbox_autostart(self)
          cmdline << "--name #{vmname} --memory #{vbs.vbox_memory(self)} --vcpus #{vbs.vbox_cpus(self)} "
          cmdline << "--os-variant #{vbs.vbox_os(self)} " if vbs.vbox_os(self)
          cmdline << case vbs.vbox_network(self)
                     when :hostnet
                       "--network network=#{vbs.vbox_netname(self) || 'default'} "
                     when :bridge
                       "--network bridge=#{vbs.vbox_netname(self) || 'virbr0' } "
                     end
          cmdline << '--graphics spice '
          cmdline << "--disk path=#{vbs.vbox_image(self)},device=disk,boot_order=1"
          cmdline << ",bus=#{vbs.vbox_diskbus(self)}" if vbs.vbox_diskbus(self)
          cmdline << ",format=#{vbs.vbox_format(self)}" if vbs.vbox_format(self)
          cmdline << ' --disk device=cdrom,boot_order=2,bus=ide'
          cmdline << " #{vbs.vbox_install_opts(self)}" if vbs.vbox_install_opts(self)
          sudo(cmdline)
          10.times do
            sleep(1)
            break if trigger 'vbox:vbox-verify', vmname, true, vbs.vbox_autostart(self)
          end
        end

        # revert : uninstall
        revert do
          vmname = vbs.vbox_name(self)
          if trigger 'vbox:vbox-verify', vmname, true
            trigger 'vbox:vbox-shutdown', vmname
            log.print("Waiting for shutdown of VBox #{vmname}. Please wait ...|".bold)
            30.times do |n|
              sleep(1)
              log.print("\b" + %w{| / - \\}[(n+1) % 4].bold)
              break unless trigger 'vbox:vbox-verify', vmname, true
            end
            if trigger('vbox:vbox-verify', vmname, true)
              trigger('vbox:vbox-kill', vmname)
              sleep(1)
            end
            log.println("\bdone".bold)
          end
          trigger('vbox:vbox-delete', vmname) unless trigger('vbox:vbox-verify', vmname, true)
        end
      end

      # 2. add an Inprovise node if the VM was installed successfully
      @node_script = Inprovise::DSL.script "#{name}#vbox_node" do

        validate do
          vmname = vbs.vbox_name(self)
          if tgt = Inprovise::Infrastructure.find(vmname)
            raise ArgumentError, "VBox #{vmname} clashes with existing group" if Inprovise::Infrastructure::Group === tgt
            true
          else
            false
          end
        end

        # add a node object for the new VM unless suppressed
        apply do
          vmname = vbs.vbox_name(self)
          unless vbs.vbox_no_node(self)
            # get MAC and IP for VM
            log.print("Determining IP address for VBox #{vmname}. Please wait ...|".bold)
            mac = addr = nil
            150.times do |n|
              sleep(2)
              log.print("\b" + %w{| / - \\}[(n+1) % 4].bold)
              mac, addr = trigger 'vbox:vbox-ifaddr', vmname
              if addr
                break
              end
            end
            log.println("\bdone".bold)
            raise RuntimeError, "Failed to determin IP address for VBox #{vmname}" unless addr
            log("VBox #{vmname} : mac=#{mac}, addr=#{addr}") if Inprovise.verbosity > 0
            vbox_opts = vbs.vbox_config_hash(self)
            vbox_opts.delete(:no_node)
            vbox_opts.delete(:no_sniff)
            node_opts = vbox_opts.delete(:node) || {}
            node_opts[:host] ||= addr
            node_opts[:user] ||= vbs.vbox_user(self)
            node_opts[:vbox] = vbox_opts
            node = Inprovise::Infrastructure::Node.new(vmname, node_opts)
            Inprovise::Infrastructure.save
            unless vbs.vbox_no_sniff(self)
              # retry on (comm) failure
              Inprovise::Sniffer.run_sniffers_for(node) rescue Inprovise::Sniffer.run_sniffers_for(node)
              Inprovise::Infrastructure.save
            end
            log("Added new node #{node}".bold)
          end
        end

        # remove the node object for the VM unless node creation suppressed
        revert do
          vmname = vbs.vbox_name(self)
          unless vbs.vbox_no_node(self)
            tgt = Inprovise::Infrastructure.find(vmname)
            if tgt && Inprovise::Infrastructure::Node === tgt
              Inprovise::Infrastructure.deregister(vmname)
              Inprovise::Infrastructure.save
              log("Removed node #{tgt}".bold)
            else
              log("No existing node #{vmname} found!".yellow)
            end
          end
        end

      end

      # add dependencies in correct order
      # MUST proceed any user defined dependencies
      dependencies.insert(0, @vm_script.name, @node_script.name)

      self
    end

    def vbox_name(context)
      value_for context, context.config[name.to_sym][:name]
    end

    def vbox_autostart(context)
      value_for context, context.config[name.to_sym][:autostart]
    end

    def vbox_no_node(context)
      value_for context, context.config[name.to_sym][:no_node]
    end

    def vbox_no_sniff(context)
      value_for context, context.config[name.to_sym][:no_sniff]
    end

    def vbox_image(context)
      value_for context, context.config[name.to_sym][:image]
    end

    def vbox_memory(context)
      value_for context, context.config[name.to_sym][:memory]
    end

    def vbox_cpus(context)
      value_for context, context.config[name.to_sym][:cpus]
    end

    def vbox_network(context)
      value_for context, context.config[name.to_sym][:network]
    end

    def vbox_netname(context)
      value_for context, context.config[name.to_sym][:netname]
    end

    def vbox_os(context)
      value_for context, context.config[name.to_sym][:os]
    end

    def vbox_user(context)
      value_for context, context.config[name.to_sym][:user]
    end

    def vbox_diskbus(context)
      value_for context, context.config[name.to_sym][:diskbus]
    end

    def vbox_format(context)
      value_for context, context.config[name.to_sym][:format]
    end

    def vbox_install_opts(context)
      value_for context, context.config[name.to_sym][:install_opts]
    end

    def vbox_config_hash(context)
      context.config[name.to_sym].to_h.reduce({}) do |h, (k,v)|
        case h[k] = value_for(context, v)
          when OpenStruct
          h[k] = config_to_hash(h[k])
        end
        h
      end
    end

    def config_to_hash(cfg)
      cfg.to_h.reduce({}) do |h, (k,v)|
        h[k] = case v
          when OpenStruct
          config_to_hash(v)
          else
          v
        end
        h
      end
    end
    private :config_to_hash

    def value_for(context, option)
      return nil if option.nil?
      return context.instance_exec(&option) if option.respond_to?(:call)
      option
    end
    private :value_for

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
