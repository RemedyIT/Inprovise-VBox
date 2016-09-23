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
    action 'vbox-install' do |vboxname, cfg|
      log("Installing VBox #{vboxname}", :bold)
      log("VBox config :\n#{JSON.pretty_generate(cfg)}") if Inprovise.verbosity > 1
      cmdline = "virt-install --connect qemu:///system --hvm --virt-type #{cfg[:virt_type] || 'kvm'} --import --wait 0 "
      cmdline << "--arch #{cfg[:arch]} "
      cmdline << '--autostart ' if cfg[:autostart]
      cmdline << "--name #{vboxname} --memory #{cfg[:memory]} --vcpus #{cfg[:cpus]} "
      # check if os variant defined on this host
      if cfg[:os]
        os_variant = sudo("osinfo-query --fields=short-id os | grep #{cfg[:os]}").strip
        cmdline << "--os-variant #{cfg[:os]} " unless os_variant.empty?
      end
      cmdline << '--network '
      cmdline << case cfg[:network]
                 when :hostnet
                   "network=#{cfg[:netname] || 'default'}"
                 when :bridge
                   "bridge=#{cfg[:netname] || 'virbr0' }"
                 end
      cmdline << ",model=#{cfg[:nic]}" if cfg[:nic]
      cmdline << ' '
      cmdline << "--graphics #{cfg[:graphics] || 'spice'} "
      cmdline << "--disk path=#{cfg[:image]},device=disk,boot_order=1"
      cmdline << ",bus=#{cfg[:diskbus]}" if cfg[:diskbus]
      cmdline << ",format=#{cfg[:format]}" if cfg[:format]
      cmdline << " --disk device=cdrom,boot_order=2,bus=#{cfg[:cdrombus] || 'ide'}" unless cfg[:cdrom] == false
      cmdline << %{ --boot "kernel=#{cfg[:kernel]},kernel_args=#{cfg[:kernel_args]}"} if cfg[:kernel]
      cmdline << " #{cfg[:install_opts]}" if cfg[:install_opts]
      sudo(cmdline, :log => true)
    end
  end

  class VBoxScript < Inprovise::Script

    # configuration
    #     :name
    #     :virt_type
    #     :arch
    #     :image
    #     :format
    #     :diskbus
    #     :memory
    #     :cdrom
    #     :cdrombus
    #     :cpus
    #     :os
    #     :network
    #     :netname
    #     :nic
    #     :autostart
    #     :kernel
    #     :kernel_args
    #     :install_opts

    def initialize(name)
      super(name)
      @vm_script = nil
      @node_script = nil
    end

    def setup
      # take care of defaults
      @configuration ||= Inprovise::Config.new
      @configuration[:arch] ||= 'x86_64'
      @configuration[:memory] ||= 1024
      @configuration[:cpus] ||= 1
      @configuration[:network] ||= :hostnet
      # generate name if none set
      @configuration[:name] ||= "#{name}_#{self.hash}_#{Time.now.to_f}"
      # create default configuration callback
      self.configure

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
          # 1. trigger virt-install
          trigger('vbox:vbox-install', vbs.vbox_name(self), {
              :virt_type => vbs.vbox_virt_type(self),
              :arch => vbs.vbox_arch(self),
              :autostart => vbs.vbox_autostart(self),
              :memory => vbs.vbox_memory(self),
              :cpus => vbs.vbox_cpus(self),
              :os => vbs.vbox_os(self),
              :network => vbs.vbox_network(self) || :hostnet,
              :netname => vbs.vbox_netname(self),
              :nic => vbs.vbox_nic(self),
              :graphics => vbs.vbox_graphics(self),
              :image => vbs.vbox_image(self),
              :diskbus => vbs.vbox_diskbus(self),
              :format => vbs.vbox_format(self),
              :cdrom => vbs.vbox_cdrom(self),
              :cdrombus => vbs.vbox_cdrombus(self),
              :kernel => vbs.vbox_kernel(self),
              :kernel_args => vbs.vbox_kernel_args(self),
              :install_opts => vbs.vbox_install_opts(self)
            })
          # wait to startup
          10.times do
            sleep(1)
            break if trigger 'vbox:vbox-verify', vbs.vbox_name(self), true, vbs.vbox_autostart(self)
          end
        end

        # revert : uninstall
        revert do
          vmname = vbs.vbox_name(self)
          if trigger 'vbox:vbox-verify', vmname, true
            trigger 'vbox:vbox-shutdown', vmname
            msg = "Waiting for shutdown of VBox #{vmname}. Please wait ..."
            log.print("#{msg}|\r", :bold)
            30.times do |n|
              sleep(1)
              log.print("#{msg}#{%w{| / - \\}[(n+1) % 4]}\r", :bold)
              break unless trigger 'vbox:vbox-verify', vmname, true
            end
            if trigger('vbox:vbox-verify', vmname, true)
              trigger('vbox:vbox-kill', vmname)
              sleep(1)
            end
            log.println("#{msg}done", :bold)
          end
          trigger('vbox:vbox-delete', vmname) unless trigger('vbox:vbox-verify', vmname, true)
        end
      end

      # 2. add an Inprovise node if the VM was installed successfully
      @node_script = Inprovise::DSL.script "#{name}#vbox_node" do

        validate do
          if vbs.vbox_no_node(self)
            config.command != :revert
          else
            vmname = vbs.vbox_name(self)
            if tgt = Inprovise::Infrastructure.find(vmname)
              raise ArgumentError, "VBox #{vmname} clashes with existing group" if Inprovise::Infrastructure::Group === tgt
              true
            else
              false
            end
          end
        end

        # add a node object for the new VM unless suppressed
        apply do
          vmname = vbs.vbox_name(self)
          unless vbs.vbox_no_node(self)
            # get MAC and IP for VM
            msg = "Determining IP address for VBox #{vmname}. Please wait ..."
            log.print("#{msg}|\r", :bold)
            mac = addr = nil
            150.times do |n|
              sleep(2)
              log.print("#{msg}#{%w{| / - \\}[(n+1) % 4]}\r", :bold)
              mac, addr = trigger 'vbox:vbox-ifaddr', vmname
              if addr
                break
              end
            end
            log.println("#{msg}done", :bold)
            raise RuntimeError, "Failed to determin IP address for VBox #{vmname}" unless addr
            log("VBox #{vmname} : mac=#{mac}, addr=#{addr}") if Inprovise.verbosity > 0
            vbox_opts = vbs.vbox_config_hash(self)
            vbox_opts.delete(:no_node)
            vbox_opts.delete(:no_sniff)
            node_opts = vbox_opts.delete(:node) || {}
            node_group = [node_opts.delete(:group)].flatten.compact
            node_opts[:host] ||= addr
            node_opts[:user] ||= vbs.vbox_user(self)
            node_opts[:vbox] = vbox_opts
            node = Inprovise::Infrastructure::Node.new(vmname, node_opts)
            Inprovise::Infrastructure.save
            node_group.each do |grpnm|
              grp = Inprovise::Infrastructure.find(grpnm)
              raise ArgumentError, "Invalid Group name '#{grpnm}'." unless grp.nil? || Inprovise::Infrastructure::Group === grp
              grp = Inprovise::Infrastructure::Group.new(grpnm) unless grp
              node.add_to(grp)
            end
            Inprovise::Infrastructure.save unless node_group.empty?
            unless vbs.vbox_no_sniff(self)
              (1..5).each do |i|
                begin
                  Inprovise::Sniffer.run_sniffers_for(node)
                  break
                rescue
                  raise if i == 5
                  sleep(5)  # maybe VM needs more time to start up SSH
                  node.disconnect!
                  # retry on (comm) failure
                end
              end
              Inprovise::Infrastructure.save
            end
            log("Added new node #{node}", :bold)
            config['vbox'] = node
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
              log("Removed node #{tgt}", :bold)
            else
              log("No existing node #{vmname} found!", :yellow)
            end
          end
        end

      end

      # add dependencies in correct order
      # MUST preceed any user defined dependencies
      dependencies.insert(0, @vm_script.name, @node_script.name)

      self
    end

    # overload Script#configure
    def configure(cfg=nil, &definition)
      @configuration = Inprovise::Config.new.merge!(cfg) if cfg
      vbs = self
      config_block = block_given? ? definition : nil
      command(:configure).clear
      command(:configure) do
        self.instance_eval(&config_block) if config_block
        config['vbox'] = Inprovise::Infrastructure.find(config[vbs.name][:name])
      end
      @configuration
    end

    def vbox_name(context)
      value_for context, context.config[name.to_sym][:name]
    end

    def vbox_virt_type(context)
      value_for context, context.config[name.to_sym][:virt_type]
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

    def vbox_arch(context)
      value_for context, context.config[name.to_sym][:arch]
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

    def vbox_nic(context)
      value_for context, context.config[name.to_sym][:nic]
    end

    def vbox_graphics(context)
      value_for context, context.config[name.to_sym][:graphics]
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

    def vbox_cdrom(context)
      value_for context, context.config[name.to_sym][:cdrom]
    end

    def vbox_cdrombus(context)
      value_for context, context.config[name.to_sym][:cdrombus]
    end

    def vbox_kernel(context)
      value_for context, context.config[name.to_sym][:kernel]
    end

    def vbox_kernel_args(context)
      value_for context, context.config[name.to_sym][:kernel_args]
    end

    def vbox_install_opts(context)
      value_for context, context.config[name.to_sym][:install_opts]
    end

    def vbox_config_hash(context)
      context.config[name.to_sym].to_h.reduce({}) do |h, (k,v)|
        case h[k] = value_for(context, v)
          when Inprovise::Config
          h[k] = h[k].to_h
        end
        h
      end
    end

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
