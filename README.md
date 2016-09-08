
Inprovise Virtual Box
=====================

This project implements an extension for the Inprovise provisioning tool providing `vbox` scripts for installing
Libvirt based virtual machine instances.

This is not a really general purpose plugin nor is it intended to be. This plugin is very much tailored to our particular
requirements which are pretty simple in this area. Currently we only use libvirt based virtualization and hvm (fully virtualized)
type virtual machines.
However, this plugin gives a good example of the ease with which such an Inprovise plugin can be created using mostly the
basic functionality provided by Inprovise itself.

Installation
------------

    $ gem install inprovise-vbox

Usage
-----

Add the following to (for example) your Inprovise project's `rigrc` file.

````ruby
require 'inprovise/vbox'
````

Syntax
------

````ruby
vbox 'myvm' do

    configuration ({
      :name => 'MyVM',
      :image => '/remote/image/path',
      :memory => 1024,
      :cpus => 2  
    })

end
````

When applying this script for a target VM host node it will automatically create a (libvirt based, hvm type) virtual machine instance `MyVM`
on the specified host and define a new Inprovise infrastructure node if the installation was successful.

Optionally user defined `apply`, `revert` and/or `validate` blocks can be added to provide additional (custom) 
processing.
  
