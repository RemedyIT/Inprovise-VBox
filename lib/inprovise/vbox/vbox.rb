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
    action('vbox-verify') do |vboxname, autostart=false|
      vbox_info = sudo("virsh dominfo #{vboxname}").gsub("\n", ' ')
      vbox_info =~ /name:\s+#{vboxname}\s.*state:\s+running/i &&
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

      vbox_script = self
      vbox_scrname = self.name
      # define the scripts that do the actual work as dependencies
      # 1. install the virtual machine
      @vm_script = Inprovise::DSL.script "#{name}#vbox_vm" do

        # verify VM
        validate do
          vbox_cfg = config[vbox_scrname.to_sym]
          # look for existing target with VM name on :apply unless node creation is suppressed
          if command == :apply && !vbox_cfg.no_node
            if tgt = Inprovise::Infrastructure.find(vbox_cfg.name)
              type = Inprovise::Infrastructure::Group === tgt ? 'group' : 'node'
              raise ArgumentError, "VBox #{vbox_cfg.name} clashes with existing #{type}"
            end
          end
          trigger 'vbox:vbox-verify', vbox_cfg.name, (command == :apply && vbox_cfg.autostart)
        end

        # apply : installation
        apply do
          vbox_cfg = config[vbox_scrname.to_sym]
          # 1. verify config
          raise ArgumentError, "Cannot access VBox image #{vbox_cfg.image}" unless remote(vbox_cfg.image).file?
          # 2. execute virt-install
          log("Installing VBox #{vbox_cfg.name}".bold)
          cmdline = 'virt-install --connect qemu:///system --hvm --virt-type kvm --import --wait 0 '
          cmdline << '--autostart ' if vbox_cfg.autostart
          cmdline << "--name #{vbox_cfg.name} --memory #{vbox_cfg.memory} --vcpus #{vbox_cfg.cpus} "
          cmdline << "--os-variant #{vbox_cfg.os} " if vbox_cfg.os
          cmdline << case vbox_cfg.network
                     when :hostnet
                       "--network network=#{vbox_cfg.netname || 'default'} "
                     when :bridge
                       "--network bridge=#{vbox_cfg.netname || 'virbr0' } "
                     end
          cmdline << '--graphics spice '
          cmdline << "--disk path=#{vbox_cfg.image},device=disk,boot_order=1"
          cmdline << ",bus=#{vbox_cfg.diskbus}" if vbox_cfg.diskbus
          cmdline << ",format=#{vbox_cfg.format}" if vbox_cfg.format
          cmdline << ' --disk device=cdrom,boot_order=2,bus=ide'
          cmdline << " #{vbox_cfg.install_opts}" if vbox_cfg.install_opts
          sudo(cmdline)
          10.times do
            sleep(1)
            break if trigger 'vbox:vbox-verify', vbox_cfg.name, vbox_cfg.autostart
          end
        end

        # revert : uninstall
        revert do
          vbox_cfg = config[vbox_scrname.to_sym]
          trigger 'vbox:vbox-shutdown', vbox_cfg.name
          log.print("Waiting for shutdown of VBox #{vbox_cfg.name}. Please wait ...|".bold)
          30.times do |n|
            sleep(1)
            log.print("\b" + %w{| / - \\}[(n+1) % 4].bold)
            break unless trigger 'vbox:vbox-verify', vbox_cfg.name
          end
          if trigger('vbox:vbox-verify', vbox_cfg.name)
            trigger('vbox:vbox-kill', vbox_cfg.name)
            sleep(1)
          end
          log.println("\bdone".bold)
          trigger('vbox:vbox-delete', vbox_cfg.name) unless trigger('vbox:vbox-verify', vbox_cfg.name)
        end
      end

      # 2. add an Inprovise node if the VM was installed successfully
      @node_script = Inprovise::DSL.script "#{name}#vbox_node" do

        # add a node object for the new VM unless suppressed
        apply do
          vbox_cfg = config[vbox_scrname.to_sym]
          unless vbox_cfg.no_node
            # get MAC and IP for VM
            log.print("Determining IP address for VBox #{vbox_cfg.name}. Please wait ...|".bold)
            mac = addr = nil
            150.times do |n|
              sleep(2)
              log.print("\b" + %w{| / - \\}[(n+1) % 4].bold)
              mac, addr = trigger 'vbox:vbox-ifaddr', vbox_cfg.name
              if addr
                break
              end
            end
            log.println("\bdone".bold)
            raise RuntimeError, "Failed to determin IP address for VBox #{vbox_cfg.name}" unless addr
            log("VBox #{vbox_cfg.name} : mac=#{mac}, addr=#{addr}") if Inprovise.verbosity > 0
            vbox_opts = vbox_cfg.to_h
            vbox_opts.delete(:no_node)
            vbox_opts.delete(:no_sniff)
            node = Inprovise::Infrastructure::Node.new(vbox_cfg.name, {:host => addr, :user => vbox_cfg.user, :vbox => vbox_opts})
            Inprovise::Infrastructure.save
            unless vbox_cfg.no_sniff
              # retry on (comm) failure
              Inprovise::Sniffer.run_sniffers_for(node) rescue Inprovise::Sniffer.run_sniffers_for(node)
              Inprovise::Infrastructure.save
            end
            log("Added new node #{node.to_s}".bold)
          end
        end

        # remove the node object for the VM unless node creation suppressed
        revert do
          vbox_cfg = config[vbox_scrname.to_sym]
          unless vbox_cfg.no_node
            tgt = Inprovise::Infrastructure.find(vbox_cfg.name)
            if tgt && Inprovise::Infrastructure::Node === tgt
              Inprovise::Infrastructure.deregister(vbox_cfg.name)
              Inprovise::Infrastructure.save
              log("Removed node #{tgt.to_s}".bold)
            else
              log("No existing node #{vbox_cfg.name} found!".yellow)
            end
          end
        end

      end

      # add dependencies in correct order
      # MUST proceed any user defined dependencies
      dependencies.insert(0, @vm_script.name, @node_script.name)

      self
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
